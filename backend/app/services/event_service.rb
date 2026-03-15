# frozen_string_literal: true

# EventService handles core event business logic including creation,
# lifecycle management, and queries.
module EventService
  extend ResultHandler

  class << self
    # Create a new event
    def create_event(organizer:, name:, starts_at:, room: nil, location: nil, **options)
      Event.create(
        organizer_id: organizer.id,
        name: name,
        starts_at: starts_at,
        ends_at: options[:ends_at],
        room_id: room&.id,
        location_id: location&.id || room&.location_id,
        event_type: options[:event_type] || 'party',
        description: options[:description],
        is_public: options.fetch(:is_public, true),
        logs_visible_to: options[:logs_visible_to] || 'public',
        banner_url: options[:banner_url],
        max_attendees: options[:max_attendees],
        status: 'scheduled'
      )
    end

    # Start an event - snapshot room state and set status to active
    def start_event!(event)
      return error('Event already started') if event.active?
      return error('Event cancelled') if event.cancelled?
      return error('Event completed') if event.completed?

      # Snapshot the room state
      event.snapshot_room! if event.room

      event.start!

      success('Event started', data: { event: event })
    end

    # End an event - cleanup and set status to completed
    def end_event!(event)
      return error('Event not active') unless event.active?

      event.end_for_all!

      # Create world memory from event (bounded async runner)
      WorldMemoryService.create_from_event_async(event)

      success('Event ended', data: { event: event })
    end

    # Cancel an event
    def cancel_event!(event)
      return error('Cannot cancel completed event') if event.completed?

      # Remove all characters from event if active
      event.characters_in_event.update(in_event_id: nil) if event.active?
      event.cleanup_temporary_content!
      event.cancel!

      success('Event cancelled', data: { event: event })
    end

    # Get upcoming events (public)
    def upcoming_events(limit: 20, include_private: false)
      if include_private
        Event.upcoming(limit: limit)
      else
        Event.public_upcoming(limit: limit)
      end
    end

    # Get events for a specific character (attending or organizing)
    def events_for_character(character, limit: 20)
      Event.for_character(character, limit: limit)
    end

    # Get active event at a room
    def find_event_at(room)
      Event.active_at_room(room)
    end

    # Get events at a location
    def events_at_location(location, limit: 10)
      Event.at_location(location, limit: limit)
    end

    # Get events at a room
    def events_at_room(room, limit: 10)
      Event.at_room(room, limit: limit)
    end

    # RSVP a character to an event
    def rsvp(event:, character:, status: 'yes')
      attendee = event.add_attendee(character, rsvp: status)
      success('RSVP recorded', data: { attendee: attendee })
    end

    # Check if a character can enter an event
    def can_enter_event?(event:, character:)
      return { can_enter: false, reason: 'Event not active' } unless event.active? || event.in_progress?
      return { can_enter: false, reason: 'Event at capacity' } if event.max_attendees && event.attendee_count >= event.max_attendees

      # Check if character is banned/bounced
      attendee = EventAttendee.first(event_id: event.id, character_id: character.id)
      return { can_enter: false, reason: 'You have been bounced from this event and cannot re-enter.' } if attendee&.bounced

      { can_enter: true }
    end

    # Enter a character into an event
    def enter_event!(event:, character_instance:)
      character = character_instance.character
      check = can_enter_event?(event: event, character: character)
      return error(check[:reason]) unless check[:can_enter]

      # Add as attendee if not already
      event.add_attendee(character, rsvp: 'yes')

      # Update character instance
      character_instance.update(in_event_id: event.id)

      success('Entered event', data: { event: event })
    end

    # Leave an event
    def leave_event!(character_instance:)
      event = Event[character_instance.in_event_id]
      return error('Not in an event') unless event

      character_instance.update(in_event_id: nil, event_camera: false, spotlight_remaining: nil)

      success('Left event', data: { event: event })
    end

    # Check if character is host/staff of event
    def is_host_or_staff?(event:, character:)
      return true if event.organizer_id == character.id

      attendee = EventAttendee.first(event_id: event.id, character_id: character.id)
      attendee && %w[host staff].include?(attendee.role)
    end

    # Add a decoration to an event room
    def add_decoration(event:, room:, name:, description: nil, created_by: nil)
      unless is_host_or_staff?(event: event, character: created_by)
        return error('Only hosts and staff can add decorations')
      end

      decoration = EventDecoration.add_to_event(
        event: event,
        room: room,
        name: name,
        description: description,
        created_by: created_by
      )

      success('Decoration added', data: { decoration: decoration })
    end

    # Add a place to an event room
    def add_place(event:, room:, name:, created_by: nil, **options)
      unless is_host_or_staff?(event: event, character: created_by)
        return error('Only hosts and staff can add furniture')
      end

      place = EventPlace.add_to_event(
        event: event,
        room: room,
        name: name,
        created_by: created_by,
        **options
      )

      success('Furniture added', data: { place: place })
    end

    # Set room description override for event
    def set_room_description(event:, room:, description:, character: nil)
      unless is_host_or_staff?(event: event, character: character)
        return error('Only hosts and staff can modify room')
      end

      state = EventRoomState.snapshot!(event, room)
      state.set_event_description(description)

      success('Room description updated', data: { room_state: state })
    end

    # Set room background override for event
    def set_room_background(event:, room:, url:, character: nil, night_url: nil)
      unless is_host_or_staff?(event: event, character: character)
        return error('Only hosts and staff can modify room')
      end

      state = EventRoomState.snapshot!(event, room)
      state.set_event_background(url, night_url: night_url)

      success('Room background updated', data: { room_state: state })
    end

    # Calendar data for display (with timezone info)
    def calendar_data(events, timezone: 'UTC')
      events.map do |event|
        {
          id: event.id,
          name: event.name,
          description: event.description,
          event_type: event.event_type,
          starts_at: event.starts_at.iso8601,
          ends_at: event.ends_at&.iso8601,
          is_public: event.is_public,
          status: event.status,
          organizer_name: event.organizer&.name,
          location_name: event.location&.name || event.room&.location&.name,
          room_name: event.room&.name,
          attendee_count: event.attendee_count,
          max_attendees: event.max_attendees,
          banner_url: event.banner_url
        }
      end
    end
  end
end
