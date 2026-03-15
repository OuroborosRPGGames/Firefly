# frozen_string_literal: true

# NarrativeThreadService detects emergent storyline threads from entity clusters.
#
# Algorithm:
#   1. Find connected components in the entity relationship graph
#   2. Match clusters to existing threads via Jaccard similarity
#   3. Create new threads or update existing ones
#   4. Manage thread lifecycle (emerging -> active -> dormant -> resolved)
#
# Runs hourly via scheduler.
module NarrativeThreadService
  class << self
    # Main entry point - detect and update storyline threads
    # @return [Hash] { new_threads:, updated_threads:, dormant_count:, errors: }
    def detect_and_update!
      results = { new_threads: 0, updated_threads: 0, dormant_count: 0, errors: [] }

      # Step 1: Find entity clusters
      clusters = find_entity_clusters

      # Step 2: Match clusters to existing threads
      matches = match_clusters_to_threads(clusters)

      # Step 3: Create or update threads
      matches.each do |match|
        if match[:thread]
          update_thread(match[:thread], match[:entity_ids])
          results[:updated_threads] += 1
        else
          create_thread_from_cluster(match[:entity_ids])
          results[:new_threads] += 1
        end
      rescue StandardError => e
        results[:errors] << { entity_ids: match[:entity_ids], error: e.message }
        warn "[NarrativeThread] Error processing cluster: #{e.message}"
      end

      # Step 4: Lifecycle management
      results[:dormant_count] = update_thread_statuses!

      results
    end

    private

    # ========================================
    # Step 1: Find Clusters
    # ========================================

    # Find entity clusters via graph or relational BFS
    # @return [Array<Array<Integer>>] arrays of entity IDs
    def find_entity_clusters
      config = GameConfig::Narrative::THREADS
      NarrativeGraphService.find_connected_components(min_size: config[:min_cluster_size])
    rescue StandardError => e
      warn "[NarrativeThread] Error finding clusters: #{e.message}"
      []
    end

    # ========================================
    # Step 2: Match to Existing Threads
    # ========================================

    # Match clusters to existing threads using Jaccard similarity
    # @param clusters [Array<Array<Integer>>]
    # @return [Array<Hash>] { thread: NarrativeThread or nil, entity_ids: [Integer] }
    def match_clusters_to_threads(clusters)
      active_threads = NarrativeThread.active_threads.all
      thread_entity_sets = active_threads.map { |t| [t, t.entity_id_set] }
      threshold = GameConfig::Narrative::THREADS[:jaccard_match_threshold]

      matched_threads = Set.new
      results = []

      clusters.each do |entity_ids|
        cluster_set = Set.new(entity_ids)
        best_match = nil
        best_score = 0.0

        thread_entity_sets.each do |thread, thread_set|
          next if matched_threads.include?(thread.id)

          score = jaccard_similarity(cluster_set, thread_set)
          if score >= threshold && score > best_score
            best_match = thread
            best_score = score
          end
        end

        if best_match
          matched_threads.add(best_match.id)
          results << { thread: best_match, entity_ids: entity_ids }
        else
          results << { thread: nil, entity_ids: entity_ids }
        end
      end

      results
    end

    # Jaccard similarity between two sets
    # @return [Float] 0.0 to 1.0
    def jaccard_similarity(set_a, set_b)
      return 0.0 if set_a.empty? && set_b.empty?

      intersection = (set_a & set_b).size
      union = (set_a | set_b).size
      intersection.to_f / union
    end

    # ========================================
    # Step 3: Create/Update Threads
    # ========================================

    # Create a new thread from an entity cluster
    # @param entity_ids [Array<Integer>]
    # @return [NarrativeThread]
    def create_thread_from_cluster(entity_ids)
      entities = NarrativeEntity.where(id: entity_ids).all
      memories = gather_cluster_memories(entity_ids)

      # Generate thread info via LLM
      thread_info = generate_thread_info(entities, memories)

      thread = NarrativeThread.create(
        name: thread_info[:name] || "Thread #{Time.now.to_i}",
        summary: thread_info[:summary],
        status: 'emerging',
        importance: calculate_thread_importance(entities, memories),
        themes: thread_info[:themes] || [],
        entity_count: entities.size,
        memory_count: memories.size,
        last_activity_at: Time.now
      )

      # Link entities with centrality and roles
      entities.each do |entity|
        centrality = calculate_entity_centrality(entity, entity_ids)
        role = find_entity_role(entity, thread_info[:roles])
        thread.add_entity!(entity, centrality: centrality, role: role)
      end

      # Link memories
      memories.each { |m| thread.add_memory!(m, relevance: 0.7) }

      thread
    end

    # Update an existing thread with new entity data
    # @param thread [NarrativeThread]
    # @param entity_ids [Array<Integer>]
    def update_thread(thread, entity_ids)
      existing_ids = thread.entity_id_set
      new_ids = Set.new(entity_ids)
      added_ids = new_ids - existing_ids

      # Add new entities
      added_ids.each do |eid|
        entity = NarrativeEntity[eid]
        next unless entity

        centrality = calculate_entity_centrality(entity, entity_ids)
        thread.add_entity!(entity, centrality: centrality)
      end

      # Add new memories
      memories = gather_cluster_memories(entity_ids)
      existing_memory_ids = thread.narrative_thread_memories_dataset.select_map(:world_memory_id)
      memories.each do |m|
        thread.add_memory!(m, relevance: 0.5) unless existing_memory_ids.include?(m.id)
      end

      # Re-summarize if significant change (>30% new entities)
      change_ratio = added_ids.size.to_f / [new_ids.size, 1].max
      if change_ratio > 0.3
        entities = NarrativeEntity.where(id: entity_ids).all
        thread_info = generate_thread_info(entities, memories)
        thread.update(
          summary: thread_info[:summary],
          themes: thread_info[:themes] || thread.themes,
          importance: calculate_thread_importance(entities, memories),
          last_activity_at: Time.now
        )
      else
        thread.update(last_activity_at: Time.now)
      end
    end

    # ========================================
    # Step 4: Lifecycle Management
    # ========================================

    # Update thread statuses based on activity
    # @return [Integer] number of threads marked dormant/resolved
    def update_thread_statuses!
      config = GameConfig::Narrative::THREADS
      dormant_threshold = Time.now - (config[:dormant_days] * 86_400)
      resolved_threshold = Time.now - (config[:resolved_days] * 86_400)
      count = 0

      # Emerging -> Active (10+ memories)
      NarrativeThread.where(status: 'emerging').where { memory_count >= 10 }.update(status: 'active')

      # Active -> Climax (20+ memories AND importance >= 7)
      NarrativeThread.where(status: 'active')
                     .where { memory_count >= 20 }
                     .where { importance >= 7 }
                     .update(status: 'climax')

      # Active/Climax -> Dormant (no activity for dormant_days)
      count += NarrativeThread.where(status: %w[active climax emerging])
                              .where { last_activity_at < dormant_threshold }
                              .update(status: 'dormant')

      # Dormant -> Resolved (no activity for resolved_days)
      count += NarrativeThread.where(status: 'dormant')
                              .where { last_activity_at < resolved_threshold }
                              .update(status: 'resolved')

      count
    end

    # ========================================
    # LLM Analysis
    # ========================================

    # Generate thread name, summary, themes, and entity roles via LLM
    # @param entities [Array<NarrativeEntity>]
    # @param memories [Array<WorldMemory>]
    # @return [Hash] { name:, summary:, themes:, roles: }
    def generate_thread_info(entities, memories)
      config = GameConfig::Narrative::THREADS

      entities_text = entities.map { |e| "- #{e.name} (#{e.entity_type}): #{e.description || 'no description'}" }.join("\n")

      # Gather reputation context for PC entities
      reputation_lines = []
      if defined?(Character)
        entities.select { |e| e.canonical_type == 'Character' && e.canonical_id }.each do |e|
          char = Character[e.canonical_id]
          next unless char && !char.npc? && char.tier_1_reputation && !char.tier_1_reputation.strip.empty?

          reputation_lines << "- #{e.name} is known for: #{char.tier_1_reputation}"
        end
      end
      reputation_text = reputation_lines.any? ? reputation_lines.join("\n") : '(no established reputations)'


      # Get relationships between these entities
      entity_ids = entities.map(&:id)
      relationships = NarrativeRelationship.current.where(
        Sequel.&(
          Sequel.|({ source_entity_id: entity_ids }, { target_entity_id: entity_ids }),
          Sequel.|({ source_entity_id: entity_ids }, { target_entity_id: entity_ids })
        )
      ).all

      relationships_text = relationships.map do |r|
        src = entities.find { |e| e.id == r.source_entity_id }&.name || "Entity##{r.source_entity_id}"
        tgt = entities.find { |e| e.id == r.target_entity_id }&.name || "Entity##{r.target_entity_id}"
        "- #{src} --[#{r.relationship_type}]--> #{tgt}#{r.context ? " (#{r.context})" : ''}"
      end.join("\n")

      memories_text = memories.first(10).map do |m|
        "- [#{m.memory_at&.strftime('%Y-%m-%d')}] #{m.summary}"
      end.join("\n")

      prompt = GamePrompts.get('narrative.thread_summary',
                               entities: entities_text,
                               relationships: relationships_text.empty? ? '(none detected)' : relationships_text,
                               memories: memories_text.empty? ? '(no memories yet)' : memories_text,
                               reputation_context: reputation_text)

      result = LLM::Client.generate(
        prompt: prompt,
        model: config[:summary_model],
        provider: config[:summary_provider],
        options: { temperature: 0.4 }
      )

      return default_thread_info(entities) unless result[:success] && result[:text]

      parse_thread_response(result[:text], entities)
    rescue StandardError => e
      warn "[NarrativeThread] LLM error generating thread info: #{e.message}"
      default_thread_info(entities)
    end

    # Parse LLM thread response
    # @param text [String]
    # @param entities [Array<NarrativeEntity>]
    # @return [Hash]
    def parse_thread_response(text, entities)
      json_text = text.match(/\{[\s\S]*\}/)&.[](0)
      return default_thread_info(entities) unless json_text

      parsed = JSON.parse(json_text, symbolize_names: true)
      {
        name: parsed[:name] || default_thread_name(entities),
        summary: parsed[:summary],
        themes: Array(parsed[:themes]),
        roles: Array(parsed[:roles])
      }
    rescue JSON::ParserError
      default_thread_info(entities)
    end

    # Fallback thread info when LLM fails
    # @param entities [Array<NarrativeEntity>]
    # @return [Hash]
    def default_thread_info(entities)
      {
        name: default_thread_name(entities),
        summary: nil,
        themes: [],
        roles: []
      }
    end

    # Generate default thread name from entity names
    # @param entities [Array<NarrativeEntity>]
    # @return [String]
    def default_thread_name(entities)
      names = entities.sort_by { |e| -e.importance }.first(3).map(&:name)
      "The #{names.join(', ')} Story"
    end

    # ========================================
    # Helpers
    # ========================================

    # Calculate thread importance from entities and memories
    # @param entities [Array<NarrativeEntity>]
    # @param memories [Array<WorldMemory>]
    # @return [Float]
    def calculate_thread_importance(entities, memories)
      entity_importance = entities.any? ? entities.sum(&:importance) / entities.size : 5.0
      memory_importance = memories.any? ? memories.sum(&:importance) / memories.size : 5.0
      memory_volume_bonus = [memories.size / 10.0, 2.0].min
      reputation_bonus = calculate_reputation_bonus(entities)

      [(entity_importance + memory_importance) / 2.0 + memory_volume_bonus + reputation_bonus, 10.0].min
    end

    # Bonus importance for threads involving PCs with established reputation.
    # +0.5 per PC with reputation, capped at 1.5.
    #
    # @param entities [Array<NarrativeEntity>]
    # @return [Float]
    def calculate_reputation_bonus(entities)
      return 0.0 unless defined?(Character)

      pc_entities = entities.select { |e| e.canonical_type == 'Character' && e.canonical_id }
      bonus = 0.0

      pc_entities.each do |e|
        char = Character[e.canonical_id]
        next unless char && !char.npc?
        next if char.tier_1_reputation.nil? || char.tier_1_reputation.strip.empty?

        bonus += 0.5
      end

      [bonus, 1.5].min
    rescue StandardError => e
      warn "[NarrativeThreadService] Failed to calculate reputation bonus: #{e.message}"
      0.0
    end

    # Calculate entity centrality within a cluster
    # @param entity [NarrativeEntity]
    # @param cluster_entity_ids [Array<Integer>]
    # @return [Float] 0.0 to 1.0
    def calculate_entity_centrality(entity, cluster_entity_ids)
      # Relationship count within cluster / cluster size
      rel_count = NarrativeRelationship.current.where(
        Sequel.|(
          { source_entity_id: entity.id, target_entity_id: cluster_entity_ids },
          { target_entity_id: entity.id, source_entity_id: cluster_entity_ids }
        )
      ).count

      return 0.0 if cluster_entity_ids.size <= 1

      rel_count.to_f / (cluster_entity_ids.size - 1)
    end

    # Find entity role from LLM-assigned roles
    # @param entity [NarrativeEntity]
    # @param roles [Array<Hash>]
    # @return [String, nil]
    def find_entity_role(entity, roles)
      return nil unless roles.is_a?(Array)

      match = roles.find { |r| r[:entity_name]&.downcase == entity.name.downcase }
      role = match&.[](:role)
      NarrativeThreadEntity::ROLES.include?(role) ? role : nil
    end

    # Gather world memories linked to any entity in the cluster
    # @param entity_ids [Array<Integer>]
    # @return [Array<WorldMemory>]
    def gather_cluster_memories(entity_ids)
      memory_ids = NarrativeEntityMemory
        .where(narrative_entity_id: entity_ids)
        .select_map(:world_memory_id)
        .uniq

      return [] if memory_ids.empty?

      WorldMemory.where(id: memory_ids).order(Sequel.desc(:memory_at)).limit(50).all
    end
  end
end
