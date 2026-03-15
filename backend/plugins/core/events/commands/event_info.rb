# frozen_string_literal: true

module Commands
  module Events
    class EventInfo < Commands::Base::Command
      command_name 'event info'
      aliases 'eventinfo', 'event details', 'eventdetails'
      category :events
      help_text 'View details about an event'
      usage 'event info [name]'
      examples 'event info', 'event info Birthday Party'

      protected

      def perform_command(parsed_input)
        name = parsed_input[:text].to_s.strip

        event = if name.empty?
                  # Show current event if in one, or event at current location
                  find_current_event
                else
                  find_event_by_name(name)
                end

        return error_result("Event not found.") unless event

        show_event_details(event)
      end

      private

      def find_current_event
        # First check if in an event
        if character_instance.in_event?
          return Event[character_instance.in_event_id]
        end

        # Otherwise check for active event at current location
        EventService.find_event_at(character_instance.current_room)
      end

      def find_event_by_name(name)
        # Try exact match first
        event = Event.where(Sequel.ilike(:name, name)).first
        return event if event

        # Try partial match
        Event.where(Sequel.ilike(:name, "%#{name}%")).first
      end

      def show_event_details(event)
        is_organizer = event.organizer_id == character.id
        is_staff = EventService.is_host_or_staff?(event: event, character: character)
        is_attending = event.attending?(character)

        lines = []
        lines << "<h3>#{event.name}</h3>"
        lines << ""
        lines << "Status: #{event.status.capitalize}"
        lines << "Type: #{event.event_type.capitalize}"
        lines << "Public: #{event.is_public ? 'Yes' : 'No (Invite Only)'}"
        lines << ""
        lines << "Host: #{event.organizer&.name || 'Unknown'}"
        lines << "Location: #{event.room&.name || event.location&.name || 'TBD'}"
        lines << ""
        lines << "Starts: #{format_datetime(event.starts_at)}"
        lines << "Ends: #{event.ends_at ? format_datetime(event.ends_at) : 'Open-ended'}"
        lines << ""

        if event.description && !event.description.empty?
          lines << "Description:"
          lines << event.description
          lines << ""
        end

        lines << "Attendees: #{event.attendee_count}"
        if event.max_attendees
          lines << "Max Capacity: #{event.max_attendees}"
        end
        lines << ""

        # Show actions based on role
        actions = []
        if event.active?
          if character_instance.in_event_id == event.id
            actions << "'leave event' - Leave the event"
          else
            actions << "'enter event' - Join the event"
          end
        end

        if is_organizer || is_staff
          actions << "'end event' - End the event" if event.active?
          actions << "'start event' - Start the event" if event.scheduled?
          actions << "'add decoration <name>' - Add decorations" if event.active?
        end

        unless actions.empty?
          lines << "Available Actions:"
          actions.each { |a| lines << "  #{a}" }
        end

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            event_id: event.id,
            name: event.name,
            description: event.description,
            event_type: event.event_type,
            status: event.status,
            is_public: event.is_public,
            starts_at: event.starts_at&.iso8601,
            ends_at: event.ends_at&.iso8601,
            organizer_name: event.organizer&.name,
            location_name: event.room&.name || event.location&.name,
            attendee_count: event.attendee_count,
            max_attendees: event.max_attendees,
            is_organizer: is_organizer,
            is_staff: is_staff,
            is_attending: is_attending,
            can_enter: !character_instance.in_event? && event.active?,
            can_leave: character_instance.in_event_id == event.id
          }
        )
      end

      def format_datetime(time)
        return "TBD" unless time

        time.strftime("%B %d, %Y at %I:%M %p")
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Events::EventInfo)
