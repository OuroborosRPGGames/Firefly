# frozen_string_literal: true

module Commands
  module Events
    class Camera < Commands::Base::Command
      command_name 'camera'
      aliases 'spotlight'
      category :events
      help_text 'Toggle spotlight on a character during an event (host/staff only)'
      usage 'camera <character> [count]'
      examples 'camera Alice', 'spotlight Bob', 'spotlight Bob 3'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:text]&.strip

        if blank?(args)
          return error_result("Spotlight whom? Use: camera <character> [count]")
        end

        # Parse target name and optional count
        target_name, count = parse_arguments(args)

        # Find an active event where we have authority
        event = Event.find_controllable_by(character, location)
        unless event
          return error_result("You're not hosting or staffing an active event here.")
        end

        # Find target in room
        target = find_character_in_room(target_name)
        unless target
          return error_result("#{target_name} is not here.")
        end

        target_char = target.character

        # If already spotlighted with no count, toggle off
        # If count provided, turn on with count
        # If not spotlighted with no count, toggle on (unlimited)
        if count
          # Spotlight with specific count
          target.spotlight_on!(count: count)
          broadcast_to_room(
            "The spotlight focuses on #{target_char.full_name}.",
            exclude_character: nil
          )
          success_result(
            "You focus the spotlight on #{target_char.full_name} for #{count} emotes.",
            type: :message,
            data: {
              action: 'camera_on',
              target_id: target.id,
              target_name: target_char.full_name,
              event_id: event.id,
              event_name: event.name,
              spotlight_count: count
            }
          )
        elsif target.spotlighted?
          # Toggle off
          target.spotlight_off!
          broadcast_to_room(
            "The spotlight moves away from #{target_char.full_name}.",
            exclude_character: nil
          )
          success_result(
            "You move the spotlight away from #{target_char.full_name}.",
            type: :message,
            data: {
              action: 'camera_off',
              target_id: target.id,
              target_name: target_char.full_name,
              event_id: event.id,
              event_name: event.name
            }
          )
        else
          # Toggle on (unlimited/one-shot)
          target.spotlight_on!
          broadcast_to_room(
            "The spotlight focuses on #{target_char.full_name}.",
            exclude_character: nil
          )
          success_result(
            "You focus the spotlight on #{target_char.full_name}.",
            type: :message,
            data: {
              action: 'camera_on',
              target_id: target.id,
              target_name: target_char.full_name,
              event_id: event.id,
              event_name: event.name
            }
          )
        end
      end

      private

      # Parse arguments into target name and optional count
      # "Bob" -> ["Bob", nil]
      # "Bob 3" -> ["Bob", 3]
      # "Bob Smith" -> ["Bob Smith", nil]
      # "Bob Smith 5" -> ["Bob Smith", 5]
      def parse_arguments(args)
        parts = args.split(/\s+/)

        # Check if last part is a number
        if parts.length > 1 && parts.last.match?(/^\d+$/)
          count = parts.pop.to_i
          target_name = parts.join(' ')
          [target_name, count > 0 ? count : nil]
        else
          [args, nil]
        end
      end

      # Uses inherited find_character_in_room from base command
    end
  end
end

Commands::Base::Registry.register(Commands::Events::Camera)
