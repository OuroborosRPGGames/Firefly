# frozen_string_literal: true

module Commands
  module AutoGm
    # Main command for Auto-GM spontaneous adventures.
    # Start an AI-driven adventure based on your current location and nearby world memories.
    class Autogm < Commands::Base::Command
      command_name 'autogm'
      aliases 'agm', 'adventure'
      category :staff
      help_text 'Start and manage AI-driven spontaneous adventures'
      usage 'autogm <subcommand> [arguments]'
      examples(
        'autogm start',
        'autogm start with Bob',
        'autogm status',
        'autogm end',
        'autogm end success',
        'autogm end failure'
      )

      # Alias for location (used throughout this command)
      def room
        location
      end

      def perform_command(parsed_input)
        args = parsed_input[:args]
        subcommand = args.first&.downcase
        sub_args = args[1..] || []

        case subcommand
        when 'start', 'begin', 'new'
          start_adventure(sub_args)
        when 'status', 'stat', 'info'
          show_status
        when 'leave'
          leave_adventure
        when 'end', 'stop', 'quit', 'abort'
          end_adventure(sub_args)
        when nil, '', 'help'
          show_usage
        else
          error_result("Unknown subcommand: #{subcommand}\nUse 'autogm' for help.")
        end
      end

      private

      # Start a new Auto-GM adventure
      def start_adventure(args)
        return error_result('Auto-GM is currently disabled by staff.') unless auto_gm_enabled?

        # Check if there's already an active session
        existing = ::AutoGm::AutoGmSessionService.active_session_in_room(room)
        if existing
          return error_result(
            "There's already an active adventure in this room: #{existing.sketch&.dig('title') || 'Untitled'}\n" \
            "Use 'autogm status' to see progress or 'autogm end' to stop it."
          )
        end

        # Check if character is already in a session
        active = ::AutoGm::AutoGmSessionService.active_sessions_for(character_instance)
        if active.any?
          titles = active.map { |s| s.sketch&.dig('title') || 'Untitled' }.join(', ')
          return error_result("You're already in an adventure: #{titles}\nUse 'autogm end' first.")
        end

        # Parse participants (with <name>)
        participants = [character_instance]

        if args.any?
          # Look for "with <names>" pattern
          if args.first&.downcase == 'with'
            args = args[1..]
          end

          # Find each named character in the room
          args.each do |name|
            next if name.empty?

            char = find_character_in_room(name)
            unless char
              return error_result("Could not find '#{name}' in this room.")
            end

            if char.id != character_instance.id
              participants << char
            end
          end
        end

        # Start the session
        begin
          session = ::AutoGm::AutoGmSessionService.start_session(
            room: room,
            participants: participants,
            trigger_context: { initiator_id: character_instance.character_id }
          )

          lines = [
            'Starting a new Auto-GM adventure...',
            "Gathering context from nearby memories and locations...",
            "Participants: #{participants.map { |p| p.character.name }.join(', ')}",
            '',
            "The AI is designing your adventure. This may take a moment.",
            "You'll be notified when the inciting incident occurs.",
            '',
            "Use 'autogm status' to check progress."
          ]

          success_result(lines.join("\n"), type: :message, data: { session_id: session.id })
        rescue ArgumentError => e
          error_result("Could not start adventure: #{e.message}")
        rescue StandardError => e
          error_result("Error starting adventure: #{e.message}")
        end
      end

      # Show adventure status
      def show_status
        # Find active session for this character
        sessions = ::AutoGm::AutoGmSessionService.active_sessions_for(character_instance)

        if sessions.empty?
          # Check room for any session
          room_session = ::AutoGm::AutoGmSessionService.active_session_in_room(room)
          if room_session
            return show_session_status(room_session, participating: false)
          end

          return error_result(
            "You're not in any active adventure.\n" \
            "Use 'autogm start' to begin one."
          )
        end

        # Show status of first active session
        show_session_status(sessions.first, participating: true)
      end

      # Show status for a specific session
      def show_session_status(session, participating:)
        status = ::AutoGm::AutoGmSessionService.status(session)

        lines = []

        # Header
        if status[:title]
          lines << "Adventure: #{status[:title]}"
        else
          lines << "Adventure: (being designed...)"
        end

        lines << "Status: #{status[:status].capitalize}"
        lines << ''

        # Progress
        if status[:total_stages] > 0
          lines << "Progress: Stage #{status[:current_stage] + 1} of #{status[:total_stages]}"
        end

        if status[:countdown]
          lines << "Countdown: #{status[:countdown]}"
        end

        lines << "Chaos Level: #{status[:chaos_level]}/9"
        lines << "Actions: #{status[:action_count]}"

        # Show stat system if available
        if session.stat_block_id
          lines << "Stats: #{session.stat_names_for_prompt}"
        end

        # Time info
        if status[:started_at]
          elapsed_min = (status[:elapsed_seconds] / 60.0).round(1)
          timeout_min = (status[:timeout_in_seconds] / 60.0).round(1) if status[:timeout_in_seconds]
          lines << "Elapsed: #{elapsed_min} minutes"
          lines << "Timeout in: #{timeout_min} minutes" if timeout_min && timeout_min > 0
        end

        # Combat status
        lines << 'Currently in combat!' if status[:in_combat]

        # Resolution
        if status[:resolved]
          lines << ''
          lines << "Resolution: #{status[:resolution_type].upcase}"
        end

        # Participation notice
        unless participating
          lines << ''
          lines << "(You are not participating in this adventure)"
        end

        # Recent context
        context = ::AutoGm::AutoGmCompressionService.get_relevant_summary(session)
        if context && !context.empty? && context != 'The adventure has just begun.'
          lines << ''
          lines << 'Recent events:'
          truncated_context = context.length > 200 ? "#{context[0..196]}..." : context
          lines << "  #{truncated_context}"
        end

        success_result(lines.join("\n"), type: :message)
      end

      # End the current adventure
      def end_adventure(args)
        sessions = ::AutoGm::AutoGmSessionService.active_sessions_for(character_instance)

        if sessions.empty?
          return error_result("You're not in any active adventure.")
        end

        session = sessions.first

        # Parse resolution type
        resolution_type = :abandoned
        reason = 'Ended by player'

        case args.first&.downcase
        when 'success', 'win', 'victory'
          resolution_type = :success
          reason = 'Player declared success'
        when 'failure', 'fail', 'defeat'
          resolution_type = :failure
          reason = 'Player declared failure'
        end

        # Check if they're the initiator
        initiator_id = session.created_by_id
        is_initiator = initiator_id == character_instance.character_id

        unless is_initiator
          return error_result(
            "Only the adventure initiator can end it.\n" \
            "Use 'autogm leave' to leave this adventure."
          )
        end

        # End the session
        result = ::AutoGm::AutoGmSessionService.end_session(
          session,
          resolution_type: resolution_type,
          reason: reason
        )

        if result[:success]
          lines = [
            "Adventure '#{session.sketch&.dig('title') || 'Untitled'}' has ended.",
            "Resolution: #{resolution_type.to_s.upcase}"
          ]

          if result[:memory]
            lines << ''
            lines << 'A memory of this adventure has been recorded for the world.'
          end

          success_result(lines.join("\n"), type: :message)
        else
          error_result("Failed to end adventure: #{result[:error]}")
        end
      end

      # Leave the current adventure without ending it for everyone.
      # If this is the final participant, the session is abandoned.
      def leave_adventure
        sessions = ::AutoGm::AutoGmSessionService.active_sessions_for(character_instance)
        return error_result("You're not in any active adventure.") if sessions.empty?

        session = sessions.first
        result = ::AutoGm::AutoGmSessionService.leave_session(session, character_instance)

        return error_result("Could not leave adventure: #{result[:error]}") unless result[:success]

        if result[:ended]
          lines = [
            "You leave '#{session.sketch&.dig('title') || 'Untitled'}'.",
            'You were the last participant, so the adventure has ended.'
          ]
          success_result(lines.join("\n"), type: :message)
        else
          success_result("You leave '#{session.sketch&.dig('title') || 'Untitled'}'.", type: :message)
        end
      end

      # Show usage information
      def show_usage
        lines = [
          'Auto-GM Commands:',
          '',
          '  autogm start              - Start a new spontaneous adventure',
          '  autogm start with <names> - Start with specific party members',
          '  autogm status             - Show current adventure status',
          '  autogm leave              - Leave an active adventure',
          '  autogm end                - Abandon the adventure',
          '  autogm end success        - End with success resolution',
          '  autogm end failure        - End with failure resolution',
          '',
          'The Auto-GM system creates spontaneous adventures based on your',
          'current location and nearby world memories. An AI Game Master will',
          'guide you through the adventure, reacting to your actions.',
          '',
          "Adventures timeout after 2 hours of inactivity.",
          '',
          'Tip: Use social commands like "say" and "emote" to interact',
          'with the adventure. The AI will respond to your actions!'
        ]
        success_result(lines.join("\n"), type: :message)
      end

      # Uses inherited find_character_in_room from base command

      def auto_gm_enabled?
        ::AutoGm::AutoGmSessionService.auto_gm_enabled?
      end
    end
  end
end

# REQUIRED: Register with the command registry
Commands::Base::Registry.register(Commands::AutoGm::Autogm)
