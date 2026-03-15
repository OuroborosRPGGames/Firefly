# frozen_string_literal: true

module AutoGm
  # AutoGmActionExecutor executes GM decisions from the DecisionService.
  #
  # This service takes a decision hash and performs the actual game actions:
  # - emit: Broadcast narrative to participants
  # - roll_request: Request a skill check
  # - move_characters: Move characters to a new room
  # - spawn_npc: Create an NPC in the world
  # - spawn_item: Create an item in the world
  # - reveal_secret: Reveal a secret from the sketch
  # - trigger_twist: Activate the adventure's twist
  # - advance_stage: Progress to the next stage
  # - start_climax: Begin the climax phase
  # - resolve_session: End the adventure
  #
  class AutoGmActionExecutor
    extend AutoGm::AutoGmFormatHelper
    extend AutoGm::AutoGmArchetypeConcern

    class << self
      # Execute a GM decision
      # @param session [AutoGmSession] the session
      # @param decision [Hash] decision from DecisionService
      # @return [AutoGmAction] the created action record
      def execute(session, decision)
        action = create_action_record(session, decision)

        begin
          executed = case decision[:action_type]
          when 'emit'
            execute_emit(session, action, decision[:params])
          when 'roll_request'
            execute_roll_request(session, action, decision[:params])
          when 'move_characters'
            execute_move(session, action, decision[:params])
          when 'spawn_npc'
            execute_spawn_npc(session, action, decision[:params])
          when 'spawn_item'
            execute_spawn_item(session, action, decision[:params])
          when 'reveal_secret'
            execute_reveal_secret(session, action, decision[:params])
          when 'trigger_twist'
            execute_trigger_twist(session, action, decision[:params])
          when 'advance_stage'
            execute_advance_stage(session, action, decision[:params])
          when 'start_climax'
            execute_start_climax(session, action, decision[:params])
          when 'resolve_session'
            execute_resolve(session, action, decision[:params])
          else
            # Unknown action type - mark as failed
            action.fail!("Unknown action type: #{decision[:action_type]}")
            :failed
          end

          if !action.failed? && (executed.nil? || executed == false)
            action.fail!("Action '#{decision[:action_type]}' could not be executed")
          end

          action.complete! unless action.failed?
          action
        rescue StandardError => e
          action.fail!(e.message)
          action
        end
      end

      # Execute multiple decisions in sequence
      # @param session [AutoGmSession] the session
      # @param decisions [Array<Hash>] list of decisions
      # @return [Array<AutoGmAction>] created actions
      def execute_batch(session, decisions)
        decisions.map { |d| execute(session, d) }
      end

      private

      def create_action_record(session, decision)
        AutoGmAction.create_with_next_sequence(
          session_id: session.id,
          attributes: {
            action_type: decision[:action_type],
            status: 'pending',
            emit_text: decision.dig(:params, 'emit_text'),
            action_data: decision[:params] || {},
            ai_reasoning: decision[:reasoning],
            thinking_tokens_used: decision[:thinking_tokens]
          }
        )
      end

      # Legacy helper retained for spec compatibility.
      # New writes should use AutoGmAction.create_with_next_sequence instead.
      def next_sequence_number(session)
        (session.auto_gm_actions_dataset.max(:sequence_number) || 0) + 1
      end

      # Execute emit action - broadcast narrative
      # @param session [AutoGmSession] the session
      # @param action [AutoGmAction] the action record
      # @param params [Hash] action parameters
      def execute_emit(session, action, params)
        params ||= {}
        text = params['emit_text']
        return false unless text && !text.empty?

        room_id = session.current_room_id || session.starting_room_id
        formatted = format_gm_message(text)

        # Broadcast to the room
        BroadcastService.to_room(
          room_id,
          formatted,
          type: :auto_gm_narration,
          sender_instance: nil,
          auto_gm_session_id: session.id,
          action_id: action.id
        )

        # Log Auto-GM narration to character stories
        IcActivityService.record(
          room_id: room_id, content: formatted[:content],
          sender: nil, type: :auto_gm, html: formatted[:html]
        )

        # Also send to participants not in the room
        session.participant_instances.each do |participant|
          next if participant.current_room_id == room_id

          BroadcastService.to_character(
            participant,
            formatted,
            type: :auto_gm_narration
          )

          # Log for remote participants too
          IcActivityService.record_for(
            recipients: [participant], content: formatted[:content],
            sender: nil, type: :auto_gm, html: formatted[:html]
          )
        end

        true
      end

      # Execute roll request - ask for a skill check
      # @param session [AutoGmSession] the session
      # @param action [AutoGmAction] the action record
      # @param params [Hash] action parameters
      def execute_roll_request(session, action, params)
        params ||= {}
        target_ids = Array(params['target_character_ids'] || session.participant_ids).map(&:to_i).uniq
        return false if target_ids.empty?

        roll_type = params['roll_type'] || 'skill check'
        dc = params['roll_dc'] || 10
        stat_name = params['roll_stat'] || 'Physical'

        # Resolve stat name to actual Stat record
        resolved_stat = session.resolve_stat_by_name(stat_name)
        stat_display = resolved_stat ? resolved_stat.name : stat_name

        message = "<strong>Roll Required:</strong> #{roll_type} (DC #{dc}, #{stat_display})"

        target_ids.each do |char_id|
          instance = CharacterInstance[char_id]
          next unless instance

          BroadcastService.to_character(
            instance,
            format_gm_message(message),
            type: :auto_gm_roll_request,
            roll_data: { dc: dc, stat: stat_display, stat_id: resolved_stat&.id, roll_type: roll_type }
          )
        end

        # Store roll request info in action data (deep-dup for JSONB dirty-tracking)
        data = JSON.parse((action.action_data || {}).to_json)
        data.merge!(
          'roll_pending' => true,
          'roll_targets' => target_ids,
          'roll_dc' => dc,
          'roll_stat' => stat_display,
          'roll_stat_id' => resolved_stat&.id
        )
        action.update(action_data: Sequel.pg_jsonb_wrap(data))

        true
      end

      # Execute move - move characters to a new room
      # @param session [AutoGmSession] the session
      # @param action [AutoGmAction] the action record
      # @param params [Hash] action parameters
      def execute_move(session, action, params)
        params ||= {}
        destination_id = params['destination_room_id']
        return false unless destination_id

        destination = Room[destination_id]
        return false unless destination

        target_ids = params['target_character_ids'] || session.participant_ids
        moved_instances = []

        target_ids.each do |char_id|
          instance = CharacterInstance[char_id]
          next unless instance

          # Use MovementService if available
          if defined?(MovementService) && MovementService.respond_to?(:start_movement)
            move_result = MovementService.start_movement(
              instance,
              target: destination,
              adverb: params['movement_adverb'] || 'walk'
            )
            next unless movement_successful?(move_result)
          else
            # Direct move as fallback with proper positioning
            instance.teleport_to_room!(destination)
          end

          moved_instances << instance
        end

        return false if moved_instances.empty?

        # Update session's current room
        session.update(current_room_id: destination.id)

        # Broadcast the move
        move_msg = format_gm_message("The adventure continues in #{destination.name}...")
        BroadcastService.to_room(
          destination.id,
          move_msg,
          type: :auto_gm_movement
        )

        # Log Auto-GM movement to character stories
        IcActivityService.record(
          room_id: destination.id, content: move_msg[:content],
          sender: nil, type: :auto_gm, html: move_msg[:html]
        )

        true
      end

      # Interpret MovementService return types consistently.
      # Supports Result objects, Hashes, booleans, and nil.
      # @param result [Object]
      # @return [Boolean]
      def movement_successful?(result)
        if result.respond_to?(:success)
          result.success
        elsif result.is_a?(Hash)
          result[:success] || result['success']
        elsif result.nil?
          warn "[AutoGmActionExecutor] movement result was nil — treating as failure"
          false
        else
          result == true
        end
      end

      # Execute spawn NPC - create an NPC
      # @param session [AutoGmSession] the session
      # @param action [AutoGmAction] the action record
      # @param params [Hash] action parameters
      def execute_spawn_npc(session, action, params)
        params ||= {}
        room_id = params['room_id'] || session.current_room_id
        room = Room[room_id]
        return false unless room

        archetype_hint = params['npc_archetype_hint']
        name_hint = params['name_hint'] || archetype_hint&.split(/[,.]/)&.first&.strip
        disposition = params['npc_disposition'] || 'neutral'

        # Find matching archetype
        archetype = find_archetype(archetype_hint)

        # Generate new adversary if no archetype found and generate flag is set
        if archetype.nil? && params['generate_if_missing'] != false
          archetype = generate_adversary_archetype(session, params)
        end

        if archetype && defined?(NpcSpawnService)
          npc = NpcSpawnService.spawn_from_template(
            archetype,
            room,
            auto_gm_session_id: session.id,
            disposition: disposition
          )

          if npc
            npc_name = DisplayHelper.character_display_name(npc)

            # Update action with spawn result (deep-dup for JSONB dirty-tracking)
            npc_data = JSON.parse((action.action_data || {}).to_json)
            npc_data.merge!('spawned_npc_id' => npc.id, 'spawned_npc_name' => npc_name)
            action.update(
              target_character_id: npc.character_id,
              action_data: Sequel.pg_jsonb_wrap(npc_data)
            )

            # Update world state
            update_world_state(session, 'npcs_spawned', {
              id: npc.id,
              name: npc_name,
              archetype: archetype.name,
              disposition: disposition
            })

            # Broadcast arrival
            npc_arrival_msg = format_gm_message("#{npc_name} arrives.")
            BroadcastService.to_room(
              room_id,
              npc_arrival_msg,
              type: :auto_gm_npc_spawn
            )

            # Log Auto-GM NPC spawn to character stories
            IcActivityService.record(
              room_id: room_id, content: npc_arrival_msg[:content],
              sender: nil, type: :auto_gm, html: npc_arrival_msg[:html]
            )
            return true
          end
        end

        # Spawn failed — record as a narrative-only NPC so the GM doesn't retry
        warn "[AutoGmExecutor] NPC spawn failed for '#{archetype_hint}', recording as narrative NPC"
        update_world_state(session, 'npcs_spawned', {
          name: name_hint || 'unknown NPC',
          disposition: disposition,
          narrative_only: true
        })

        true
      end

      # Execute spawn item - create an item in a room
      # @param session [AutoGmSession] the session
      # @param action [AutoGmAction] the action record
      # @param params [Hash] action parameters
      def execute_spawn_item(session, action, params)
        params ||= {}
        room_id = params['room_id'] || session.current_room_id
        room = Room[room_id]
        return false unless room

        description = params['item_description'] || params['description']
        return false if description.nil? || description.strip.empty?

        item_name = params['item_name'] || description

        # Find pattern by ID or search by description
        pattern = find_pattern_for_item(description, params)

        unless pattern
          # No pattern found - just broadcast narrative without creating item
          warn "[AutoGmActionExecutor] No pattern found for item: #{description}"
          update_world_state(session, 'items_appeared', {
            description: description,
            room_id: room_id,
            spawned: false,
            reason: 'no_pattern_found'
          })

          item_msg = format_gm_message("Something catches your eye: #{description}")
          BroadcastService.to_room(
            room_id,
            item_msg,
            type: :auto_gm_item_spawn
          )

          # Log Auto-GM item spawn to character stories
          IcActivityService.record(
            room_id: room_id, content: item_msg[:content],
            sender: nil, type: :auto_gm, html: item_msg[:html]
          )
          return true
        end

        # Create actual item in the room
        item = pattern.instantiate(
          name: item_name,
          room: room,
          quantity: params['quantity'] || 1,
          condition: params['condition'] || 'good'
        )

        if item&.id
          # Update action with item info (deep-dup for JSONB dirty-tracking)
          item_data = JSON.parse((action.action_data || {}).to_json)
          item_data.merge!('spawned_item_id' => item.id, 'spawned_item_name' => item.name)
          action.update(action_data: Sequel.pg_jsonb_wrap(item_data))

          # Track with actual item ID
          update_world_state(session, 'items_appeared', {
            id: item.id,
            name: item.name,
            description: description,
            room_id: room_id,
            spawned: true
          })

          item_found_msg = format_gm_message("Something catches your eye: #{item.name}")
          BroadcastService.to_room(
            room_id,
            item_found_msg,
            type: :auto_gm_item_spawn
          )

          # Log Auto-GM item spawn to character stories
          IcActivityService.record(
            room_id: room_id, content: item_found_msg[:content],
            sender: nil, type: :auto_gm, html: item_found_msg[:html]
          )
          return true
        else
          warn "[AutoGmActionExecutor] Failed to instantiate item from pattern #{pattern.id}"
          update_world_state(session, 'items_appeared', {
            description: description,
            room_id: room_id,
            spawned: false,
            reason: 'instantiation_failed'
          })

          item_fail_msg = format_gm_message("Something catches your eye: #{description}")
          BroadcastService.to_room(
            room_id,
            item_fail_msg,
            type: :auto_gm_item_spawn
          )

          # Log Auto-GM item spawn to character stories
          IcActivityService.record(
            room_id: room_id, content: item_fail_msg[:content],
            sender: nil, type: :auto_gm, html: item_fail_msg[:html]
          )
          return true
        end
      end

      # Find a pattern for spawning an item
      # @param description [String, nil] item description to search for
      # @param params [Hash] action parameters (may contain pattern_id)
      # @return [Pattern, nil]
      def find_pattern_for_item(description, params)
        # If pattern_id is provided, use it directly
        if params['pattern_id']
          pattern = Pattern[params['pattern_id']]
          return pattern if pattern
        end

        # Search by description (case-insensitive partial match)
        return nil unless description && !description.strip.empty?

        escaped_desc = QueryHelper.escape_like(description)
        Pattern.where(Sequel.ilike(:description, "%#{escaped_desc}%")).first ||
          Pattern.where(Sequel.ilike(:desc_desc, "%#{escaped_desc}%")).first
      rescue StandardError => e
        warn "[AutoGmActionExecutor] Pattern lookup failed: #{e.message}"
        nil
      end

      # Execute reveal secret - reveal a secret from the sketch
      # @param session [AutoGmSession] the session
      # @param action [AutoGmAction] the action record
      # @param params [Hash] action parameters
      def execute_reveal_secret(session, action, params)
        params ||= {}
        secret_index = params['secret_index'] || 0
        secrets = session.sketch.dig('secrets_twists', 'secrets') || []
        secret = secrets[secret_index]

        return false unless secret

        # Broadcast the revelation
        room_id = session.current_room_id || session.starting_room_id
        revelation_msg = format_revelation_message(secret)
        BroadcastService.to_room(
          room_id,
          revelation_msg,
          type: :auto_gm_revelation
        )

        # Log Auto-GM revelation to character stories
        IcActivityService.record(
          room_id: room_id, content: revelation_msg[:content],
          sender: nil, type: :auto_gm, html: revelation_msg[:html]
        )

        # Update world state
        update_world_state(session, 'secrets_revealed', secret)
        true
      end

      # Execute trigger twist - activate the adventure's twist
      # @param session [AutoGmSession] the session
      # @param action [AutoGmAction] the action record
      # @param params [Hash] action parameters
      def execute_trigger_twist(session, action, params)
        params ||= {}
        twist = session.sketch['secrets_twists'] || {}
        twist_description = twist['twist_description']

        return false unless twist_description

        room_id = session.current_room_id || session.starting_room_id
        twist_msg = format_twist_message(twist_description)
        BroadcastService.to_room(
          room_id,
          twist_msg,
          type: :auto_gm_twist
        )

        # Log Auto-GM twist to character stories
        IcActivityService.record(
          room_id: room_id, content: twist_msg[:content],
          sender: nil, type: :auto_gm, html: twist_msg[:html]
        )

        # Update world state
        update_world_state(session, 'twist_triggered', {
          type: twist['twist_type'],
          description: twist_description,
          triggered_at: Time.now.iso8601
        })

        # Increase chaos after a twist
        session.adjust_chaos!(1)
        true
      end

      # Execute advance stage - progress to next stage
      # @param session [AutoGmSession] the session
      # @param action [AutoGmAction] the action record
      # @param params [Hash] action parameters
      def execute_advance_stage(session, action, params)
        params ||= {}
        new_stage = session.current_stage + 1
        stages = session.sketch.dig('structure', 'stages') || []

        return false if new_stage >= stages.length

        session.advance_stage!

        stage_info = stages[new_stage]
        if stage_info
          room_id = session.current_room_id || session.starting_room_id
          stage_msg = format_stage_message(stage_info)
          BroadcastService.to_room(
            room_id,
            stage_msg,
            type: :auto_gm_stage_transition
          )

          # Log Auto-GM stage transition to character stories
          IcActivityService.record(
            room_id: room_id, content: stage_msg[:content],
            sender: nil, type: :auto_gm, html: stage_msg[:html]
          )
        end
        true
      end

      # Execute start climax - begin climax phase
      # @param session [AutoGmSession] the session
      # @param action [AutoGmAction] the action record
      # @param params [Hash] action parameters
      def execute_start_climax(session, action, params)
        session.update(status: 'climax')

        room_id = session.current_room_id || session.starting_room_id
        climax_msg = format_gm_message("<strong>The climax begins!</strong> The moment of truth is at hand.")
        BroadcastService.to_room(
          room_id,
          climax_msg,
          type: :auto_gm_climax
        )

        # Log Auto-GM climax to character stories
        IcActivityService.record(
          room_id: room_id, content: climax_msg[:content],
          sender: nil, type: :auto_gm, html: climax_msg[:html]
        )
        true
      end

      # Execute resolve - end the adventure
      # @param session [AutoGmSession] the session
      # @param action [AutoGmAction] the action record
      # @param params [Hash] action parameters
      def execute_resolve(session, action, params)
        params ||= {}
        resolution_type = params['resolution_type'] || 'success'

        # Use ResolutionService if available
        if defined?(AutoGm::AutoGmResolutionService)
          result = AutoGm::AutoGmResolutionService.resolve(
            session,
            resolution_type: resolution_type.to_sym
          )
          return result[:success] if result.is_a?(Hash)

          return true
        else
          # Simple resolution
          session.resolve!(resolution_type.to_sym)

          room_id = session.current_room_id || session.starting_room_id
          message = resolution_type == 'success' ?
            "<strong>Adventure Complete!</strong> #{session.sketch['title']} - Victory!" :
            "<strong>Adventure Failed!</strong> #{session.sketch['title']} - The mission was not completed."

          resolve_msg = format_gm_message(message)
          BroadcastService.to_room(
            room_id,
            resolve_msg,
            type: :auto_gm_resolution
          )

          # Log Auto-GM resolution to character stories
          IcActivityService.record(
            room_id: room_id, content: resolve_msg[:content],
            sender: nil, type: :auto_gm, html: resolve_msg[:html]
          )
          true
        end
      end

      # NOTE: format_gm_message, format_revelation_message, format_twist_message,
      #       format_stage_message are inherited from AutoGmFormatHelper

      # NOTE: find_archetype and generate_adversary_archetype are provided
      # by AutoGmArchetypeConcern (extended above)

      # Update world state
      # @param session [AutoGmSession] the session
      # @param key [String] state key
      # @param value [Object] value to add
      def update_world_state(session, key, value)
        # Must deep-dup to avoid Sequel JSONB dirty-tracking issue
        state = JSON.parse((session.world_state || {}).to_json)
        state[key] ||= []
        state[key] << value if value.is_a?(Hash) || value.is_a?(String)
        state[key] = value if [true, false].include?(value) || value.is_a?(Integer)
        session.update(world_state: Sequel.pg_jsonb_wrap(state))
      end
    end
  end
end
