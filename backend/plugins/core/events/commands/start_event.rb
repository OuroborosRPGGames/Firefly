# frozen_string_literal: true

module Commands
  module Events
    class StartEvent < Commands::Base::Command
      command_name 'start event'
      aliases 'startevent', 'begin event', 'beginevent'
      category :events
      help_text 'Start a scheduled event (organizer only)'
      usage 'start event [name]'
      examples 'start event', 'start event Birthday Party'

      protected

      def perform_command(parsed_input)
        name = parsed_input[:text].to_s.strip

        event = if name.empty?
                  find_my_scheduled_event
                else
                  find_event_by_name(name)
                end

        return error_result("Event not found.") unless event
        return error_result("Only the organizer can start this event.") unless event.organizer_id == character.id
        return error_result("Event is already active.") if event.active?
        return error_result("Event has been completed.") if event.completed?
        return error_result("Event has been cancelled.") if event.cancelled?

        start_the_event(event)
      end

      private

      def find_my_scheduled_event
        room = character_instance.current_room

        # Find my scheduled event at current location
        Event.where(
          organizer_id: character.id,
          status: 'scheduled'
        ).where(
          Sequel.or(room_id: room.id, location_id: room.location_id)
        ).first
      end

      def find_event_by_name(name)
        Event.where(organizer_id: character.id)
             .where(Sequel.ilike(:name, name))
             .first ||
          Event.where(organizer_id: character.id)
               .where(Sequel.ilike(:name, "%#{name}%"))
               .first
      end

      def start_the_event(event)
        result = EventService.start_event!(event)

        if result[:success]
          # Broadcast to location that event is starting
          if event.room
            BroadcastService.to_room(event.room.id, {
              type: 'event',
              content: "#{event.name} is now starting! Use 'enter event' to join."
            }, exclude_character: character_instance)
          end

          # Auto-enter the organizer
          unless character_instance.in_event_id == event.id
            character_instance.enter_event!(event)
          end

          success_result(
            "#{event.name} has started! You are now hosting the event.",
            type: :event,
            data: {
              action: 'event_started',
              event_id: event.id,
              event_name: event.name
            }
          )
        else
          error_result(result[:error] || "Failed to start event.")
        end
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Events::StartEvent)
