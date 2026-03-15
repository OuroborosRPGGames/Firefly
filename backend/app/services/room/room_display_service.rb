# frozen_string_literal: true

require_relative '../../helpers/canvas_helper'

# Service for building rich room display data for the look command
# Includes room info, places with characters, decorations, objects, exits
#
# Performance notes:
# - Uses memoization to avoid duplicate queries
# - Eager loads associations to prevent N+1 queries
class RoomDisplayService
  # Window for detecting recent RP interactions (10 minutes)
  TALKING_TO_WINDOW = 600

  # Feature types that can show outdoor weather
  WEATHER_VISIBLE_FEATURE_TYPES = %w[window door opening archway gate hatch portal].freeze

  # Display modes for room display
  # - :full - Explicit look command, shows everything
  # - :arrival - Arrived at a room and stopped, shows brief info
  # - :transit - Passing through on the way somewhere, minimal display
  DISPLAY_MODES = %i[full arrival transit].freeze

  attr_reader :room, :viewer, :mode

  class << self
    # Build the appropriate room display service for this viewer/context.
    # Uses event-aware rendering only when the viewer is in an active event
    # that applies to the room being rendered.
    def for(room, viewer_instance, mode: :full)
      return new(room, viewer_instance, mode: mode) unless room && viewer_instance

      event = viewer_instance.in_event
      if defined?(EventRoomDisplayService) && event&.active? && event_applies_to_room?(event, room)
        return EventRoomDisplayService.new(room, viewer_instance, event, mode: mode)
      end

      new(room, viewer_instance, mode: mode)
    end

    private

    def event_applies_to_room?(event, room)
      return true if event.room_id == room.id
      return true if event.location_id && room.location_id == event.location_id

      false
    end
  end

  def initialize(room, viewer_instance, mode: :full)
    @room = room
    @viewer = viewer_instance
    @mode = DISPLAY_MODES.include?(mode) ? mode : :full
  end

  # Build display data based on mode
  # @return [Hash] structured room display data
  def build_display
    case @mode
    when :transit
      build_transit_display
    when :arrival
      build_arrival_display
    else
      build_full_display
    end
  end

  # Transit mode: Minimal display for passing through rooms
  # Just room name and characters (no exits, no details)
  def build_transit_display
    {
      room: { id: @room.id, name: @room.name },
      characters_ungrouped: all_visible_characters,
      display_mode: :transit
    }
  end

  # Arrival mode: Brief display for arriving at a room
  # Room name, characters, exits, places, context hints
  def build_arrival_display
    display = {
      room: arrival_room_info,
      places: places_with_characters,
      exits: visible_exits,
      locations: build_locations_data,
      characters_ungrouped: all_visible_characters,
      content_consent: content_consent_info,
      context_hints: context_command_hints,
      display_mode: :arrival
    }

    # Add weather data if visible (outdoor room or can see outside)
    weather_data = build_weather_display
    display[:weather] = weather_data if weather_data

    display
  end

  # Full mode: Complete display for explicit look command
  def build_full_display
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    timings = {}

    # Pre-warm knowledge cache for all visible characters to avoid N+1 queries
    prefetch_character_knowledge

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    room = room_info
    timings[:room_info] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    places = places_with_characters
    timings[:places] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    decorations = visible_decorations_data
    timings[:decorations] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    objects = ground_objects
    timings[:objects] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    exits = visible_exits
    timings[:exits] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    locations = build_locations_data
    timings[:locations] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    chars = ungrouped_characters
    timings[:characters] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    nearby = nearby_room_names
    timings[:nearby] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    thumbs = room_thumbnails
    timings[:thumbnails] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    consent = content_consent_info
    timings[:consent] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    hints = context_command_hints
    timings[:hints] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round

    display = {
      room: room,
      places: places,
      decorations: decorations,
      objects: objects,
      exits: exits,
      locations: locations,
      characters_ungrouped: chars,
      nearby_rooms: nearby,
      thumbnails: thumbs,
      content_consent: consent,
      context_hints: hints,
      display_mode: :full
    }

    # Add delve monsters if viewer is in a delve
    delve_monsters_data = delve_monsters_in_room
    display[:delve_monsters] = delve_monsters_data if delve_monsters_data&.any?

    # Add weather data if visible (outdoor room or can see outside)
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    weather_data = build_weather_display
    timings[:weather] = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round
    display[:weather] = weather_data if weather_data

    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    if elapsed_ms > 100
      slow = timings.select { |_, v| v > 5 }.sort_by { |_, v| -v }.map { |k, v| "#{k}=#{v}ms" }.join(' ')
      warn "[RoomDisplayService] build_full_display slow: #{elapsed_ms}ms [#{slow}]"
    end

    display
  end

  private

  # Minimal room info for arrival mode
  def arrival_room_info
    loc = @room.location
    {
      id: @room.id,
      name: @room.name,
      room_type: @room.room_type,
      safe_room: @room.safe_room,
      time_of_day: GameTimeService.time_of_day(loc)
    }
  end

  # All visible characters for brief modes (combines ungrouped + those at places)
  def all_visible_characters
    chars = ungrouped_characters.dup

    cached_places.each do |place|
      place.characters_here(@viewer.reality_id, viewer: @viewer)
           .exclude(id: @viewer.id)
           .eager(:character)
           .all
           .each { |ci| chars << character_brief(ci) }
    end

    chars
  end


  # Memoized list of all online character instances in the room (for name disambiguation)
  def all_room_character_instances
    @all_room_character_instances ||= @room.characters_here(@viewer.reality_id, viewer: @viewer)
                                           .eager(:character)
                                           .all
  end

  # Memoized places for reuse in places_with_characters and room_thumbnails
  def cached_places
    @cached_places ||= @room.visible_places.all
  end

  # Memoized decorations for reuse in visible_decorations and room_thumbnails
  def cached_decorations
    @cached_decorations ||= @room.visible_decorations.all
  end

  # Memoized private body positions (queried once, reused per character in status_clothing_state)
  def cached_private_positions
    @cached_private_positions ||= (defined?(BodyPosition) ? BodyPosition.where(is_private: true).all : [])
  end

  # Pre-fetch CharacterKnowledge for all visible characters in one query
  # This avoids N+1 queries in display_name_for when building character briefs
  def prefetch_character_knowledge
    return unless defined?(CharacterKnowledge)

    # Use memoized room character list to avoid duplicate query
    char_ids = all_room_character_instances
                 .reject { |ci| ci.id == @viewer.id }
                 .map { |ci| ci.character_id }
                 .compact
                 .uniq
    return if char_ids.empty?

    # Load all knowledge records in one query
    knowledge_records = CharacterKnowledge.where(
      knower_character_id: @viewer.character_id,
      known_character_id: char_ids
    ).all

    # Build lookup hash by known_character_id
    @knowledge_cache = knowledge_records.each_with_object({}) do |k, h|
      h[k.known_character_id] = k
    end
  rescue StandardError => e
    warn "[RoomDisplayService] prefetch_character_knowledge error: #{e.message}"
    @knowledge_cache = {}
  end

  # Get cached knowledge record for a character
  def cached_knowledge_for(character_id)
    @knowledge_cache ||= {}
    @knowledge_cache[character_id]
  end

  def room_info
    loc = @room.location
    info = {
      id: @room.id,
      name: @room.name,
      description: @room.current_description(loc),
      short_description: @room.short_description,
      room_type: @room.room_type,
      safe_room: @room.safe_room,
      background_picture_url: @room.current_background_url(loc),
      mask_url: @room.mask_url,
      time_of_day: GameTimeService.time_of_day(loc),
      season: GameTimeService.season(loc),
      vault_accessible: @room.vault_accessible?(@viewer.character)
    }

    # Check for arranged scenes available in this room
    available_scenes = arranged_scenes_available
    unless available_scenes.empty?
      info[:arranged_scenes] = available_scenes.map do |scene|
        {
          id: scene.id,
          name: scene.display_name,
          npc_name: scene.npc_character&.full_name
        }
      end
      info[:scene_hint] = "You have an arranged meeting here. Type 'scene' to begin."
    end

    info
  end

  def arranged_scenes_available
    return [] unless defined?(ArrangedScene)

    ArrangedScene.available_for(@viewer)
  rescue StandardError => e
    warn "[RoomDisplayService] Error checking arranged scenes: #{e.message}"
    []
  end

  def places_with_characters
    cached_places.map do |place|
      chars = place.characters_here(@viewer.reality_id, viewer: @viewer)
                   .exclude(id: @viewer.id)
                   .eager(:character)
                   .all

      {
        id: place.id,
        name: place.name,
        description: place.description,
        place_type: place.place_type,
        is_furniture: place.furniture?,
        default_sit_action: place.default_sit_action,
        image_url: place.image_url,
        has_image: place.has_image?,
        characters: chars.map { |ci| character_brief(ci) }
      }
    end
  end

  def ungrouped_characters
    @room.characters_here(@viewer.reality_id, viewer: @viewer)
         .where(current_place_id: nil)
         .exclude(id: @viewer.id)
         .eager(:character)
         .all
         .map { |ci| character_brief(ci) }
  end

  def character_brief(char_instance)
    char = char_instance.character
    knowledge = cached_knowledge_for(char.id)
    display_name = char.display_name_for(@viewer, room_characters: all_room_character_instances, knowledge: knowledge)
    dist = distance_to_character(char_instance)
    dir = direction_to_character(char_instance)
    {
      id: char_instance.id,
      character_id: char_instance.id,
      name: display_name,
      short_desc: char.short_desc,
      name_is_short_desc: display_name == char.short_desc,
      status: char_instance.status,
      roomtitle: char_instance.roomtitle,
      is_npc: char.is_npc,
      status_line: build_status_line(char_instance),
      presence: char_instance.presence_indicator,
      distance: dist,
      direction_arrow: dir
    }
  end

  # Build a human-readable status line describing what the character is doing
  # @param char_instance [CharacterInstance] the character to describe
  # @return [String, nil] comma-separated status description
  def build_status_line(char_instance)
    # Don't show activity details for non-alive characters
    return nil unless char_instance.status == 'alive'

    parts = []

    parts << status_posture_and_place(char_instance)
    parts << status_clothing_state(char_instance)
    parts << status_injury_state(char_instance)
    parts << status_consumption_state(char_instance)
    parts << status_combat_state(char_instance)
    parts << status_movement_state(char_instance)
    parts << status_talking_to(char_instance)

    result = parts.compact.join(', ')
    result.empty? ? nil : result
  rescue StandardError => e
    warn "[RoomDisplayService] Failed to build status line: #{e.message}"
    nil
  end

  # Posture combined with place (e.g., "sitting at the bar")
  def status_posture_and_place(char_instance)
    place = char_instance.current_place
    stance = char_instance.stance || 'standing'

    if place
      case stance
      when 'sitting' then "sitting at #{place.name}"
      when 'lying' then "lying on #{place.name}"
      when 'reclining' then "reclining on #{place.name}"
      else "standing near #{place.name}"
      end
    else
      # Only mention non-standing postures if no place
      case stance
      when 'sitting' then 'sitting'
      when 'lying' then 'lying down'
      when 'reclining' then 'reclining'
      else nil # Don't mention "standing" without context
      end
    end
  end

  # Simple clothing state indicator (nude, topless, or partially undressed)
  def status_clothing_state(char_instance)
    # NPCs don't have coded clothing items - skip exposure check
    return nil if char_instance.character&.is_npc
    return nil unless defined?(VisibilityService) && defined?(BodyPosition)

    private_positions = cached_private_positions
    return nil if private_positions.empty?

    # Load worn items once for all position checks
    worn = char_instance.objects_dataset
      .where(worn: true)
      .eager(:item_body_positions)
      .order(:display_order, Sequel.desc(:worn_layer))
      .all

    exposed_positions = private_positions.select do |pos|
      VisibilityService.position_exposed?(char_instance, pos.id, worn_items_cache: worn)
    end

    return nil if exposed_positions.empty?

    exposed_labels = exposed_positions.map { |pos| pos.label }

    if exposed_positions.count == private_positions.count
      'nude'
    elsif exposed_labels.include?('breasts') && !exposed_labels.include?('groin') && !exposed_labels.include?('buttocks')
      # Topless applies to all genders - a shirtless person is shirtless
      'topless'
    else
      'partially undressed'
    end
  rescue StandardError => e
    warn "[RoomDisplayService] Exposure state error: #{e.message}" if ENV['DEBUG']
    nil
  end

  # Injury state based on health percentage
  def status_injury_state(char_instance)
    return nil unless char_instance.respond_to?(:health) && char_instance.respond_to?(:max_health)
    return nil unless char_instance.max_health && char_instance.max_health > 0

    health_pct = (char_instance.health.to_f / char_instance.max_health) * 100

    case health_pct
    when 0..25 then 'critically injured'
    when 26..50 then 'badly wounded'
    when 51..75 then 'injured'
    when 76..99 then 'lightly wounded'
    else nil # 100% = no mention
    end
  end

  # Current consumption activity (eating, drinking, smoking)
  def status_consumption_state(char_instance)
    actions = []

    if char_instance.respond_to?(:eating?) && char_instance.eating?
      item = char_instance.eating_item
      actions << (item ? "eating #{item.name}" : 'eating')
    end

    if char_instance.respond_to?(:drinking?) && char_instance.drinking?
      item = char_instance.drinking_item
      actions << (item ? "drinking #{item.name}" : 'drinking')
    end

    if char_instance.respond_to?(:smoking?) && char_instance.smoking?
      item = char_instance.smoking_item
      actions << (item ? "smoking #{item.name}" : 'smoking')
    end

    actions.any? ? actions.join(' and ') : nil
  end

  # Combat state with target name if available
  def status_combat_state(char_instance)
    return nil unless char_instance.respond_to?(:in_combat?) && char_instance.in_combat?
    return nil unless defined?(FightParticipant)

    # Find fight participant to get fight info
    participant = FightParticipant.where(character_instance_id: char_instance.id).first
    return 'in combat' unless participant&.fight_id

    # Find other participants in the fight
    targets = FightParticipant.where(fight_id: participant.fight_id)
                              .exclude(character_instance_id: char_instance.id)
                              .eager(character_instance: :character)
                              .limit(1)
                              .all

    if targets.any?
      target = targets.first
      # Use fight participant's own name (handles NPC/monster names correctly)
      target_name = target.respond_to?(:character_name) ? target.character_name : nil
      target_name ||= target.character_instance&.character&.display_name_for(@viewer)
      target_name ? "fighting #{target_name}" : 'in combat'
    else
      'in combat'
    end
  rescue StandardError => e
    warn "[RoomDisplayService] Combat state error: #{e.message}" if ENV['DEBUG']
    'in combat'
  end

  # Movement/traveling state
  def status_movement_state(char_instance)
    return nil unless char_instance.respond_to?(:traveling?) && char_instance.traveling?

    'walking'
  end

  # Recent RP interaction (who they're talking to)
  def status_talking_to(char_instance)
    return nil unless defined?(RpLog)

    cutoff = Time.now - TALKING_TO_WINDOW

    # Find most recent say/whisper in this room within window
    recent = RpLog.where(character_instance_id: char_instance.id)
                  .where(room_id: @room.id)
                  .where { logged_at > cutoff }
                  .where(log_type: %w[say whisper])
                  .order(Sequel.desc(:logged_at))
                  .first

    return nil unless recent&.sender_character_id
    # Skip if talking to self
    return nil if recent.sender_character_id == char_instance.character_id

    sender = Character[recent.sender_character_id]
    return nil unless sender

    "talking to #{sender.display_name_for(@viewer)}"
  rescue StandardError => e
    warn "[RoomDisplayService] Conversation state error: #{e.message}" if ENV['DEBUG']
    nil
  end

  def visible_decorations_data
    cached_decorations.map do |dec|
      {
        id: dec.id,
        name: dec.name,
        description: dec.description,
        image_url: dec.image_url,
        has_image: dec.has_image?
      }
    end
  end

  def ground_objects
    # Filter items by viewer's timeline
    items_query = @room.objects_here
    items_query = Item.visible_to(@viewer).where(room_id: @room.id) if @viewer

    items_query.map do |obj|
      {
        id: obj.id,
        name: obj.name,
        description: obj.description,
        quantity: obj.quantity,
        condition: obj.condition,
        image_url: obj.image_url,
        thumbnail_url: obj.thumbnail_url
      }
    end
  end

  def visible_exits
    # Memoized spatial exits - avoids recomputing for nearby_room_names
    @visible_exits ||= build_spatial_exits
  end

  # Build exit data from spatial adjacency (polygon geometry)
  # Deduplicates by destination room - each room appears only once (in closest direction)
  def build_spatial_exits
    return [] unless defined?(RoomAdjacencyService) && defined?(RoomPassabilityService)

    # Collect all passable exits with distances
    all_exits = []

    # Get navigable exits (already filtered for passability by RoomAdjacencyService)
    adjacent = RoomAdjacencyService.navigable_exits(@room)
    adjacent.each do |direction, rooms|
      rooms.each do |adj_room|
        next unless adj_room.navigable?

        distance = calculate_distance_to_room(adj_room)
        all_exits << {
          room_id: adj_room.id,
          room: adj_room,
          direction: direction.to_s,
          distance: distance
        }
      end
    end

    # Deduplicate by destination room - keep only the closest direction for each room
    exits_by_room = {}
    all_exits.each do |exit_data|
      room_id = exit_data[:room_id]
      if exits_by_room[room_id].nil? || exit_data[:distance] < exits_by_room[room_id][:distance]
        exits_by_room[room_id] = exit_data
      end
    end

    # Build final exit data
    exits = exits_by_room.values.map do |exit_data|
      adj_room = exit_data[:room]
      {
        direction: exit_data[:direction],
        to_room_name: adj_room.name,
        to_room_styled_name: adj_room.respond_to?(:styled_name) ? adj_room.styled_name : nil,
        distance: exit_data[:distance],
        distance_tag: distance_tag_for(exit_data[:distance]),
        direction_arrow: direction_arrow_for(exit_data[:direction].to_sym),
        exit_type: :spatial
      }
    end

    # Check for exit to containing room via openings
    container = RoomAdjacencyService.containing_room(@room)
    if container && container.navigable?
      RoomFeature::VALID_DIRECTIONS.each do |dir|
        next unless RoomPassabilityService.opening_in_direction?(@room, dir.to_sym)

        distance = calculate_distance_to_room(container)
        exits << {
          direction: "exit (#{dir})",
          to_room_name: container.name,
          to_room_styled_name: container.respond_to?(:styled_name) ? container.styled_name : nil,
          distance: distance,
          distance_tag: distance_tag_for(distance),
          direction_arrow: direction_arrow_for(dir.to_sym),
          exit_type: :spatial
        }
      end
    end

    exits
  rescue StandardError => e
    warn "[RoomDisplayService] Spatial exits error: #{e.message}"
    []
  end

  # Build data for contained rooms (locations that can be entered)
  def build_locations_data
    return [] unless defined?(RoomAdjacencyService)

    RoomAdjacencyService.contained_rooms(@room).map do |contained_room|
      {
        id: contained_room.id,
        name: contained_room.name,
        type: contained_room.room_type,
        description: contained_room.short_description
      }
    end
  rescue StandardError => e
    warn "[RoomDisplayService] Locations data error: #{e.message}"
    []
  end

  # Calculate distance from viewer position to another room's center
  def calculate_distance_to_room(target_room)
    bounds = target_room.polygon_bounds
    room_center_x = (bounds[:min_x] + bounds[:max_x]) / 2.0
    room_center_y = (bounds[:min_y] + bounds[:max_y]) / 2.0

    viewer_pos = @viewer&.position || [0, 0, 0]

    Math.sqrt(
      (viewer_pos[0] - room_center_x)**2 +
      (viewer_pos[1] - room_center_y)**2
    ).round
  rescue StandardError => e
    warn "[RoomDisplayService] Distance calculation error: #{e.message}" if ENV['DEBUG']
    0
  end

  # Calculate distance from viewer to exit in coordinate units
  def calculate_exit_distance(exit)
    return 0 unless @viewer

    DistanceService.time_to_exit(@viewer, exit) / 100.0  # Convert ms to units
  rescue StandardError => e
    warn "[RoomDisplayService] Exit distance error: #{e.message}" if ENV['DEBUG']
    0  # Default to close if calculation fails
  end

  # Calculate distance in feet from viewer to another character
  def distance_to_character(char_instance)
    return 0 unless @viewer
    vp = @viewer.position
    cp = char_instance.position
    dx = cp[0] - vp[0]
    dy = cp[1] - vp[1]
    Math.sqrt(dx**2 + dy**2).round
  rescue StandardError => e
    warn "[RoomDisplayService] Character distance error: #{e.message}" if ENV['DEBUG']
    0
  end

  # Cardinal direction arrows for relative character positions (uses uppercase abbreviation keys
  # matching the computed direction codes in direction_to_character, not compass direction names).
  # Same arrow glyphs as CanvasHelper::DIRECTION_ARROWS but different key format.
  CHAR_DIRECTION_ARROWS = {
    'N' => '↑', 'S' => '↓', 'E' => '→', 'W' => '←',
    'NE' => '↗', 'NW' => '↖', 'SE' => '↘', 'SW' => '↙'
  }.freeze

  def direction_to_character(char_instance)
    return nil unless @viewer
    vp = @viewer.position
    cp = char_instance.position
    dx = cp[0] - vp[0]
    dy = cp[1] - vp[1]
    return nil if dx == 0 && dy == 0

    dir = if dy > 0
            dx > 0 ? 'NE' : (dx < 0 ? 'NW' : 'N')
          elsif dy < 0
            dx > 0 ? 'SE' : (dx < 0 ? 'SW' : 'S')
          else
            dx > 0 ? 'E' : 'W'
          end
    CHAR_DIRECTION_ARROWS[dir]
  rescue StandardError => e
    warn "[RoomDisplayService] Character direction error: #{e.message}" if ENV['DEBUG']
    nil
  end

  # Convert distance to human-readable tag like Ravencroft
  def distance_tag_for(distance)
    case distance
    when 0..20 then nil        # Very close, no tag needed
    when 21..50 then 'nearby'
    when 51..100 then 'far'
    else 'very far'
    end
  end

  # Get directional arrow for exit direction (Ravencroft-style)
  def direction_arrow_for(direction)
    CanvasHelper::DIRECTION_ARROWS[direction.to_s.downcase] || ''
  end

  def nearby_room_names
    # Use spatial exits - returns rooms based on polygon adjacency
    visible_exits.map do |exit_data|
      {
        direction: exit_data[:direction],
        room_name: exit_data[:to_room_name]
      }
    end
  end

  def room_thumbnails
    thumbnails = []

    # Place images first (reuses cached query)
    cached_places.each do |place|
      next unless place.has_image?

      thumbnails << { url: place.image_url, alt: place.name, type: 'place' }
    end

    # Decoration images (reuses cached query)
    cached_decorations.each do |dec|
      next unless dec.has_image?

      thumbnails << { url: dec.image_url, alt: dec.name, type: 'decoration' }
    end

    # Background as last thumbnail - use current resolved background for time/season
    bg_url = @room.current_background_url(@room.location)
    if bg_url && !bg_url.to_s.empty?
      thumbnails << { url: bg_url, alt: @room.name, type: 'background' }
    end

    thumbnails
  end

  # Get content consent information for the room
  # Returns nil if timer hasn't elapsed yet
  def content_consent_info
    return nil unless ContentConsentService.display_ready?(@room)

    info = ContentConsentService.consent_display_for_room(@room)
    return nil unless info

    {
      allowed_content: info[:allowed_content],
      stable_since: info[:stable_since]&.iso8601,
      ready: true
    }
  rescue StandardError => e
    warn "[RoomDisplayService] Failed to get content consent info: #{e.message}"
    nil
  end

  # Build context-sensitive command hints based on player's current situation
  # Returns an array of hint objects for active contexts (combat, delve, etc.)
  def context_command_hints
    hints = []

    # Combat context
    if @viewer.in_combat?
      hints << {
        context: :combat,
        message: "Type 'fight' to open the combat menu.",
        commands: %w[fight attack done flee]
      }
    end

    # Delve context - delve has its own HUD and room display, no hints needed here

    # Traveling context
    if @viewer.traveling?
      hints << {
        context: :traveling,
        message: "Type 'travel' for journey status, 'travel stop' to exit.",
        commands: %w[travel]
      }
    end

    # Event context
    if @viewer.in_event?
      hints << {
        context: :event,
        message: "Type 'event' for event details.",
        commands: %w[event]
      }
    end

    hints
  rescue StandardError => e
    warn "[RoomDisplayService] Failed to get context hints: #{e.message}"
    []
  end

  # Check if viewer is actively participating in a delve
  def active_delve_participant
    return nil unless defined?(DelveParticipant)

    DelveParticipant.where(
      character_instance_id: @viewer.id,
      status: 'active'
    ).first
  rescue StandardError => e
    warn "[RoomDisplayService] Delve participant error: #{e.message}" if ENV['DEBUG']
    nil
  end

  # Get delve monsters visible in the current room
  def delve_monsters_in_room
    participant = active_delve_participant
    return nil unless participant

    delve = participant.delve
    room = participant.current_room
    return nil unless delve && room

    monsters = delve.monsters_in_room(room)
    return nil if monsters.empty?

    monsters.map do |m|
      {
        id: m.id,
        name: m.display_name,
        monster_type: m.monster_type,
        difficulty: m.difficulty_text,
        hp: m.hp,
        max_hp: m.max_hp
      }
    end
  rescue StandardError => e
    warn "[RoomDisplayService] Delve monsters error: #{e.message}"
    nil
  end

  # ========================================
  # Weather Display Methods
  # ========================================

  # Build weather display data for the room
  # Returns weather with optional "Outside:" prefix for indoor rooms
  # @return [Hash, nil] weather data or nil if not visible
  def build_weather_display
    return nil unless @room.location

    # Determine weather source and whether we're viewing from inside
    if @room.outdoor_room?
      # Outdoor room - show weather directly
      build_weather_data(@room, from_inside: false)
    else
      # Indoor room - check if we can see outside
      outdoor_source = outdoor_weather_source
      return nil unless outdoor_source

      build_weather_data(outdoor_source, from_inside: true)
    end
  rescue StandardError => e
    warn "[RoomDisplayService] Weather display error: #{e.message}"
    nil
  end

  # Find an outdoor room visible from this indoor room
  # Checks windows (with open curtains), open doors, and exits
  # @return [Room, nil] first outdoor room found, or nil
  def outdoor_weather_source
    return nil if @room.outdoor_room?

    # Check RoomFeatures first (windows with open curtains, open doors)
    # Track if any feature connects to outdoor (even if blocked)
    has_feature_to_outdoor = false

    # Check both own features and inbound features from adjacent rooms
    RoomFeature.visible_from(@room).each do |feature|
      next unless WEATHER_VISIBLE_FEATURE_TYPES.include?(feature.feature_type)

      # For inbound features, connected_room points back to the source room
      target_room = feature.connected_room
      next unless target_room&.outdoor_room?

      has_feature_to_outdoor = true

      case feature.feature_type
      when 'window'
        return target_room unless feature.curtain_state == 'closed'
      when 'door', 'gate', 'hatch'
        return target_room if feature.is_open
      when 'opening', 'archway', 'portal'
        return target_room
      end
    end

    # Only use spatial adjacency if there's no feature connecting to outdoor
    # Features are the "official" connection - if blocked, weather isn't visible
    unless has_feature_to_outdoor
      @room.raw_adjacent_rooms.each do |_direction, rooms|
        rooms.each do |room|
          return room if room.outdoor_room?
        end
      end
    end

    nil
  end

  # Build weather data hash for display
  # @param source_room [Room] the room to get weather from
  # @param from_inside [Boolean] whether viewing from inside (adds "Outside:" prefix)
  # @return [Hash, nil] weather data or nil if no weather
  def build_weather_data(source_room, from_inside: false)
    weather = source_room.location&.weather
    return nil unless weather

    prose = WeatherProseService.prose_for(source_room.location)
    return nil if prose.nil? || prose.empty?

    {
      prefix: from_inside ? 'Outside' : nil,
      prose: prose,
      condition: weather.condition,
      intensity: weather.intensity,
      temperature_c: weather.temperature_c,
      temperature_f: weather.temperature_f&.round
    }
  end
end
