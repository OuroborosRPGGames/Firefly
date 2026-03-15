# frozen_string_literal: true

module Commands
  module Events
    class EventsCmd < Commands::Base::Command
      command_name 'events'
      aliases 'calendar', 'upcoming', 'eventslist'
      category :events
      help_text 'View upcoming events'
      usage 'events [my|here]'
      examples 'events', 'events my', 'events here', 'calendar'

      protected

      def perform_command(parsed_input)
        filter = parsed_input[:text].to_s.strip.downcase

        case filter
        when 'my', 'mine'
          show_my_events
        when 'here'
          show_events_here
        when 'create'
          show_create_event_form
        when ''
          # No filter: show quickmenu with events list
          show_events_quickmenu
        else
          show_all_events
        end
      end

      private

      # Show a quickmenu with events list and actions
      def show_events_quickmenu
        events = EventService.upcoming_events(limit: 10, include_private: false).all

        # Build options for each event
        options = events.each_with_index.map do |event, idx|
          status = event.active? ? '●' : ' '  # Bullet for active
          room_name = event.room&.name || 'TBD'
          attendee_info = "(#{event.attendee_count} attendees)"

          {
            key: (idx + 1).to_s,
            label: "#{status} #{event.name}",
            description: "#{room_name} #{attendee_info}"
          }
        end

        # Add action shortcuts
        options << { key: 'c', label: 'Create new event', description: 'Host your own event' }
        options << { key: 'm', label: 'My events', description: 'View events you\'re attending' }
        options << { key: 'h', label: 'Events here', description: 'Events at this location' }
        options << { key: 'q', label: 'Close', description: 'Close calendar' }

        # Store event IDs for the handler
        event_data = events.map { |e| { id: e.id, name: e.name } }

        prompt = if events.empty?
                   "📅 No upcoming events. Create one!"
                 else
                   "📅 Upcoming Events (#{events.length}):"
                 end

        create_quickmenu(
          character_instance,
          prompt,
          options,
          context: {
            command: 'events',
            stage: 'select_event',
            events: event_data
          }
        )
      end

      # Show the create event form
      def show_create_event_form
        room = character_instance.current_room

        fields = [
          {
            name: 'name',
            label: 'Event Name',
            type: 'text',
            placeholder: 'Birthday Party, Game Night, etc.',
            required: true
          },
          {
            name: 'description',
            label: 'Description',
            type: 'textarea',
            placeholder: 'What is this event about?',
            required: false
          },
          {
            name: 'event_type',
            label: 'Event Type',
            type: 'select',
            options: [
              { value: 'party', label: 'Party' },
              { value: 'meeting', label: 'Meeting' },
              { value: 'competition', label: 'Competition' },
              { value: 'concert', label: 'Concert' },
              { value: 'ceremony', label: 'Ceremony' }
            ],
            default: 'party',
            required: true
          },
          {
            name: 'is_public',
            label: 'Public event (visible to all)',
            type: 'checkbox',
            default: true
          },
          {
            name: 'start_delay',
            label: 'Start Time',
            type: 'select',
            options: [
              { value: '0', label: 'Right now' },
              { value: '30', label: 'In 30 minutes' },
              { value: '60', label: 'In 1 hour' },
              { value: '120', label: 'In 2 hours' },
              { value: '1440', label: 'Tomorrow' }
            ],
            default: '60',
            required: true
          }
        ]

        create_form(
          character_instance,
          "Create New Event",
          fields,
          context: {
            command: 'event',
            room_id: room.id,
            room_name: room.name,
            location_id: room.location_id,
            organizer_id: character.id
          }
        )
      end

      def show_all_events
        events = EventService.upcoming_events(limit: 20, include_private: false).all

        if events.empty?
          return success_result("No upcoming public events.", type: :message, data: { events: [] })
        end

        format_events_list("Upcoming Events", events)
      end

      def show_my_events
        events = EventService.events_for_character(character, limit: 20).all

        if events.empty?
          return success_result(
            "You have no upcoming events. Use 'create event' to host one!",
            type: :message,
            data: { events: [] }
          )
        end

        format_events_list("Your Events", events)
      end

      def show_events_here
        room = character_instance.current_room
        location = room.location

        # Check room first, then location
        events = EventService.events_at_room(room, limit: 10).all
        events = EventService.events_at_location(location, limit: 10).all if events.empty? && location

        if events.empty?
          return success_result(
            "No upcoming events at this location.",
            type: :message,
            data: { events: [] }
          )
        end

        format_events_list("Events at #{room.name}", events)
      end

      def format_events_list(title, events)
        calendar_data = EventService.calendar_data(events)

        lines = ["<h3>#{title}</h3>", ""]

        events.each do |event|
          status = event.active? ? "[ACTIVE]" : ""
          time_str = format_time_until(event.starts_at)
          public_str = event.is_public ? "" : "[Private]"

          lines << "#{event.name} #{status} #{public_str}".strip
          lines << "  Type: #{event.event_type.capitalize} | #{time_str}"
          lines << "  Location: #{event.room&.name || event.location&.name || 'TBD'}"
          lines << "  Host: #{event.organizer&.name || 'Unknown'} | Attendees: #{event.attendee_count}"
          lines << ""
        end

        lines << "Use 'event info <name>' for details or 'directions to event <name>' for directions."

        success_result(
          lines.join("\n"),
          type: :message,
          data: {
            title: title,
            events: calendar_data
          }
        )
      end

      def format_time_until(time)
        time_until(time)
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Events::EventsCmd)
