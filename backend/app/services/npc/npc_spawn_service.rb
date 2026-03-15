# frozen_string_literal: true

# Service for managing NPC spawning and despawning based on schedules
class NpcSpawnService
  class << self
    # Process all NPC schedules - called periodically by scheduler
    # Spawns NPCs that should be present and despawns those that shouldn't
    # @param current_time [Time] The current time (default: Time.now)
    # @return [Hash] Summary of spawn/despawn actions taken
    def process_schedules!(current_time = Time.now)
      results = { spawned: [], despawned: [], errors: [] }

      # First, despawn NPCs that should no longer be present
      despawn_due_npcs!(current_time, results)

      # Then, spawn NPCs that should be present
      spawn_scheduled_npcs!(current_time, results)

      results
    end

    # Spawn a unique NPC in a specific room
    # @param character [Character] The NPC character to spawn
    # @param room [Room] The room to spawn in
    # @param options [Hash] Additional options
    # @return [NpcSpawnInstance, nil] The spawn instance or nil on failure
    def spawn_unique_npc(character, room, options = {})
      return nil unless character&.npc?
      return nil unless room

      # Get or create the character instance
      reality = options[:reality] || Reality.first(reality_type: 'primary') || Reality.first
      return nil unless reality

      # Find or create a character instance for this NPC
      instance = CharacterInstance.first(character_id: character.id, reality_id: reality.id)
      unless instance
        instance = CharacterInstance.create(
          character_id: character.id,
          reality_id: reality.id,
          current_room_id: room.id,
          level: 1,
          health: 100,
          max_health: 100,
          mana: 50,
          max_mana: 50,
          online: true,
          status: 'alive',
          roomtitle: options[:activity]
        )
      end

      return nil unless instance

      # Update instance to be in the correct room and online
      instance.update(
        current_room_id: room.id,
        online: true,
        roomtitle: options[:activity]
      )

      # Initialize animation state (LLM-generated outfit/status if enabled)
      initialize_animation_state(instance, options)

      upsert_active_spawn_instance(
        character_id: character.id,
        character_instance_id: instance.id,
        room_id: room.id,
        schedule_id: options[:schedule_id],
        despawn_at: options[:despawn_at],
        activity: options[:activity]
      )
    end

    # Spawn an NPC from a template (for non-unique NPCs)
    # Accepts either a template Character or an NpcArchetype.
    # @param template_or_archetype [Character, NpcArchetype]
    # @param room [Room] The room to spawn in
    # @param options [Hash] Additional options
    # @return [NpcSpawnInstance, nil] The spawn instance or nil on failure
    def spawn_from_template(template_or_archetype, room, options = {})
      return nil unless room
      options = normalize_spawn_options(options)

      template, archetype = resolve_template_and_archetype(template_or_archetype)
      return nil unless template&.template_npc?
      return nil unless archetype

      # Use archetype to create the instance
      instance = archetype.spawn_instance_from_template(
        template,
        room,
        options
      )
      return nil unless instance

      # Initialize animation state (LLM-generated outfit/status if enabled)
      initialize_animation_state(instance, options)

      upsert_active_spawn_instance(
        character_id: template.id,
        character_instance_id: instance.id,
        room_id: room.id,
        schedule_id: options[:schedule_id],
        despawn_at: options[:despawn_at],
        activity: options[:activity]
      )
    end

    # Spawn a character by IDs into a room.
    # Used by TriggerCodeExecutor DSL (`spawn_npc(character_id, room_id)`).
    # @param character_id [Integer]
    # @param room_id [Integer]
    # @param options [Hash]
    # @return [NpcSpawnInstance, nil]
    def spawn_at_room(character_id:, room_id:, options: {})
      character = Character[character_id]
      room = Room[room_id]
      return nil unless character&.npc?
      return nil unless room

      options = normalize_spawn_options(options)

      if character.template_npc?
        spawn_from_template(character, room, options)
      else
        spawn_unique_npc(character, room, options)
      end
    rescue StandardError => e
      warn "[NpcSpawnService] spawn_at_room failed: #{e.message}"
      nil
    end

    # Despawn an NPC
    # @param spawn_instance [NpcSpawnInstance] The spawn instance to despawn
    # @return [Boolean] Success status
    def despawn_npc(spawn_instance)
      return false unless spawn_instance

      spawn_instance.despawn!
      true
    end

    # Despawn all instances of a character
    # @param character [Character] The character to despawn
    # @return [Integer] Number of instances despawned
    def despawn_all(character)
      return 0 unless character

      count = 0
      NpcSpawnInstance.where(character_id: character.id, active: true).each do |spawn|
        spawn.despawn!
        count += 1
      end
      count
    end

    # Kill an NPC in combat - despawn and announce death
    # Used when hostile NPCs reach 0 HP instead of knockout
    # @param character_instance [CharacterInstance] The NPC to kill
    # @param cause [String] Optional death cause for narrative
    # @return [Boolean] Success status
    def kill_npc!(character_instance, cause: nil)
      return false unless character_instance
      return false unless character_instance.character&.npc?

      room = character_instance.current_room
      character = character_instance.character

      # Find and deactivate spawn instance if one exists
      spawn = NpcSpawnInstance.first(
        character_instance_id: character_instance.id,
        active: true
      )
      spawn&.despawn!

      # Set instance offline and dead
      character_instance.update(online: false, status: 'dead')

      # Broadcast death message to room (personalized per viewer)
      death_msg = cause || "#{character.full_name} has been slain!"
      if room&.id
        room_chars = CharacterInstance.where(
          current_room_id: room.id,
          online: true
        ).eager(:character).all

        all_chars = room_chars
        unless room_chars.any? { |rc| rc.id == character_instance.id }
          all_chars = room_chars + [character_instance]
        end

        room_chars.each do |viewer|
          personalized = MessagePersonalizationService.personalize(
            message: death_msg,
            viewer: viewer,
            room_characters: all_chars
          )
          BroadcastService.to_character(viewer, personalized, type: :combat)
        end

        # Log NPC death to character stories
        IcActivityService.record(
          room_id: room.id, content: death_msg,
          sender: nil, type: :combat
        )
      end

      true
    rescue StandardError => e
      warn "[NpcSpawnService] kill_npc! failed: #{e.message}"
      false
    end

    # Get all currently active NPC spawns in a room
    # @param room [Room] The room to check
    # @return [Array<NpcSpawnInstance>] Active spawn instances
    def active_in_room(room)
      return [] unless room

      NpcSpawnInstance.where(room_id: room.id, active: true).all
    end

    # Check if a character is currently spawned
    # @param character [Character] The character to check
    # @return [Boolean]
    def spawned?(character)
      return false unless character

      NpcSpawnInstance.where(character_id: character.id, active: true).any?
    end

    private

    # Despawn NPCs that are due for despawning
    def despawn_due_npcs!(current_time, results)
      NpcSpawnInstance.due_for_despawn(current_time).each do |spawn|
        begin
          spawn.despawn!
          results[:despawned] << {
            character_id: spawn.character_id,
            room_id: spawn.room_id,
            reason: spawn.npc_schedule_id ? 'schedule_ended' : 'despawn_time'
          }
        rescue StandardError => e
          results[:errors] << {
            character_id: spawn.character_id,
            error: e.message
          }
        end
      end
    end

    # Spawn NPCs that should be present based on schedules
    def spawn_scheduled_npcs!(current_time, results)
      grouped = NpcSchedule.applicable_now(current_time).group_by(&:character_id)

      grouped.each_value do |schedules|
        begin
          chosen = select_schedule_for_character(schedules)
          next unless chosen

          character = chosen.character
          next unless character&.npc?

          # A character instance can only be in one room per reality.
          # If this NPC is already spawned, don't spawn another schedule copy.
          next if NpcSpawnInstance.where(character_id: character.id, active: true).any?

          spawn = spawn_unique_npc(
            character,
            chosen.room,
            schedule_id: chosen.id,
            activity: chosen.activity
          )

          if spawn
            set_current_schedule!(character_id: character.id, schedule_id: chosen.id, current_time: current_time)
            results[:spawned] << {
              character_id: character.id,
              room_id: chosen.room_id,
              schedule_id: chosen.id
            }
          end
        rescue StandardError => e
          results[:errors] << {
            character_id: schedules.first&.character_id,
            error: e.message
          }
        end
      end
    end

    # Initialize animation state for an NPC instance on spawn
    # Generates outfit and status via LLM if the archetype has animation enabled
    # @param instance [CharacterInstance] The spawned character instance
    # @param options [Hash] Spawn options (may override generated values)
    def initialize_animation_state(instance, options = {})
      return unless instance
      return unless defined?(NpcAnimationService)

      archetype = instance.character&.npc_archetype
      return unless archetype&.animated?

      # Reset animation tracking for fresh spawn
      instance.update(
        last_animation_at: nil,
        animation_emote_count: 0,
        animation_first_emote_done: false
      )

      # Generate outfit if enabled and not overridden
      if archetype.should_generate_outfit? && !options[:outfit]
        outfit = NpcAnimationService.generate_spawn_outfit(instance)
        instance.character.update(outfit: outfit) if outfit
      end

      # Generate status/roomtitle if enabled and not overridden
      if archetype.should_generate_status? && !options[:activity]
        status = NpcAnimationService.generate_spawn_status(instance)
        instance.update(roomtitle: status) if status
      end
    rescue StandardError => e
      # Don't fail the spawn if animation initialization fails
      warn "[NpcSpawn] Animation init error for #{instance.id}: #{e.message}"
    end

    # Normalizes option hashes from different callers.
    # Some callers pass `{ options: { ... } }` while others pass `{ ... }`.
    def normalize_spawn_options(options)
      return {} unless options.is_a?(Hash)
      return options unless options[:options].is_a?(Hash)

      options[:options].merge(options.reject { |k, _| k == :options })
    end

    def resolve_template_and_archetype(template_or_archetype)
      if template_or_archetype&.respond_to?(:template_npc?) && template_or_archetype.template_npc?
        template = template_or_archetype
        return [template, template.npc_archetype]
      end

      if defined?(NpcArchetype) && template_or_archetype.is_a?(NpcArchetype)
        archetype = template_or_archetype
        template = archetype.characters_dataset
                           .where(is_npc: true, is_unique_npc: false)
                           .first
        template ||= archetype.create_template_npc
        return [template, archetype]
      end

      [nil, nil]
    rescue StandardError => e
      warn "[NpcSpawnService] Failed to resolve template/archetype: #{e.message}"
      [nil, nil]
    end

    # Select one schedule for a character when multiple schedules apply.
    # This prevents conflicting concurrent spawns for the same NPC instance.
    def select_schedule_for_character(schedules)
      eligible = schedules.select(&:can_spawn_more?)
      return nil if eligible.empty?

      rolled = eligible.select(&:should_spawn?)
      return nil if rolled.empty?

      rolled.max_by { |schedule| [schedule.probability || 100, -(schedule.id || 0)] }
    end

    def set_current_schedule!(character_id:, schedule_id:, current_time:)
      NpcSchedule.where(character_id: character_id).exclude(id: schedule_id).update(current: false)
      NpcSchedule.where(id: schedule_id).update(current: true, arrive_time: current_time)
    end

    def upsert_active_spawn_instance(character_id:, character_instance_id:, room_id:, schedule_id:, despawn_at:, activity:)
      existing = NpcSpawnInstance.where(character_instance_id: character_instance_id, active: true).first
      if existing
        existing.update(
          character_id: character_id,
          npc_schedule_id: schedule_id,
          room_id: room_id,
          despawn_at: despawn_at,
          activity: activity
        )
        return existing
      end

      NpcSpawnInstance.create(
        character_id: character_id,
        character_instance_id: character_instance_id,
        npc_schedule_id: schedule_id,
        room_id: room_id,
        spawned_at: Time.now,
        despawn_at: despawn_at,
        activity: activity,
        active: true
      )
    end
  end
end
