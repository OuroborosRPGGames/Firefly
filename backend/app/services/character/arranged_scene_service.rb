# frozen_string_literal: true

# ArrangedSceneService handles the creation and execution of arranged NPC scenes.
# Staff can set up private meetings between NPCs and specific PCs, with the NPC
# receiving seeded instructions and the scene being logged for summarization.
#
# Usage:
#   ArrangedSceneService.create_scene(...)        # Staff creates scene
#   ArrangedSceneService.trigger_scene(scene, pc) # PC triggers scene
#   ArrangedSceneService.end_scene(scene, pc)     # End active scene
#
module ArrangedSceneService
  class << self
    # Create a new arranged scene
    # @param npc_character [Character] The NPC to meet
    # @param pc_character [Character] The PC invited
    # @param meeting_room [Room] Where the PC triggers the scene
    # @param rp_room [Room] Where the scene takes place
    # @param created_by [Character] Staff who created it
    # @param options [Hash] Additional options (scene_name, instructions, etc.)
    # @return [Hash] Result with :success and :scene or :message
    def create_scene(npc_character:, pc_character:, meeting_room:, rp_room:, created_by:, **options)
      scene = ArrangedScene.create(
        npc_character_id: npc_character.id,
        pc_character_id: pc_character.id,
        meeting_room_id: meeting_room.id,
        rp_room_id: rp_room.id,
        created_by_id: created_by.id,
        scene_name: options[:scene_name],
        npc_instructions: options[:npc_instructions],
        invitation_message: options[:invitation_message],
        available_from: options[:available_from],
        expires_at: options[:expires_at],
        status: 'pending'
      )

      # Send invitation to PC if online
      send_invitation(scene)

      { success: true, scene: scene }
    rescue Sequel::ValidationFailed => e
      { success: false, message: "Validation failed: #{e.message}" }
    rescue StandardError => e
      warn "[ArrangedSceneService] create_scene failed: #{e.message}"
      { success: false, message: "Failed to create scene: #{e.message}" }
    end

    # Trigger an arranged scene (called when PC uses 'scene' command)
    # @param scene [ArrangedScene] The scene to trigger
    # @param pc_instance [CharacterInstance] The PC triggering the scene
    # @return [Hash] Result with :success and details
    def trigger_scene(scene, pc_instance)
      return { success: false, message: 'Scene is not available' } unless scene.available?

      DB.transaction do
        # Get NPC instance (spawn if needed)
        npc_instance, was_spawned = find_or_spawn_npc(scene)
        unless npc_instance
          return { success: false, message: 'Could not locate or spawn the NPC for this scene' }
        end

        # Store original locations for cleanup
        updated_metadata = JSON.parse((scene.metadata || {}).to_json).merge(
          'pc_original_room_id' => pc_instance.current_room_id,
          'npc_original_room_id' => npc_instance.current_room_id,
          'npc_was_spawned' => was_spawned
        )
        scene.update(metadata: Sequel.pg_jsonb_wrap(updated_metadata))

        # Broadcast departures
        broadcast_departure(pc_instance, 'leaves to attend a meeting.')
        broadcast_departure(npc_instance, 'heads off to a meeting.') unless was_spawned

        # Teleport both to RP room
        teleport_to_room(pc_instance, scene.rp_room)
        teleport_to_room(npc_instance, scene.rp_room)

        # Broadcast arrivals
        broadcast_arrival(pc_instance, scene.rp_room)
        broadcast_arrival(npc_instance, scene.rp_room)

        # Seed NPC with instructions
        if scene.npc_instructions && !scene.npc_instructions.strip.empty?
          npc_instance.seed_instruction!(scene.npc_instructions)
        end

        # Start RP session tracking
        session = start_memory_session(scene, pc_instance, npc_instance)

        # Update scene status
        scene.update(
          status: 'active',
          started_at: Time.now,
          world_memory_session_id: session&.id
        )

        # Notify staff
        notify_staff_scene_started(scene, pc_instance, npc_instance)
      end

      { success: true, scene: scene, rp_room: scene.rp_room }
    rescue StandardError => e
      warn "[ArrangedSceneService] trigger_scene failed: #{e.message}"
      { success: false, message: "Failed to trigger scene: #{e.message}" }
    end

    # End an active arranged scene
    # @param scene [ArrangedScene] The scene to end
    # @param pc_instance [CharacterInstance] The PC ending the scene
    # @return [Hash] Result with :success and details
    def end_scene(scene, pc_instance)
      return { success: false, message: 'Scene is not active' } unless scene.active?

      DB.transaction do
        # Finalize RP session and create memory
        if scene.world_memory_session
          memory = finalize_memory_session(scene.world_memory_session)
          scene.update(world_memory_id: memory&.id) if memory
        end

        # Handle NPC cleanup
        npc_instance = npc_instance(scene)
        cleanup_npc(scene, npc_instance) if npc_instance

        # Teleport PC back to meeting room
        if pc_instance && scene.meeting_room
          broadcast_departure(pc_instance, 'concludes their meeting.')
          teleport_to_room(pc_instance, scene.meeting_room)
          broadcast_arrival(pc_instance, scene.meeting_room)
        end

        # Update status
        scene.update(status: 'completed', ended_at: Time.now)

        # Send summary to staff
        send_summary_to_staff(scene)
      end

      { success: true, scene: scene, meeting_room: scene.meeting_room }
    rescue StandardError => e
      warn "[ArrangedSceneService] end_scene failed: #{e.message}"
      { success: false, message: "Failed to end scene: #{e.message}" }
    end

    # Cancel a pending scene
    # @param scene [ArrangedScene] The scene to cancel
    # @return [Hash] Result with :success
    def cancel_scene(scene)
      return { success: false, message: 'Scene is not pending' } unless scene.pending?

      scene.update(status: 'cancelled')
      { success: true, scene: scene }
    end

    # Send invitation to PC when scene is created
    # @param scene [ArrangedScene] The scene
    def send_invitation(scene)
      pc_instance = CharacterInstance.first(character_id: scene.pc_character_id, online: true)
      return unless pc_instance

      message = scene.invitation_text

      BroadcastService.to_character(
        pc_instance,
        {
          content: "[SCENE INVITATION] #{message}",
          html: "<div class='scene-invitation'><strong>[SCENE INVITATION]</strong> #{message}</div>"
        },
        type: :message
      )
    end

    private

    # Find existing NPC instance or spawn a new one
    # @return [Array<CharacterInstance, Boolean>] [instance, was_spawned]
    def find_or_spawn_npc(scene)
      # Try to find existing online instance
      existing = CharacterInstance.first(
        character_id: scene.npc_character_id,
        online: true
      )

      return [existing, false] if existing

      # Need to spawn the NPC
      npc_character = scene.npc_character
      return [nil, false] unless npc_character

      # Create instance for the scene
      reality = Reality.first(reality_type: 'primary') || Reality.first
      return [nil, false] unless reality

      instance = CharacterInstance.create(
        character_id: npc_character.id,
        reality_id: reality.id,
        current_room_id: scene.rp_room_id,
        level: 1,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50,
        online: true,
        status: 'alive'
      )

      [instance, true]
    rescue StandardError => e
      warn "[ArrangedScene] Error spawning NPC: #{e.message}"
      [nil, false]
    end

    # Get the active NPC instance for a scene
    def npc_instance(scene)
      CharacterInstance.first(character_id: scene.npc_character_id, online: true)
    end

    # Cleanup NPC after scene ends
    def cleanup_npc(scene, npc_instance)
      return unless npc_instance

      # Clear any seeded instructions
      npc_instance.clear_seed_instruction! if npc_instance.respond_to?(:clear_seed_instruction!)

      metadata = scene.metadata

      if metadata['npc_was_spawned']
        # Despawn NPC that was created for this scene
        npc_instance.update(online: false)
      elsif metadata['npc_original_room_id']
        # Return NPC to original location
        original_room = Room[metadata['npc_original_room_id']]
        if original_room
          broadcast_departure(npc_instance, 'departs after the meeting.')
          teleport_to_room(npc_instance, original_room)
          broadcast_arrival(npc_instance, original_room)
        end
      end
    end

    # Teleport a character to a room with proper positioning
    def teleport_to_room(character_instance, room)
      character_instance.teleport_to_room!(room)
    end

    # Broadcast departure message
    def broadcast_departure(character_instance, action = 'leaves.')
      return unless character_instance.current_room_id

      BroadcastService.to_room(
        character_instance.current_room_id,
        "#{character_instance.full_name} #{action}",
        exclude: [character_instance.id],
        type: :departure
      )
    end

    # Broadcast arrival message
    def broadcast_arrival(character_instance, room)
      BroadcastService.to_room(
        room.id,
        "#{character_instance.full_name} arrives.",
        exclude: [character_instance.id],
        type: :arrival
      )
    end

    # Start a WorldMemorySession for the scene
    def start_memory_session(scene, pc_instance, npc_instance)
      return nil unless defined?(WorldMemorySession)

      # Create or find session for the room
      WorldMemorySession.create(
        room_id: scene.rp_room_id,
        publicity_level: 'private',
        status: 'active',
        started_at: Time.now,
        last_activity_at: Time.now
      )
    rescue StandardError => e
      warn "[ArrangedScene] Error starting memory session: #{e.message}"
      nil
    end

    # Finalize the memory session and generate summary
    def finalize_memory_session(session)
      return nil unless session
      return nil unless defined?(WorldMemoryService)

      WorldMemoryService.finalize_session(session)
    rescue StandardError => e
      warn "[ArrangedScene] Error finalizing memory session: #{e.message}"
      nil
    end

    # Notify staff that a scene has started
    def notify_staff_scene_started(scene, pc_instance, npc_instance)
      message = "Arranged scene '#{scene.display_name}' started between " \
                "#{npc_instance.full_name} and #{pc_instance.full_name} " \
                "in #{scene.rp_room.name}"

      StaffAlertService.broadcast_to_staff(message)
    rescue StandardError => e
      warn "[ArrangedScene] Error notifying staff: #{e.message}"
    end

    # Send scene summary to staff
    def send_summary_to_staff(scene)
      summary = if scene.world_memory
                  scene.world_memory.summary
                else
                  'No summary generated (insufficient RP content)'
                end

      message = "Scene '#{scene.display_name}' completed:\n#{summary}"
      StaffAlertService.broadcast_to_staff(message)
    rescue StandardError => e
      warn "[ArrangedScene] Error sending summary: #{e.message}"
    end
  end
end
