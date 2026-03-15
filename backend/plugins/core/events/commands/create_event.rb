# frozen_string_literal: true

module Commands
  module Events
    class CreateEvent < Commands::Base::Command
      command_name 'create event'
      aliases 'newevent', 'new event', 'createevent'
      category :events
      help_text 'Create a new event'
      usage 'create event [name]'
      examples 'create event', 'create event Birthday Party'

      protected

      def perform_command(parsed_input)
        args = parsed_input[:text].to_s.strip

        if args.empty?
          # Open modal for full event creation
          return modal_result
        end

        # Quick create with just name (defaults to starting in 1 hour at current room)
        quick_create(args)
      end

      private

      def modal_result
        success_result(
          "Opening event creation form...",
          type: :modal,
          data: {
            action: 'create_event',
            modal_type: 'create_event',
            defaults: {
              room_id: character_instance.current_room_id,
              room_name: character_instance.current_room&.name,
              location_id: character_instance.current_room&.location_id,
              location_name: character_instance.current_room&.location&.name,
              starts_at: (Time.now + 3600).iso8601, # Default: 1 hour from now
              event_type: 'party',
              is_public: true,
              logs_visible_to: 'public'
            }
          }
        )
      end

      def quick_create(name)
        # Sanitize: strip HTML tags from event name
        name = name.gsub(/<[^>]*>/, '').strip
        return error_result("Event name cannot be empty.") if name.empty?
        return error_result("Event name is too long (max 200 characters).") if name.length > 200

        room = character_instance.current_room

        result = begin
          EventService.create_event(
            organizer: character,
            name: name,
            starts_at: Time.now + 3600, # 1 hour from now
            room: room,
            event_type: 'party',
            is_public: true,
            logs_visible_to: 'public'
          )
        rescue Sequel::ValidationFailed => e
          return error_result("Could not create event: #{e.message}")
        end

        if result
          # Auto-add creator as attendee
          result.add_attendee(character, rsvp: 'yes')

          success_result(
            "Event '#{name}' created! It will start in 1 hour at #{room.name}. Use 'event info #{name}' to see details or 'start event' when ready.",
            type: :event,
            data: {
              action: 'event_created',
              event_id: result.id,
              event_name: result.name,
              starts_at: result.starts_at.iso8601
            }
          )
        else
          error_result("Failed to create event.")
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Events::CreateEvent)
