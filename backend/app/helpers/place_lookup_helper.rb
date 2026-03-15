# frozen_string_literal: true

# Helper for finding places/furniture in rooms
# Reduces duplication across posture commands (sit, lie, etc.)
module PlaceLookupHelper
  # Find a place in the current room by name
  # Supports exact, prefix, and contains matching with article stripping
  #
  # @param name [String] The place name to search for
  # @param furniture_only [Boolean] Only match places marked as furniture
  # @param room [Room] The room to search in (defaults to location)
  # @return [Place, nil] The matched place or nil
  def find_place(name, furniture_only: false, room: nil)
    return nil if blank?(name)

    room ||= location
    return nil unless room

    name_lower = name.downcase.strip
    query = Place.where(room_id: room.id)
    query = query.where(is_furniture: true) if furniture_only
    places = query.all

    # Hide invisible places unless they're linked to the viewer's current event.
    viewer_event_id = respond_to?(:character_instance) ? character_instance&.in_event_id : nil
    event_place_by_place_id = {}
    if defined?(EventPlace) && EventPlace.columns.include?(:place_id)
      EventPlace.where(room_id: room.id).exclude(place_id: nil).all.each do |ep|
        event_place_by_place_id[ep.place_id] = ep
      end
    end

    places = places.select do |place|
      event_place = event_place_by_place_id[place.id]
      if event_place
        viewer_event_id == event_place.event_id
      else
        !place.invisible
      end
    end

    return nil if places.empty?

    # Strip leading article for matching
    stripped_name = strip_article(name_lower)

    # 1. Exact match (with or without article)
    exact = places.find do |p|
      p_name = p.name.downcase
      p_name == name_lower ||
        p_name == stripped_name ||
        strip_article(p_name) == stripped_name
    end
    return exact if exact

    # 2. Prefix match
    prefix = places.find do |p|
      p_name_stripped = strip_article(p.name.downcase)
      p_name_stripped.start_with?(stripped_name) ||
        p.name.downcase.start_with?(name_lower)
    end
    return prefix if prefix

    # 3. Contains match (min 3 chars to avoid false positives)
    return nil if stripped_name.length < 3

    places.find do |p|
      strip_article(p.name.downcase).include?(stripped_name)
    end
  end

  # Find furniture specifically (places marked as is_furniture: true)
  # Convenience method for find_place with furniture_only: true
  #
  # @param name [String] The furniture name to search for
  # @param room [Room] The room to search in (defaults to location)
  # @return [Place, nil] The matched furniture or nil
  def find_furniture(name, room: nil)
    find_place(name, furniture_only: true, room: room)
  end

  private

  # Strip leading articles (the, a, an) from a string
  # @param text [String] Text to strip
  # @return [String] Text without leading article
  def strip_article(text)
    text.sub(/\A(the|a|an)\s+/i, '')
  end
end
