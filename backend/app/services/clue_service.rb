# frozen_string_literal: true

# ClueService manages clue storage, retrieval, and sharing decisions.
# Integrates with NPC memory system for RAG context.
module ClueService
  CLUE_EMBEDDING_TYPE = GameConfig::Clue::EMBEDDING_TYPE

  class << self
    # Get clues relevant to a conversation topic for an NPC
    # @param npc [Character] The NPC character
    # @param query [String] Conversation topic/content
    # @param pc [Character] The PC the NPC is talking to
    # @param limit [Integer] Max clues to return
    # @param arranged_scene_id [Integer, nil] Optional scene ID for scene-specific clues
    # @return [Array<Hash>] Clues with share info: { clue:, can_share:, likelihood:, already_shared: }
    def relevant_clues_for(npc:, query:, pc:, limit: GameConfig::Clue::DEFAULT_LIMIT, arranged_scene_id: nil)
      return [] unless npc && query && pc

      # Get clues this NPC knows
      npc_clue_ids = NpcClue.where(character_id: npc.id).select_map(:clue_id)
      return [] if npc_clue_ids.empty?

      # Semantic search on clue content
      result = LLM::Client.embed(text: query, input_type: 'query')
      return [] unless result[:success]

      similar = Embedding.similar_to(
        result[:embedding],
        limit: limit * GameConfig::Clue::OVER_FETCH_MULTIPLIER,
        content_type: CLUE_EMBEDDING_TYPE,
        threshold: GameConfig::Clue::SIMILARITY_THRESHOLD
      )

      # Filter to this NPC's clues with scene scope
      clue_ids = similar.map { |s| s[:embedding].content_id }
      clues_query = Clue.where(id: clue_ids, is_active: true)
                        .where(id: npc_clue_ids)

      # Include global clues + scene-specific clues if in a scene
      if arranged_scene_id
        clues_query = clues_query.where(
          Sequel.|(
            { arranged_scene_id: nil },
            { arranged_scene_id: arranged_scene_id }
          )
        )
      else
        # Only global clues when not in a scene
        clues_query = clues_query.where(arranged_scene_id: nil)
      end

      clues = clues_query.all

      # Build result with share info
      clues.map do |clue|
        {
          clue: clue,
          can_share: clue.can_share_to?(pc, npc: npc),
          likelihood: clue.share_likelihood_for(npc),
          already_shared: clue.already_shared_to?(pc, npc: npc)
        }
      end.first(limit)
    rescue StandardError => e
      warn "[ClueService] Failed to retrieve clues: #{e.message}"
      []
    end

    # Determine if NPC should share a clue during this interaction
    # @param clue [Clue] The clue
    # @param npc [Character] The NPC
    # @param pc [Character] The PC
    # @return [Boolean] Whether to share
    def should_share?(clue:, npc:, pc:)
      return false unless clue && npc && pc
      return false unless clue.can_share_to?(pc, npc: npc)
      return false if clue.already_shared_to?(pc, npc: npc)

      likelihood = clue.share_likelihood_for(npc)
      rand < likelihood
    end

    # Record that a clue was shared and trigger any related triggers
    # @param clue [Clue] The clue
    # @param npc [Character] The NPC who shared
    # @param pc [Character] The PC who received
    # @param room [Room, nil] Where it was shared
    # @param context [String, nil] Conversation context
    # @return [ClueShare] The created share record
    def record_share!(clue:, npc:, pc:, room: nil, context: nil)
      share = ClueShare.create(
        clue_id: clue.id,
        npc_character_id: npc.id,
        recipient_character_id: pc.id,
        room_id: room&.id,
        context: context,
        shared_at: Time.now
      )

      # Store as NPC memory (if service is available)
      if defined?(NpcMemoryService)
        NpcMemoryService.store_memory(
          npc: npc,
          content: "Shared clue about '#{clue.name}' with #{pc.full_name}",
          about_character: pc,
          importance: GameConfig::Clue::MEMORY_IMPORTANCE,
          memory_type: 'interaction'
        )
      end

      # Check clue share triggers
      TriggerService.check_clue_share_triggers(
        clue: clue,
        npc: npc,
        recipient: pc,
        room: room
      )

      share
    rescue StandardError => e
      warn "[ClueService] Failed to record share: #{e.message}"
      nil
    end

    # Format clues for NPC RAG context
    # @param clue_info [Array<Hash>] From relevant_clues_for
    # @return [String] Formatted context string
    def format_for_context(clue_info)
      return '' if clue_info.nil? || clue_info.empty?

      clue_info.map do |info|
        clue = info[:clue]
        status = if info[:already_shared]
          '[Already shared]'
        elsif info[:can_share]
          "[Can share - #{(info[:likelihood] * 100).round}% likely]"
        else
          '[Secret - requires trust]'
        end

        "#{status} #{clue.name}: #{clue.content}"
      end.join("\n")
    end

    # Check if NPC knows any clues about a topic
    # @param npc [Character] The NPC
    # @param topic [String] Topic to search
    # @return [Boolean]
    def npc_knows_about?(npc:, topic:)
      return false unless npc && topic

      npc_clue_ids = NpcClue.where(character_id: npc.id).select_map(:clue_id)
      return false if npc_clue_ids.empty?

      # Simple keyword search
      Clue.where(id: npc_clue_ids, is_active: true)
          .where(Sequel.ilike(:content, "%#{topic}%") | Sequel.ilike(:name, "%#{topic}%"))
          .any?
    end

    # Get all clues an NPC knows
    # @param npc [Character] The NPC
    # @return [Array<Clue>]
    def clues_for_npc(npc)
      return [] unless npc

      clue_ids = NpcClue.where(character_id: npc.id).select_map(:clue_id)
      Clue.where(id: clue_ids, is_active: true).all
    end

    # Assign a clue to an NPC
    # @param clue [Clue] The clue
    # @param npc [Character] The NPC
    # @param likelihood_override [Float, nil] Override share likelihood
    # @param trust_override [Float, nil] Override trust requirement
    def assign_to_npc(clue:, npc:, likelihood_override: nil, trust_override: nil)
      return unless clue && npc

      existing = NpcClue.where(clue_id: clue.id, character_id: npc.id).first
      if existing
        existing.update(
          share_likelihood_override: likelihood_override,
          min_trust_override: trust_override
        )
      else
        NpcClue.create(
          clue_id: clue.id,
          character_id: npc.id,
          share_likelihood_override: likelihood_override,
          min_trust_override: trust_override
        )
      end
    end

    # Remove clue from NPC
    # @param clue [Clue] The clue
    # @param npc [Character] The NPC
    def remove_from_npc(clue:, npc:)
      return unless clue && npc
      NpcClue.where(clue_id: clue.id, character_id: npc.id).delete
    end
  end
end
