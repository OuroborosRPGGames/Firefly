# frozen_string_literal: true

module Commands
  module Events
    class EndEvent < Commands::Base::Command
      command_name 'end event'
      aliases 'endevent'
      category :events
      help_text 'End your event (host only)'
      usage 'end event'
      examples 'end event'

      protected

      def perform_command(_parsed_input)
        unless character_instance.in_event?
          return error_result("You're not in an event.")
        end

        event = character_instance.in_event
        return error_result("Event not found.") unless event

        unless event.organizer_id == character.id
          return error_result("You are not the host of this event.")
        end

        if event.completed? || event.cancelled?
          return error_result("This event has already ended.")
        end

        end_event(event)
      end

      private

      def end_event(event)
        # Collect all characters in the event for broadcasting
        characters_in_event = event.characters_in_event.eager(:character).all

        # Broadcast to all characters in the event
        characters_in_event.each do |ci|
          BroadcastService.to_character(ci, {
            type: 'event',
            content: "The event ends."
          })
        end

        # End the event through service so cleanup and world-memory side effects stay consistent.
        result = EventService.end_event!(event)
        unless result[:success]
          return error_result(result[:error] || "Failed to end event.")
        end

        broadcast_to_room(
          "#{event.name} has ended.",
          exclude_character: nil
        )

        success_result(
          "You have ended #{event.name}. All attendees have been notified.",
          type: :event,
          data: {
            action: 'end_event',
            event_id: event.id,
            event_name: event.name,
            attendee_count: characters_in_event.length
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Events::EndEvent)
