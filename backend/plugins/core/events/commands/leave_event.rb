# frozen_string_literal: true

module Commands
  module Events
    class LeaveEvent < Commands::Base::Command
      command_name 'leave event'
      aliases 'leaveevent', 'exit event', 'exitevent'
      category :events
      help_text 'Leave the current event'
      usage 'leave event'
      examples 'leave event', 'exit event'

      protected

      def perform_command(_parsed_input)
        unless character_instance.in_event?
          return error_result("You're not in an event.")
        end

        event = character_instance.in_event
        return error_result("Event not found.") unless event

        leave_event(event)
      end

      private

      def leave_event(event)
        # Broadcast departure to others in the event
        event.characters_in_event.exclude(id: character_instance.id).each do |ci|
          BroadcastService.to_character(ci, {
            type: 'event',
            content: "#{character.full_name} leaves."
          })
        end

        # Update character instance
        character_instance.leave_event!

        # Broadcast return to room (outside event)
        broadcast_to_room(
          "#{character.full_name} leaves #{event.name}.",
          exclude_character: character_instance
        )

        success_result(
          "You leave #{event.name}.",
          type: :event,
          data: {
            action: 'leave_event',
            event_id: event.id,
            event_name: event.name
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Events::LeaveEvent)
