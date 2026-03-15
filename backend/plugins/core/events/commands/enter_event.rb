# frozen_string_literal: true

module Commands
  module Events
    class EnterEvent < Commands::Base::Command
      command_name 'enter event'
      aliases 'enterevent', 'join event', 'joinevent'
      category :events
      help_text 'Join an active event at your current location'
      usage 'enter event'
      examples 'enter event', 'join event'

      protected

      def perform_command(_parsed_input)
        if character_instance.in_event?
          return error_result("You are already in an event.")
        end

        event = find_active_event
        return error_result("There is no active event here.") unless event

        enter_event(event)
      end

      private

      def find_active_event
        now = Time.now
        room = character_instance.current_room

        # Find active events at current room or location
        active = Event.where(status: 'active')
                      .where(Sequel.or(room_id: room.id, location_id: room.location_id))
                      .first
        return active if active

        # Find scheduled events within time window (within 1 hour, started within 12 hours)
        Event.where(status: 'scheduled')
             .where(Sequel.or(room_id: room.id, location_id: room.location_id))
             .where { starts_at <= now + 3600 }
             .where { starts_at >= now - (12 * 3600) }
             .first
      end

      def enter_event(event)
        # Auto-start if scheduled and we're the organizer
        if event.scheduled? && event.organizer_id == character.id
          begin
            start_result = EventService.start_event!(event)
            unless start_result[:success]
              return error_result(start_result[:error] || "Could not start event.")
            end
          rescue StandardError => e
            warn "[EnterEvent] EventService.start_event! failed, falling back to basic start: #{e.message}"
            event.start!
          end
        end
        broadcast_to_room(
          "#{character.full_name} enters #{event.name}.",
          exclude_character: character_instance
        )

        # Apply canonical entry checks/state update (capacity, bounced, active-state gate).
        result = EventService.enter_event!(event: event, character_instance: character_instance)
        unless result[:success]
          return error_result(result[:error] || "Unable to enter event.")
        end

        # Ensure attendee status is marked as checked-in/yes.
        attendee = EventAttendee.find_or_create(event_id: event.id, character_id: character.id)
        attendee.check_in!

        # Broadcast arrival to others in the event
        event.characters_in_event.exclude(id: character_instance.id).each do |ci|
          BroadcastService.to_character(ci, {
            type: 'event',
            content: "#{character.full_name} arrives."
          })
        end

        success_result(
          "You enter #{event.name}.",
          type: :event,
          data: {
            action: 'enter_event',
            event_id: event.id,
            event_name: event.name
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Events::EnterEvent)
