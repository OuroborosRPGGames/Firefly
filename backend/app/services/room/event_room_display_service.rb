# frozen_string_literal: true

require_relative 'room_display_service'

# Event-aware room display service that shows event decorations,
# places, and room overrides to event participants.
class EventRoomDisplayService < RoomDisplayService
  attr_reader :event

  def initialize(room, viewer_instance, event, mode: :full)
    super(room, viewer_instance, mode: mode)
    @event = event
  end

  # Build complete display data for a room during an event
  # Overrides room description/background if event has customizations
  # Merges permanent and temporary decorations/places
  def build_display
    base = super

    return base unless @event&.active?

    base.merge(
      room: event_room_info,
      places: merged_places,
      decorations: merged_decorations,
      event: event_info,
      thumbnails: merged_thumbnails
    )
  end

  private

  def event_room_info
    info = super_room_info
    room_state = @event.room_state_for(@room)

    if room_state
      info[:description] = room_state.effective_description if room_state.effective_description
      info[:background_picture_url] = room_state.effective_background_url if room_state.effective_background_url
    end

    info[:in_event] = true
    info[:event_name] = @event.name
    info
  end

  # Get the base room info from parent class
  def super_room_info
    loc = @room.location
    {
      id: @room.id,
      name: @room.name,
      description: @room.current_description(loc),
      short_description: @room.short_description,
      room_type: @room.room_type,
      safe_room: @room.safe_room,
      background_picture_url: @room.current_background_url(loc),
      time_of_day: GameTimeService.time_of_day(loc),
      season: GameTimeService.season(loc)
    }
  end

  # Merge permanent places with event-specific temporary places
  def merged_places
    permanent = places_with_characters
    temporary = event_places

    permanent + temporary
  end

  # Get event-specific temporary places
  def event_places
    @event.places_for(@room).all.map do |place|
      linked_place_id = place.respond_to?(:place_id) ? place.place_id : nil
      chars = CharacterInstance.where(
        current_room_id: @room.id,
        current_place_id: linked_place_id || place.id,
        in_event_id: @event.id,
        reality_id: @viewer.reality_id
      ).exclude(id: @viewer.id)
        .eager(:character)
        .all

      {
        id: "event_place_#{place.id}",
        name: place.name,
        description: place.description,
        place_type: place.place_type,
        is_furniture: place.is_furniture,
        default_sit_action: if place.respond_to?(:default_sit_action)
                              place.default_sit_action
                            elsif place.respond_to?(:sit_action)
                              place.sit_action
                            end,
        image_url: place.image_url,
        has_image: !place.image_url.to_s.empty?,
        characters: chars.map { |ci| character_brief(ci) },
        is_event_place: true,
        event_id: @event.id
      }
    end
  end

  # Merge permanent decorations with event-specific temporary decorations
  def merged_decorations
    permanent = visible_decorations_data
    temporary = event_decorations

    permanent + temporary
  end

  # Get event-specific temporary decorations
  def event_decorations
    @event.decorations_for(@room).all.map do |dec|
      {
        id: "event_dec_#{dec.id}",
        name: dec.name,
        description: dec.description,
        image_url: dec.image_url,
        has_image: !dec.image_url.to_s.empty?,
        is_event_decoration: true,
        event_id: @event.id
      }
    end
  end

  # Event information block
  def event_info
    {
      id: @event.id,
      name: @event.name,
      description: @event.description,
      event_type: @event.event_type,
      organizer_name: @event.organizer&.name,
      starts_at: @event.starts_at,
      is_host: @event.organizer_id == @viewer.character_id,
      is_staff: EventService.is_host_or_staff?(event: @event, character: @viewer.character),
      attendee_count: @event.attendee_count
    }
  end

  # Merge permanent thumbnails with event-specific thumbnails
  def merged_thumbnails
    thumbnails = []

    # Permanent place images
    @room.visible_places.each do |place|
      next unless place.has_image?

      thumbnails << { url: place.image_url, alt: place.name, type: 'place' }
    end

    # Event place images
    @event.places_for(@room).each do |place|
      next if place.image_url.to_s.empty?

      thumbnails << { url: place.image_url, alt: place.name, type: 'event_place' }
    end

    # Permanent decoration images
    @room.visible_decorations.each do |dec|
      next unless dec.has_image?

      thumbnails << { url: dec.image_url, alt: dec.name, type: 'decoration' }
    end

    # Event decoration images
    @event.decorations_for(@room).each do |dec|
      next if dec.image_url.to_s.empty?

      thumbnails << { url: dec.image_url, alt: dec.name, type: 'event_decoration' }
    end

    # Background - use event override if available
    room_state = @event.room_state_for(@room)
    bg_url = room_state&.effective_background_url || @room.current_background_url(@room.location)
    if bg_url && !bg_url.to_s.empty?
      thumbnails << { url: bg_url, alt: @room.name, type: 'background' }
    end

    thumbnails
  end
end
