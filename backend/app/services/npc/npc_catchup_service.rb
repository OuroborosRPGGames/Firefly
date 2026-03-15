# frozen_string_literal: true

# NpcCatchupService generates temporal continuity for NPCs.
#
# When an NPC hasn't been interacted with for 1+ days, this service:
# 1. Ensures a location recap WorldMemory exists (what's been happening here)
# 2. Generates an NPC reflection NpcMemory (what the NPC has been up to)
#
# Called from NpcAnimationHandler.call before emote generation.
# Both memories flow into the existing context assembly via semantic search.
#
# Usage:
#   NpcCatchupService.ensure_caught_up!(npc_instance)
#
module NpcCatchupService
  CATCHUP_THRESHOLD_SECONDS = 86_400  # 1 day
  LOCATION_RECAP_WINDOW_DAYS = 7
  LONG_GAP_THRESHOLD_DAYS = 7
  LOCATION_HISTORY_DAYS = 90

  class << self
    # Main entry point — called from NpcAnimationHandler before emote generation.
    # Checks if catch-up is needed and generates location recap + NPC reflection.
    #
    # @param npc_instance [CharacterInstance] the NPC's live instance
    def ensure_caught_up!(npc_instance)
      npc = npc_instance.character
      return unless npc&.npc?

      # Step 1: Should we catch up?
      last_interaction = most_recent_interaction(npc)
      return unless last_interaction # No interactions ever — nothing to catch up from

      gap_seconds = Time.now - last_interaction.memory_at
      return if gap_seconds < CATCHUP_THRESHOLD_SECONDS # Less than 1 day — too recent

      # Already caught up since last interaction?
      if npc_instance.last_catchup_at && npc_instance.last_catchup_at > last_interaction.memory_at
        return
      end

      room = npc_instance.current_room
      return unless room

      # Step 2: Ensure location recap exists
      location_recap = ensure_location_recap!(room)

      # Step 3: Generate NPC catch-up
      gap_days = gap_seconds / 86_400.0
      generate_npc_reflection!(
        npc: npc,
        npc_instance: npc_instance,
        room: room,
        location_recap: location_recap,
        gap_days: gap_days
      )

      # Step 4: Mark complete
      npc_instance.update(last_catchup_at: Time.now)
    rescue StandardError => e
      warn "[NpcCatchup] Error during catch-up for #{npc_instance&.character&.full_name}: #{e.message}"
    end

    private

    # Find the most recent interaction memory for this NPC
    # @param npc [Character]
    # @return [NpcMemory, nil]
    def most_recent_interaction(npc)
      NpcMemory.where(character_id: npc.id, memory_type: 'interaction')
               .order(Sequel.desc(:memory_at))
               .first
    end

    # Check for a recent location recap; generate one if missing
    # @param room [Room]
    # @return [WorldMemory, nil] the recap (existing or newly generated)
    def ensure_location_recap!(room)
      existing = find_recent_location_recap(room)
      return existing if existing

      generate_location_recap!(room)
    end

    # Find a location_recap WorldMemory for this room within the last 7 days
    # @param room [Room]
    # @return [WorldMemory, nil]
    def find_recent_location_recap(room)
      cutoff = Time.now - (LOCATION_RECAP_WINDOW_DAYS * 86_400)
      recap_ids = WorldMemoryLocation.where(room_id: room.id).select(:world_memory_id)

      WorldMemory.where(id: recap_ids, source_type: 'location_recap')
                 .where { memory_at > cutoff }
                 .order(Sequel.desc(:memory_at))
                 .first
    end

    # Generate a location recap via Claude Sonnet
    # @param room [Room]
    # @return [WorldMemory, nil]
    def generate_location_recap!(room)
      location = room.location
      game_setting = GameSetting.get('world_type') || 'modern fantasy'

      recent_events = gather_recent_events(room)
      narrative_threads = gather_narrative_threads(room)

      prompt = GamePrompts.get(
        'memory.location_recap',
        game_setting: game_setting,
        room_name: room.name || 'Unknown Location',
        room_description: room.description ? "DESCRIPTION: #{room.description}" : '',
        location_name: location&.name || 'Unknown Building',
        recent_events: recent_events.empty? ? 'No notable events recorded recently.' : recent_events,
        narrative_threads: narrative_threads.empty? ? 'No active storylines nearby.' : narrative_threads
      )

      result = LLM::Client.generate(
        prompt: prompt,
        model: 'claude-sonnet-4-6',
        provider: 'anthropic',
        options: { temperature: 0.8, max_tokens: 400 }
      )

      return nil unless result[:success] && result[:text]&.strip&.length&.positive?

      now = Time.now
      recap = WorldMemory.create(
        summary: result[:text].strip,
        started_at: now - (LOCATION_RECAP_WINDOW_DAYS * 86_400),
        ended_at: now,
        memory_at: now,
        source_type: 'location_recap',
        publicity_level: 'public',
        importance: 4
      )

      recap.add_location!(room, is_primary: true)
      store_world_memory_embedding(recap)

      recap
    rescue StandardError => e
      warn "[NpcCatchup] Failed to generate location recap: #{e.message}"
      nil
    end

    # Generate NPC reflection via Claude Sonnet
    # @param npc [Character]
    # @param npc_instance [CharacterInstance]
    # @param room [Room]
    # @param location_recap [WorldMemory, nil]
    # @param gap_days [Float]
    def generate_npc_reflection!(npc:, npc_instance:, room:, location_recap:, gap_days:)
      archetype = npc.npc_archetype
      game_setting = GameSetting.get('world_type') || 'modern fantasy'

      # Gather context
      personality = archetype&.effective_personality_prompt || 'A quiet, unremarkable person.'
      goals = gather_npc_goals(npc)
      relationships = gather_npc_relationships(npc)
      recent_memories = gather_recent_memories(npc)
      recap_text = location_recap&.summary || 'Nothing notable has been happening nearby.'
      gap_duration = format_gap_duration(gap_days)

      prompt = GamePrompts.get(
        'memory.npc_catchup',
        npc_name: npc.full_name,
        game_setting: game_setting,
        personality: personality,
        goals: goals.empty? ? 'No specific goals.' : goals,
        relationships: relationships.empty? ? 'No notable relationships.' : relationships,
        recent_memories: recent_memories.empty? ? 'No recent memories.' : recent_memories,
        location_recap: recap_text,
        gap_duration: gap_duration
      )

      result = LLM::Client.generate(
        prompt: prompt,
        model: 'claude-sonnet-4-6',
        provider: 'anthropic',
        options: { temperature: 0.8, max_tokens: 400 }
      )

      return unless result[:success] && result[:text]&.strip&.length&.positive?

      abstraction_level = gap_days >= LONG_GAP_THRESHOLD_DAYS ? 2 : 1

      memory = NpcMemory.create(
        character_id: npc.id,
        content: result[:text].strip,
        memory_type: 'reflection',
        importance: 5,
        abstraction_level: abstraction_level,
        location_id: room.location_id,
        memory_at: Time.now
      )

      store_npc_memory_embedding(memory, npc)
    rescue StandardError => e
      warn "[NpcCatchup] Failed to generate NPC reflection for #{npc.full_name}: #{e.message}"
    end

    # ============================================
    # Context Gathering Helpers
    # ============================================
    # Each helper uses a savepoint so PG errors (e.g., missing columns)
    # don't poison the outer transaction and cascade to later operations.

    def gather_recent_events(room)
      DB.transaction(savepoint: true) do
        memories = WorldMemory.for_room(room, limit: 5)
                              .where { memory_at > Time.now - (LOCATION_HISTORY_DAYS * 86_400) }
                              .exclude(source_type: 'location_recap')
                              .all

        memories.map { |m| "- #{m.summary}" }.join("\n")
      end
    rescue StandardError => e
      warn "[NpcCatchup] gather_recent_events failed: #{e.message}"
      ''
    end

    def gather_narrative_threads(room)
      return '' unless defined?(WorldMemoryService)

      DB.transaction(savepoint: true) do
        threads = WorldMemoryService.retrieve_thread_context_for_npc(
          npc: nil, room: room, limit: 3
        )
        return '' if threads.empty?

        threads.map { |t| "- #{t.name}: #{t.summary}" }.join("\n")
      end
    rescue StandardError => e
      warn "[NpcCatchup] gather_narrative_threads failed: #{e.message}"
      ''
    end

    def gather_npc_goals(npc)
      DB.transaction(savepoint: true) do
        goals = NpcGoal.active_for(npc).limit(5).all
        goals.map do |goal|
          content = goal.content_text
          next if content.nil? || content.to_s.strip.empty?

          "- [#{goal.goal_type}] #{content}"
        end.compact.join("\n")
      end
    rescue StandardError => e
      warn "[NpcCatchup] gather_npc_goals failed: #{e.message}"
      ''
    end

    def gather_npc_relationships(npc)
      DB.transaction(savepoint: true) do
        rels = NpcRelationship.for_npc(npc).limit(5).all
        rels.map(&:to_context_string).join("\n")
      end
    rescue StandardError => e
      warn "[NpcCatchup] gather_npc_relationships failed: #{e.message}"
      ''
    end

    def gather_recent_memories(npc)
      DB.transaction(savepoint: true) do
        memories = NpcMemory.where(character_id: npc.id)
                            .exclude(memory_type: 'reflection')
                            .order(Sequel.desc(:memory_at))
                            .limit(5)
                            .all
        memories.map { |m| "- #{m.content}" }.join("\n")
      end
    rescue StandardError => e
      warn "[NpcCatchup] gather_recent_memories failed: #{e.message}"
      ''
    end

    def format_gap_duration(gap_days)
      if gap_days < 1
        'less than a day'
      elsif gap_days < 2
        'about a day'
      elsif gap_days < 7
        "about #{gap_days.round} days"
      elsif gap_days < 14
        'about a week'
      elsif gap_days < 30
        "about #{(gap_days / 7).round} weeks"
      else
        "about #{(gap_days / 30).round} months"
      end
    end

    # ============================================
    # Embedding Storage
    # ============================================

    def store_world_memory_embedding(memory)
      Embedding.store(
        content_type: 'world_memory',
        content_id: memory.id,
        text: memory.summary,
        room_id: memory.primary_room&.id,
        input_type: 'document'
      )
    rescue StandardError => e
      warn "[NpcCatchup] Failed to store world memory embedding: #{e.message}"
    end

    def store_npc_memory_embedding(memory, npc)
      Embedding.store(
        content_type: 'npc_memory',
        content_id: memory.id,
        text: memory.content,
        character_id: npc.id,
        input_type: 'document'
      )
    rescue StandardError => e
      warn "[NpcCatchup] Failed to store NPC memory embedding: #{e.message}"
    end
  end
end
