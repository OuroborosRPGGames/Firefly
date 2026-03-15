# frozen_string_literal: true

# NarrativeExtractionService extracts entities and relationships from world memories.
# Two-tier extraction:
#   - Batch: fast model, summary only (every 15 min for normal sessions)
#   - Comprehensive: powerful model, summary + raw_log (immediate for important events)
#
# Deduplication pipeline:
#   1. Canonical match (real game objects)
#   2. Exact name match (case-insensitive)
#   3. Alias match (JSONB contains)
#   4. Embedding similarity (> 0.9 threshold)
#   5. Create new entity
module NarrativeExtractionService
  class << self
    # ========================================
    # Entry Points
    # ========================================

    # Process a batch of unextracted memories
    # Called by scheduler every 15 minutes
    # @param limit [Integer]
    # @return [Hash] { processed:, entities:, relationships:, errors: }
    def extract_batch(limit: nil)
      limit ||= GameConfig::Narrative::EXTRACTION[:batch_limit]
      results = { processed: 0, entities: 0, relationships: 0, errors: [] }

      # Find memories without extraction logs
      extracted_ids = NarrativeExtractionLog.select(:world_memory_id)
      memories = WorldMemory
        .exclude(id: extracted_ids)
        .where { importance >= 3 }
        .order(Sequel.desc(:importance), Sequel.desc(:created_at))
        .limit(limit)
        .all

      memories.each do |memory|
        counts = extract_from_memory(memory, tier: :batch)
        results[:processed] += 1
        results[:entities] += counts[:entities]
        results[:relationships] += counts[:relationships]
      rescue StandardError => e
        results[:errors] << { memory_id: memory.id, error: e.message }
        warn "[NarrativeExtraction] Batch error for memory ##{memory.id}: #{e.message}"
      end

      results
    end

    # Extract entities from an important memory immediately
    # Called after Auto-GM outcomes, missions, high-importance events
    # @param world_memory [WorldMemory]
    # @return [Hash] { entities:, relationships: }
    def extract_comprehensive(world_memory)
      return { entities: 0, relationships: 0 } if NarrativeExtractionLog.extracted?(world_memory.id)

      extract_from_memory(world_memory, tier: :comprehensive)
    rescue StandardError => e
      warn "[NarrativeExtraction] Comprehensive error for memory ##{world_memory.id}: #{e.message}"
      { entities: 0, relationships: 0 }
    end

    private

    # ========================================
    # Core Extraction
    # ========================================

    # Extract entities and relationships from a single memory
    # @param memory [WorldMemory]
    # @param tier [Symbol] :batch or :comprehensive
    # @return [Hash] { entities:, relationships: }
    def extract_from_memory(memory, tier:)
      start_time = Time.now

      # Skip if already extracted
      return { entities: 0, relationships: 0 } if NarrativeExtractionLog.extracted?(memory.id)

      # Build prompt and call LLM
      extraction = call_extraction_llm(memory, tier)
      return log_extraction(memory, tier, { entities: 0, relationships: 0 }, start_time) unless extraction

      # Resolve entities (dedup and create)
      entities_map = {}
      entity_count = 0
      (extraction[:entities] || []).each do |entity_data|
        next if entity_data[:name].nil? || entity_data[:name].strip.empty?
        next if entity_count >= GameConfig::Narrative::EXTRACTION[:max_entities_per_memory]

        entity = resolve_entity(entity_data)
        next unless entity

        entities_map[entity_data[:name]] = entity
        entity_count += 1

        # Link entity to memory
        role = entity_data[:role] || 'mentioned'
        confidence = entity_data[:confidence] || 0.8
        is_reputation_relevant = (role == 'central' && confidence >= 0.8 && entity.canonical_type == 'Character')


        NarrativeEntityMemory.find_or_create(
          narrative_entity_id: entity.id,
          world_memory_id: memory.id
        ) do |em|
          em.role = role
          em.confidence = confidence
          em.reputation_relevant = is_reputation_relevant
        end

        entity.record_mention!
      end

      # Resolve relationships
      rel_count = 0
      (extraction[:relationships] || []).each do |rel_data|
        next if rel_count >= GameConfig::Narrative::EXTRACTION[:max_relationships_per_memory]

        relationship = resolve_relationship(rel_data, entities_map)
        next unless relationship

        rel_count += 1
      end

      # Sync to AGE graph
      sync_to_graph(entities_map.values, NarrativeRelationship.where(
        Sequel.|(
          { source_entity_id: entities_map.values.map(&:id) },
          { target_entity_id: entities_map.values.map(&:id) }
        )
      ).current.all) unless entities_map.empty?

      counts = { entities: entity_count, relationships: rel_count }
      log_extraction(memory, tier, counts, start_time)

      counts
    end

    # Call LLM for entity/relationship extraction
    # @param memory [WorldMemory]
    # @param tier [Symbol]
    # @return [Hash, nil] parsed extraction result
    def call_extraction_llm(memory, tier)
      config = GameConfig::Narrative::EXTRACTION

      if tier == :comprehensive
        prompt_key = 'narrative.extract_entities_comprehensive'
        model = config[:comprehensive_model]
        provider = config[:comprehensive_provider]
        content = build_comprehensive_content(memory)
      else
        prompt_key = 'narrative.extract_entities'
        model = config[:batch_model]
        provider = config[:batch_provider]
        content = memory.summary.to_s
      end

      prompt = GamePrompts.get(prompt_key, content: content)

      result = LLM::Client.generate(
        prompt: prompt,
        model: model,
        provider: provider,
        options: { temperature: 0.2 }
      )

      return nil unless result[:success] && result[:text]

      parse_extraction_response(result[:text])
    rescue StandardError => e
      warn "[NarrativeExtraction] LLM call failed: #{e.message}"
      nil
    end

    # Build content for comprehensive extraction (summary + raw_log)
    # @param memory [WorldMemory]
    # @return [String]
    def build_comprehensive_content(memory)
      parts = []
      parts << "Summary: #{memory.summary}" if memory.summary
      if memory.raw_log && !memory.raw_log.strip.empty?
        parts << "Detailed log:\n#{memory.raw_log[0, 4000]}"
      end
      parts.join("\n\n")
    end

    # Parse LLM response into structured data
    # Handles truncated JSON from token limits by attempting repair
    # @param text [String]
    # @return [Hash, nil]
    def parse_extraction_response(text)
      # Extract JSON from response (may be wrapped in markdown code block)
      json_text = text.match(/\{[\s\S]*\}/)&.[](0)

      # If no closing brace found, the response was likely truncated
      json_text ||= text.match(/\{[\s\S]*/)&.[](0)
      return nil unless json_text

      # Try direct parse first
      parsed = JSON.parse(json_text, symbolize_names: true)
      return parsed if parsed.is_a?(Hash)

      nil
    rescue JSON::ParserError
      # Attempt to repair truncated JSON
      repaired = repair_truncated_json(json_text)
      return nil unless repaired

      parsed = JSON.parse(repaired, symbolize_names: true)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError => e
      warn "[NarrativeExtraction] JSON parse error after repair: #{e.message}"
      nil
    end

    # Attempt to repair truncated JSON by closing open structures
    # @param json [String]
    # @return [String, nil]
    def repair_truncated_json(json)
      # Remove trailing commas and incomplete key-value pairs
      cleaned = json
        .gsub(/,\s*}/, '}')      # Trailing comma before }
        .gsub(/,\s*\]/, ']')     # Trailing comma before ]

      # Remove any incomplete last element (truncated mid-value)
      # Find the last complete JSON object in any array
      cleaned = cleaned.gsub(/,\s*\{[^}]*\z/m, '')

      # Count open/close brackets to figure out what needs closing
      open_braces = cleaned.count('{') - cleaned.count('}')
      open_brackets = cleaned.count('[') - cleaned.count(']')

      # Close remaining open structures
      cleaned += ']' * open_brackets if open_brackets > 0
      cleaned += '}' * open_braces if open_braces > 0

      cleaned
    rescue StandardError => e
      warn "[NarrativeExtraction] JSON repair failed: #{e.message}"
      nil
    end

    # ========================================
    # Entity Deduplication
    # ========================================

    # Resolve entity data to an existing or new NarrativeEntity
    # @param entity_data [Hash] { name:, type:, description:, aliases:, role:, confidence: }
    # @return [NarrativeEntity, nil]
    def resolve_entity(entity_data)
      name = entity_data[:name].to_s.strip
      entity_type = normalize_entity_type(entity_data[:type])
      return nil if name.empty?

      # 1. Canonical match (try to link to real game objects)
      entity = try_canonical_match(name, entity_type)
      return entity if entity

      # 2. Exact name match
      entity = NarrativeEntity.find_by_name(name)
      return entity if entity

      # 3. Alias match
      entity = NarrativeEntity.find_by_alias(name)
      return entity if entity

      # 4. Embedding similarity (skip if no embedding service)
      entity = try_embedding_match(name)
      return entity if entity

      # 5. Create new entity
      create_entity(entity_data)
    rescue StandardError => e
      warn "[NarrativeExtraction] Error resolving entity '#{name}': #{e.message}"
      nil
    end

    # Try to match entity to a real game object
    # @param name [String]
    # @param entity_type [String]
    # @return [NarrativeEntity, nil]
    def try_canonical_match(name, entity_type)
      canonical_type = nil
      canonical_id = nil

      case entity_type
      when 'character'
        char = Character.first(Sequel.ilike(:forename, name)) ||
               Character.first(Sequel.ilike(Sequel.join([:forename, ' ', :surname]), name))
        if char
          canonical_type = 'Character'
          canonical_id = char.id
        end
      when 'location'
        room = Room.first(Sequel.ilike(:name, name))
        if room
          canonical_type = 'Room'
          canonical_id = room.id
        end
      when 'faction'
        group = Group.first(Sequel.ilike(:name, name)) if defined?(Group)
        if group
          canonical_type = 'Group'
          canonical_id = group.id
        end
      end

      return nil unless canonical_type

      # Find or create entity with canonical link
      existing = NarrativeEntity.find_by_canonical(canonical_type, canonical_id)
      return existing if existing

      NarrativeEntity.create(
        name: name,
        entity_type: entity_type,
        canonical_type: canonical_type,
        canonical_id: canonical_id
      )
    rescue StandardError => e
      warn "[NarrativeExtraction] canonical match failed for '#{name}' (#{entity_type}): #{e.message}"
      nil
    end

    # Try to match by embedding similarity
    # @param name [String]
    # @return [NarrativeEntity, nil]
    def try_embedding_match(name)
      return nil unless defined?(Embedding) && defined?(LLM::Client)

      result = LLM::Client.embed(text: name, input_type: 'query')
      return nil unless result[:success]

      threshold = GameConfig::Narrative::EXTRACTION[:dedup_embedding_threshold]
      similar = Embedding.similar_to(
        result[:embedding],
        limit: 1,
        content_type: 'narrative_entity',
        threshold: threshold
      )

      return nil if similar.empty?

      NarrativeEntity[similar.first[:embedding].content_id]
    rescue StandardError => e
      warn "[NarrativeExtraction] embedding match failed for '#{name}': #{e.message}"
      nil
    end

    # Create a new entity
    # @param entity_data [Hash]
    # @return [NarrativeEntity]
    def create_entity(entity_data)
      entity = NarrativeEntity.create(
        name: entity_data[:name].to_s.strip,
        entity_type: normalize_entity_type(entity_data[:type]),
        description: entity_data[:description],
        aliases: entity_data[:aliases] || [],
        importance: entity_data[:importance] || 5.0
      )

      # Store embedding for future dedup
      store_entity_embedding(entity) if defined?(Embedding)

      entity
    end

    # ========================================
    # Relationship Resolution
    # ========================================

    # Resolve relationship data to NarrativeRelationship
    # @param rel_data [Hash] { source:, target:, type:, context:, bidirectional: }
    # @param entities_map [Hash] name -> NarrativeEntity
    # @return [NarrativeRelationship, nil]
    def resolve_relationship(rel_data, entities_map)
      source_name = rel_data[:source].to_s.strip
      target_name = rel_data[:target].to_s.strip
      rel_type = rel_data[:type].to_s.strip.downcase.gsub(/\s+/, '_')

      return nil if source_name.empty? || target_name.empty? || rel_type.empty?

      source = entities_map[source_name] || NarrativeEntity.find_by_name(source_name)
      target = entities_map[target_name] || NarrativeEntity.find_by_name(target_name)
      return nil unless source && target

      # Find or create relationship
      existing = NarrativeRelationship.find_between(source.id, target.id, type: rel_type)
      if existing
        existing.strengthen!
        return existing
      end

      NarrativeRelationship.create(
        source_entity_id: source.id,
        target_entity_id: target.id,
        relationship_type: rel_type,
        context: rel_data[:context],
        is_bidirectional: rel_data[:bidirectional] || false
      )
    rescue StandardError => e
      warn "[NarrativeExtraction] Error resolving relationship: #{e.message}"
      nil
    end

    # ========================================
    # Graph Sync
    # ========================================

    # Push entities and relationships to AGE graph
    # @param entities [Array<NarrativeEntity>]
    # @param relationships [Array<NarrativeRelationship>]
    def sync_to_graph(entities, relationships)
      return unless defined?(NarrativeGraphService)

      entities.each { |e| NarrativeGraphService.upsert_entity_node(e) }
      relationships.each { |r| NarrativeGraphService.upsert_relationship_edge(r) }
    rescue StandardError => e
      warn "[NarrativeExtraction] Graph sync error: #{e.message}"
    end

    # ========================================
    # Helpers
    # ========================================

    # Normalize entity type to valid ENTITY_TYPES
    # @param type [String, nil]
    # @return [String]
    def normalize_entity_type(type)
      normalized = type.to_s.strip.downcase
      return normalized if NarrativeEntity::ENTITY_TYPES.include?(normalized)

      # Map common variations
      case normalized
      when 'person', 'npc', 'player', 'creature', 'monster'
        'character'
      when 'place', 'room', 'area', 'region', 'city', 'building'
        'location'
      when 'group', 'organization', 'guild', 'clan', 'gang'
        'faction'
      when 'object', 'weapon', 'armor', 'artifact', 'tool'
        'item'
      when 'idea', 'magic', 'spell', 'power'
        'concept'
      when 'plot', 'quest', 'mission', 'battle', 'incident'
        'event'
      else
        'concept'
      end
    end

    # Store embedding for entity name (for future dedup)
    # @param entity [NarrativeEntity]
    def store_entity_embedding(entity)
      Embedding.store(
        content_type: 'narrative_entity',
        content_id: entity.id,
        text: entity.name,
        input_type: 'document'
      )
    rescue StandardError => e
      warn "[NarrativeExtraction] Failed to store entity embedding: #{e.message}"
    end

    # Log extraction for idempotency tracking
    # @param memory [WorldMemory]
    # @param tier [Symbol]
    # @param counts [Hash]
    # @param start_time [Time]
    # @return [Hash] the counts
    def log_extraction(memory, tier, counts, start_time)
      NarrativeExtractionLog.create(
        world_memory_id: memory.id,
        extraction_tier: tier.to_s,
        entity_count: counts[:entities],
        relationship_count: counts[:relationships],
        success: true,
        processing_time_seconds: Time.now - start_time
      )

      counts
    rescue StandardError => e
      warn "[NarrativeExtraction] Error logging extraction: #{e.message}"
      counts
    end
  end
end
