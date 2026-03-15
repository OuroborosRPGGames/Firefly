# frozen_string_literal: true

module Commands
  module Activity
    # Command for remote observation of activities.
    # Allows players to support or oppose participants from outside the activity.
    class Observe < Commands::Base::Command
      command_name 'aobserve'
      aliases 'obs', 'activity observe'
      category :events
      help_text 'Observe and interact with activities remotely'
      usage 'observe <subcommand> [arguments]'
      examples(
        'observe status',
        'observe leave',
        'observe actions',
        'observe support Player',
        'observe oppose Player',
        'observe accept Player',
        'observe reject Player',
        'observe action stat_swap Player'
      )

      requires :character

      REDIS_REQUEST_TTL = 120 # 2 minutes

      def perform_command(parsed_input)
        args = parsed_input[:args]
        subcommand = args.first&.downcase
        sub_args = args[1..] || []

        case subcommand
        when 'status', 'stat'
          show_status
        when 'leave', 'quit'
          leave_observation
        when 'actions', 'list'
          list_actions
        when 'support'
          request_observe(sub_args, role: 'support')
        when 'oppose'
          request_observe(sub_args, role: 'oppose')
        when 'accept'
          accept_observer(sub_args)
        when 'reject', 'deny'
          reject_observer(sub_args)
        when 'action'
          submit_action(sub_args)
        else
          show_usage
        end
      end

      private

      # Find the current active observation for this character
      def current_observation
        ActivityRemoteObserver.where(
          character_instance_id: character_instance.id,
          active: true
        ).first
      end

      # Show observation status
      def show_status
        obs = current_observation

        unless obs
          return error_result('You are not observing any activity.')
        end

        instance = obs.activity_instance
        activity = instance&.activity

        lines = [
          "Observing: #{activity&.display_name || 'Unknown Activity'}",
          "Role: #{obs.role.capitalize}",
          "Round: #{instance&.rounds_done || 0}"
        ]

        if obs.has_action?
          lines << ''
          lines << "Queued action: #{obs.action_type}"
          if obs.action_target_id
            target = ActivityParticipant[obs.action_target_id]
            lines << "  Target: #{target&.character&.full_name || 'Unknown'}"
          end
        end

        success_result(lines.join("\n"), type: :message)
      end

      # List available actions for current round type
      def list_actions
        obs = current_observation

        unless obs
          return error_result('You are not observing any activity.')
        end

        instance = obs.activity_instance
        round = instance&.current_round
        round_type = round&.round_type&.to_sym || :standard

        actions = obs.available_actions(round_type)

        if actions.empty?
          return success_result('No actions available for this round type.')
        end

        lines = ["Available #{obs.role} actions for #{round_type} round:"]
        actions.each_with_index do |action, idx|
          lines << "  #{idx + 1}. #{action}"
        end
        lines << ''
        lines << "Use 'observe action <type> <target>' to submit an action."

        success_result(lines.join("\n"), type: :message)
      end

      # Stop observing
      def leave_observation
        obs = current_observation

        unless obs
          return error_result('You are not observing any activity.')
        end

        obs.update(active: false)
        success_result('You have stopped observing the activity.')
      end

      # Request to observe a player's activity
      def request_observe(args, role:)
        target_name = args.join(' ')

        if target_name.empty?
          return error_result("Usage: observe #{role} <player name>")
        end

        # Find target character in the room
        target = find_character_in_room(target_name)
        unless target
          return error_result("Could not find player '#{target_name}' in this room.")
        end

        # Find their active activity participation
        # ActivityParticipant uses char_id which is the character's id, not character_instance_id
        participation = ActivityParticipant.where(char_id: target.character.id, continue: true)
                                           .all
                                           .find { |p| p.instance&.running? }

        unless participation
          return error_result("#{target.character.full_name} is not currently participating in any activity.")
        end

        # Check if already observing something
        if current_observation
          return error_result("You are already observing an activity. Use 'observe leave' first.")
        end

        # Store request in Redis
        request_key = observe_request_key(character_instance.id, target.id, role)
        request_data = {
          requester_id: character_instance.id,
          requester_name: character_instance.character.full_name,
          target_id: target.id,
          activity_instance_id: participation.instance_id,
          role: role,
          requested_at: Time.now.iso8601
        }

        redis_store(request_key, request_data, ttl: REDIS_REQUEST_TTL)

        # Notify target
        BroadcastService.to_character(
          target,
          "#{character_instance.character.full_name} wants to #{role} you in your activity. " \
          "Use 'observe accept #{character_instance.character.forename}' or 'observe reject #{character_instance.character.forename}'.",
          type: :system
        )

        success_result(
          "You have sent a #{role} request to #{target.character.full_name}. " \
          'They have 2 minutes to accept or reject.',
          type: :message
        )
      end

      # Accept an observe request
      def accept_observer(args)
        requester_name = args.join(' ')

        if requester_name.empty?
          return error_result('Usage: observe accept <player name>')
        end

        # Find requester in room
        requester = find_character_in_room(requester_name)
        unless requester
          return error_result("Could not find player '#{requester_name}' in this room.")
        end

        # Check for pending request (try both roles)
        request_data = nil
        role = nil
        %w[support oppose].each do |r|
          key = observe_request_key(requester.id, character_instance.id, r)
          data = redis_fetch(key)
          if data
            request_data = data
            role = r
            redis_delete(key)
            break
          end
        end

        unless request_data
          return error_result("No pending observe request from #{requester.character.full_name}.")
        end

        # Find my active participation
        participation = ActivityParticipant.where(char_id: character_instance.character.id, continue: true)
                                           .all
                                           .find { |p| p.instance&.running? }

        unless participation
          return error_result('You are not currently participating in any activity.')
        end

        existing_observation = ActivityRemoteObserver.where(
          character_instance_id: requester.id,
          active: true
        ).first
        if existing_observation
          return error_result("#{requester.character.full_name} is already observing another activity.")
        end

        # Create the remote observer
        observer = ActivityRemoteObserver.create(
          activity_instance_id: participation.instance_id,
          character_instance_id: requester.id,
          consented_by_id: character_instance.id,
          role: role,
          active: true
        )

        # Notify requester
        BroadcastService.to_character(
          requester,
          "#{character_instance.character.full_name} accepted your #{role} request. " \
          "Use 'observe status' to see your observation and 'observe actions' to see available actions.",
          type: :system
        )

        success_result(
          "You accepted #{requester.character.full_name}'s request to #{role} you.",
          type: :message
        )
      rescue Sequel::UniqueConstraintViolation
        error_result("#{requester.character.full_name} is already observing another activity.")
      end

      # Reject an observe request
      def reject_observer(args)
        requester_name = args.join(' ')

        if requester_name.empty?
          return error_result('Usage: observe reject <player name>')
        end

        # Find requester in room
        requester = find_character_in_room(requester_name)
        unless requester
          return error_result("Could not find player '#{requester_name}' in this room.")
        end

        # Delete any pending requests from this requester
        deleted = false
        %w[support oppose].each do |role|
          key = observe_request_key(requester.id, character_instance.id, role)
          if redis_fetch(key)
            redis_delete(key)
            deleted = true
          end
        end

        unless deleted
          return error_result("No pending observe request from #{requester.character.full_name}.")
        end

        # Notify requester
        BroadcastService.to_character(
          requester,
          "#{character_instance.character.full_name} rejected your observe request.",
          type: :system
        )

        success_result(
          "You rejected #{requester.character.full_name}'s observe request.",
          type: :message
        )
      end

      # Submit an action as observer
      def submit_action(args)
        obs = current_observation

        unless obs
          return error_result('You are not observing any activity.')
        end

        if args.length < 2
          return error_result("Usage: observe action <type> <target> [secondary_target] [message]\nUse 'observe actions' to see available action types.")
        end

        action_type = args[0]
        target_name = args[1]
        secondary_target_name = args[2] if args.length > 2 && !args[2].start_with?('"')
        message = args[3..].join(' ') if args.length > 3

        # Handle quoted message
        if args.length > 2 && args[2..].join(' ').start_with?('"')
          message = args[2..].join(' ').gsub(/^"|"$/, '')
          secondary_target_name = nil
        end

        # Validate action type
        instance = obs.activity_instance
        round = instance&.current_round
        round_type = round&.round_type&.to_sym || :standard
        valid_actions = obs.available_actions(round_type)

        unless valid_actions.include?(action_type)
          return error_result("Invalid action '#{action_type}'. Use 'observe actions' to see available actions.")
        end

        # Find target participant
        participants = instance.participants
        target_participant = participants.find do |p|
          char = p.character
          char && (char.full_name.downcase.include?(target_name.downcase) ||
                   char.forename.downcase.include?(target_name.downcase))
        end

        unless target_participant
          return error_result("Could not find participant '#{target_name}' in the activity.")
        end

        # Find secondary target if provided
        secondary_target_id = nil
        if secondary_target_name
          secondary_participant = participants.find do |p|
            char = p.character
            char && (char.full_name.downcase.include?(secondary_target_name.downcase) ||
                     char.forename.downcase.include?(secondary_target_name.downcase))
          end
          secondary_target_id = secondary_participant&.id
        end

        # Submit the action
        obs.submit_action!(
          type: action_type,
          target_id: target_participant.id,
          secondary_target_id: secondary_target_id,
          message: message
        )

        lines = ["Action queued: #{action_type}"]
        lines << "  Target: #{target_participant.character.full_name}"
        lines << "  Secondary: #{secondary_participant.character.full_name}" if secondary_target_id
        lines << "  Message: #{message}" if message

        success_result(lines.join("\n"), type: :message)
      end

      # Show usage information
      def show_usage
        lines = [
          'Observe Commands:',
          '  observe status           - Show your current observation status',
          '  observe leave            - Stop observing an activity',
          '  observe actions          - List available actions for your role',
          '',
          'Requesting to observe:',
          '  observe support <player> - Request to support a player in their activity',
          '  observe oppose <player>  - Request to oppose a player in their activity',
          '',
          'Responding to requests:',
          '  observe accept <player>  - Accept an observe request',
          '  observe reject <player>  - Reject an observe request',
          '',
          'Submitting actions:',
          '  observe action <type> <target> [secondary] [message]'
        ]
        success_result(lines.join("\n"), type: :message)
      end

      # Uses inherited find_character_in_room from base command

      # Redis key for observe requests
      def observe_request_key(requester_id, target_id, role)
        "observe_request:#{requester_id}:#{target_id}:#{role}"
      end

      # Redis helpers
      def redis_store(key, value, ttl: REDIS_REQUEST_TTL)
        REDIS_POOL.with { |redis| redis.setex(key, ttl, value.to_json) }
      rescue StandardError => e
        warn "[Observe] Redis store failed: #{e.message}"
      end

      def redis_fetch(key)
        data = REDIS_POOL.with { |redis| redis.get(key) }
        data ? JSON.parse(data, symbolize_names: true) : nil
      rescue StandardError => e
        warn "[Observe] Redis fetch failed: #{e.message}"
        nil
      end

      def redis_delete(key)
        REDIS_POOL.with { |redis| redis.del(key) }
      rescue StandardError => e
        warn "[Observe] Redis delete failed: #{e.message}"
      end
    end
  end
end

# REQUIRED: Register with the command registry
Commands::Base::Registry.register(Commands::Activity::Observe)
