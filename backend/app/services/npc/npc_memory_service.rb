# frozen_string_literal: true

# NpcMemoryService handles NPC memory storage and retrieval with semantic search.
# Uses Voyage AI embeddings with proper input_type for asymmetric retrieval:
# - 'document' for storing memories (prepends document prompt)
# - 'query' for searching memories (prepends query prompt)
#
# Memory Abstraction Hierarchy:
# - Level 1: Raw memories
# - Level 2+: Progressively abstracted summaries (unlimited levels)
# - 8 memories at a level trigger abstraction into 1 summary at the next level
class NpcMemoryService
  # Reference centralized config for tunable values
  ABSTRACTION_THRESHOLD = GameConfig::NpcMemory::ABSTRACTION_THRESHOLD
  MEMORY_EMBEDDING_TYPE = GameConfig::NpcMemory::EMBEDDING_TYPE

  class << self
    # Store a new memory with embedding
    # @param npc [Character] The NPC character
    # @param content [String] Memory content
    # @param about_character [Character, nil] Who the memory is about
    # @param importance [Integer] 1-10 scale
    # @param memory_type [String] Type of memory
    # @param location [Location, nil] Where the memory occurred
    # @return [NpcMemory]
    def store_memory(npc:, content:, about_character: nil, importance: 5,
                     memory_type: 'interaction', location: nil)
      memory = NpcMemory.create(
        character_id: npc.id,
        about_character_id: about_character&.id,
        location_id: location&.id,
        content: content,
        importance: importance,
        memory_type: memory_type,
        abstraction_level: 1,
        memory_at: Time.now
      )

      # Store embedding with input_type: 'document' for asymmetric search
      store_memory_embedding(memory)

      # Check if abstraction is needed at level 1
      check_and_abstract(npc: npc, level: 1)

      memory
    end

    # Retrieve relevant memories using semantic search
    # @param npc [Character] The NPC character
    # @param query [String] Search query
    # @param limit [Integer] Max memories to return
    # @param include_abstractions [Boolean] Include abstracted memories
    # @param min_age_hours [Integer] Minimum age in hours (prevents echo)
    # @return [Array<NpcMemory>]
    def retrieve_relevant(npc:, query:, limit: GameConfig::NpcMemory::DEFAULT_LIMIT,
                          include_abstractions: true, min_age_hours: GameConfig::NpcMemory::DEFAULT_MIN_AGE_HOURS)
      # Embed query with input_type: 'query' for asymmetric search
      result = LLM::Client.embed(text: query, input_type: 'query')
      return [] unless result[:success]

      # Search with pgvector inner product - over-fetch for filtering
      over_fetch = limit * GameConfig::NpcMemory::OVER_FETCH_MULTIPLIER
      similar = Embedding.similar_to(
        result[:embedding],
        limit: over_fetch,
        content_type: MEMORY_EMBEDDING_TYPE,
        threshold: GameConfig::LLM::SIMILARITY_THRESHOLDS[:memory_search]
      )

      # Filter to this NPC's memories
      npc_embeddings = similar.select { |s| s[:embedding].character_id == npc.id }

      # Load memory records with SQL-level filtering (more efficient than Ruby)
      memory_ids = npc_embeddings.map { |s| s[:embedding].content_id }
      query = NpcMemory.where(id: memory_ids)

      # Filter by minimum age in SQL (prevents echo of recent memories)
      if min_age_hours > 0
        cutoff = Time.now - (min_age_hours * 3600)
        query = query.where { memory_at < cutoff }.exclude(memory_at: nil)
      end

      # Filter by abstraction level in SQL if needed
      query = query.where(abstraction_level: 1) unless include_abstractions

      memories = query.all

      # Sort by similarity (embeddings are already sorted)
      sorted_ids = memory_ids
      memories.sort_by { |m| sorted_ids.index(m.id) || Float::INFINITY }
              .first(limit)
    end

    # Abstract memories at a level into a summary at the next level
    # @param npc [Character] The NPC
    # @param level [Integer] Level to abstract from
    def abstract_memories!(npc:, level: 1)
      # Get oldest unabstracted memories at this level
      memories = NpcMemory.unabstracted_at_level(npc.id, level)
                          .limit(ABSTRACTION_THRESHOLD)
                          .all

      return if memories.size < ABSTRACTION_THRESHOLD

      # Generate summary using Gemini flash-2.5-lite
      summary = generate_abstraction_summary(memories)
      return if summary.nil? || summary.strip.empty?

      # Create abstracted memory at next level
      abstract = NpcMemory.create(
        character_id: npc.id,
        content: summary,
        importance: memories.map(&:importance).max,
        memory_type: 'abstraction',
        abstraction_level: level + 1,
        memory_at: Time.now
      )

      # Store embedding for the abstraction
      store_memory_embedding(abstract)

      # Link original memories to the abstraction (batch update)
      NpcMemory.where(id: memories.map(&:id)).update(abstracted_into_id: abstract.id)

      # Recursively check next level
      check_and_abstract(npc: npc, level: level + 1)

      abstract
    end

    # Check all levels and abstract if needed
    # Continues until no level has enough memories to abstract
    # @param npc [Character] The NPC
    def process_abstractions!(npc:)
      level = 1
      loop do
        break unless NpcMemory.needs_abstraction?(npc.id, level)

        # Abstract all memories at this level that need it
        while NpcMemory.needs_abstraction?(npc.id, level)
          abstract_memories!(npc: npc, level: level)
        end

        level += 1
        # Safety break at level 100 (would require 8^100 raw memories)
        break if level > 100
      end
    end

    # Format memories for LLM context
    # @param memories [Array<NpcMemory>]
    # @return [String]
    def format_for_context(memories)
      return '' if memories.empty?

      formatted = memories.map do |m|
        prefix = m.abstraction? ? '[Summary]' : ''
        "#{prefix} #{m.content}"
      end

      formatted.join("\n")
    end

    private

    def store_memory_embedding(memory)
      Embedding.store(
        content_type: MEMORY_EMBEDDING_TYPE,
        content_id: memory.id,
        text: memory.content,
        character_id: memory.character_id,
        input_type: 'document'  # Critical for asymmetric retrieval
      )
    rescue StandardError => e
      # Log but don't fail the memory creation
      warn "[NpcMemoryService] Failed to store memory embedding: #{e.message}"
    end

    def check_and_abstract(npc:, level:)
      return unless NpcMemory.needs_abstraction?(npc.id, level)

      abstract_memories!(npc: npc, level: level)
    end

    def generate_abstraction_summary(memories)
      content_list = memories.map { |m| "- #{m.content}" }.join("\n")

      prompt = GamePrompts.get('memory.npc_abstraction', memories: content_list)

      result = LLM::Client.generate(
        prompt: prompt,
        model: 'gemini-3.1-flash-lite-preview',
        provider: 'google_gemini',
        options: {
          max_tokens: GameConfig::LLM::MAX_TOKENS[:summary],
          temperature: GameConfig::LLM::TEMPERATURES[:summary]
        }
      )

      result[:success] ? result[:text]&.strip : nil
    end
  end
end
