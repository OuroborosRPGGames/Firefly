# frozen_string_literal: true

# Builds battle map visualization data for the client.
# Returns hex grid, participant positions, terrain, and relationship colors.
#
# @example
#   service = BattleMapViewService.new(fight, viewer_instance)
#   data = service.build_map_state
#
class BattleMapViewService
  # Hex scaling constants (from centralized config)
  MIN_HEX_WIDTH = GameConfig::Rendering::BATTLE_MAP[:min_hex_width]
  MAX_HEX_WIDTH = GameConfig::Rendering::BATTLE_MAP[:max_hex_width]
  CONTAINER_WIDTH = GameConfig::Rendering::BATTLE_MAP[:container_width]

  # Hazard symbols for rendering
  HAZARD_SYMBOLS = {
    'fire' => "\u{1F525}",        # Fire emoji
    'electricity' => "\u{26A1}",  # Lightning
    'poison' => "\u{2620}",       # Skull and crossbones
    'trap' => "\u{26A0}",         # Warning
    'acid' => "\u{1F4A7}",        # Droplet
    'gas' => "\u{1F4A8}",         # Wind/gas
    'spike_trap' => "\u{1F4CD}",  # Pin
    'cold' => "\u{2744}",         # Snowflake
    'arrow_trap' => "\u{1F3AF}", # Target
    'pressure_plate' => "\u{23FA}", # Record button
    'magic' => "\u{2728}",        # Sparkles
    'radiation' => "\u{2622}",    # Radioactive
    'slippery' => "\u{1F9CA}"     # Ice cube
  }.freeze

  def initialize(fight, viewer_character_instance)
    @fight = fight
    @viewer = viewer_character_instance
    @room = fight.room
  end

  # Build complete map state for client rendering
  # @return [Hash] map state data
  def build_map_state
    # Fast path: return minimal data while map is being generated
    # (client only needs arena dims + fight_id for loading wireframe + subscription)
    if @fight.battle_map_generating
      return {
        success: true,
        fight_id: @fight.id,
        round_number: @fight.round_number,
        status: @fight.status,
        battle_map_generating: true,
        arena_width: @fight.arena_width,
        arena_height: @fight.arena_height,
        hex_scale: calculate_hex_scale,
        hexes: [],
        participants: [],
        monsters: [],
        timestamp: Time.now.iso8601
      }
    end

    # Load hex records once for reuse across arena dimensions + hex data
    @room_hexes = RoomHex.where(room_id: @room.id).all

    hex_scale = calculate_hex_scale
    viewport_centered = viewport_needs_centering?(hex_scale)
    effective_arena = effective_arena_dimensions
    dynamic_lighting_enabled = GameSetting.boolean('dynamic_lighting_enabled')
    prelit_background = dynamic_lighting_enabled && !@fight.lit_battle_map_url.to_s.strip.empty?

    {
      success: true,
      fight_id: @fight.id,
      round_number: @fight.round_number,
      status: @fight.status,
      battle_map_generating: false,
      arena_width: effective_arena[:width],
      arena_height: effective_arena[:height],
      hex_scale: hex_scale,
      viewport_centered: viewport_centered,
      center_on: viewport_centered ? center_coordinates : nil,
      background_url: prelit_background ? @fight.lit_battle_map_url : @room&.battle_map_image_url,
      background_image_width: background_image_width,
      background_image_height: background_image_height,
      background_contrast: detect_contrast,
      water_mask_url: GameSetting.boolean('battle_map_effects_enabled') ? @room&.battle_map_water_mask_url : nil,
      foliage_mask_url: GameSetting.boolean('battle_map_effects_enabled') ? @room&.battle_map_foliage_mask_url : nil,
      fire_mask_url: GameSetting.boolean('battle_map_effects_enabled') ? @room&.battle_map_fire_mask_url : nil,
      light_sources: dynamic_lighting_enabled ? normalized_light_sources : [],
      lighting_mode: prelit_background ? 'server_prelit' : 'client_full',
      apply_client_ambient: !prelit_background,
      time_of_day_hour: current_hour,
      is_outdoor: outdoor_for_effects?,
      hexes: build_hex_data,
      participants: build_participant_data,
      monsters: build_monster_data,
      pending_animation: pending_animation?,
      round_resolving: round_resolving?,
      animation_round: @fight.round_number - 1,
      timestamp: Time.now.iso8601
    }
  end

  private

  # Compute arena dimensions from actual hex records rather than room feet,
  # to avoid phantom wall columns/rows when the grid overshoots the data.
  # Falls back to fight arena dimensions if no hex records exist.
  def effective_arena_dimensions
    if @room_hexes.any?
      max_x = @room_hexes.map(&:hex_x).max || 0
      max_y = @room_hexes.map(&:hex_y).max || 0
      {
        width: max_x + 1,
        height: max_y >= 2 ? (max_y + 1) / 4 + 1 : 1
      }
    else
      { width: @fight.arena_width, height: @fight.arena_height }
    end
  end

  # Calculate hex width based on arena size
  # @return [Integer] hex width in pixels
  def calculate_hex_scale
    # Flat-top hex grid width formula
    needed_width = @fight.arena_width * 0.75 + 0.5
    hex_width = CONTAINER_WIDTH / needed_width
    hex_width.clamp(MIN_HEX_WIDTH, MAX_HEX_WIDTH).round
  end

  # Check if viewport needs to be centered (map too large)
  # @param hex_scale [Integer] calculated hex width
  # @return [Boolean]
  def viewport_needs_centering?(hex_scale)
    hex_scale == MIN_HEX_WIDTH &&
      (MIN_HEX_WIDTH * (@fight.arena_width * 0.75 + 0.5)) > CONTAINER_WIDTH
  end

  # Get center coordinates (viewer's participant position)
  # @return [Hash, nil] center coordinates or nil
  def center_coordinates
    viewer_participant = @fight.fight_participants.find do |p|
      p.character_instance_id == @viewer.id
    end

    return nil unless viewer_participant

    { x: viewer_participant.hex_x, y: viewer_participant.hex_y }
  end

  # Detect background contrast for border colors
  # @return [String] 'dark' or 'light'
  def detect_contrast
    # Default to dark (white borders) for black backgrounds
    return 'dark' unless @room.battle_map_image_url

    # Check cached contrast in battle_map_config
    config = begin
      @room.parsed_battle_map_config
    rescue StandardError => e
      warn "[BattleMapViewService] Failed to parse battle_map_config: #{e.message}"
      {}
    end
    cached = config['background_contrast']
    return cached if cached

    # Default to dark for uploaded images (can be analyzed on upload later)
    'dark'
  end

  # Get background image dimensions for correct hex-to-image alignment.
  # The webclient needs these to size hexes relative to the image (like the editor does).
  def background_image_dimensions
    @_bg_dims ||= begin
      url = @room&.battle_map_image_url
      return [nil, nil] unless url

      path = File.join('public', url.sub(%r{^/}, ''))
      return [nil, nil] unless File.exist?(path)

      img = Vips::Image.new_from_file(path)
      [img.width, img.height]
    rescue StandardError => e
      warn "[BattleMapViewService] Failed to read image dimensions: #{e.message}"
      [nil, nil]
    end
  end

  def background_image_width
    background_image_dimensions[0]
  end

  def background_image_height
    background_image_dimensions[1]
  end

  # Check if animation is pending for the previous round
  # Animation is available when we're in input phase and just finished a round
  # @return [Boolean]
  def pending_animation?
    @fight.status == 'input' && @fight.round_number > 1
  end

  # True while the round is being resolved or narrated — positions may be
  # partially updated so the client should freeze the map until animation is ready.
  def round_resolving?
    %w[resolving narrative].include?(@fight.status)
  end

  # Build hex terrain data using proper offset hex coordinates
  # @return [Array<Hash>] hex data for rendering
  def build_hex_data
    hexes = []

    # Build hex lookup from pre-loaded hex records
    hex_lookup = @room_hexes.each_with_object({}) do |h, obj|
      obj["#{h.hex_x},#{h.hex_y}"] = h
    end

    valid_coords = HexGrid.hex_coords_for_records(
      @room,
      hexes: @room_hexes,
      fallback_arena_width: @fight.arena_width,
      fallback_arena_height: @fight.arena_height
    )

    # Generate hex data for each valid position
    valid_coords.each do |x, y|
      hex = hex_lookup["#{x},#{y}"]
      hexes << build_single_hex(x, y, hex)
    end

    hexes
  end

  # Build data for a single hex
  # @param x [Integer] hex x coordinate
  # @param y [Integer] hex y coordinate
  # @param hex [RoomHex, nil] existing hex record or nil
  # @return [Hash] hex data
  def build_single_hex(x, y, hex)
    # Check if hex is outside the usable room area (zone polygon boundary)
    outside_polygon = hex_outside_effective_polygon?(x, y)

    if outside_polygon
      # Render as off_map so the renderer can skip these entirely
      return {
        x: x,
        y: y,
        type: 'off_map',
        wall_type: 'zone_boundary',
        cover_object: nil,
        has_cover: false,
        elevation: 0,
        hazard_type: nil,
        hazard_symbol: nil,
        water_type: nil,
        traversable: false,
        surface_type: 'stone',
        description: 'Zone boundary'
      }
    end

    # When no hex record exists and the room has a battle map, treat as wall
    if hex.nil? && @room.has_battle_map
      return {
        x: x,
        y: y,
        type: 'wall',
        cover_object: nil,
        has_cover: false,
        elevation: 0,
        hazard_type: nil,
        hazard_symbol: nil,
        water_type: nil,
        traversable: false,
        surface_type: 'stone',
        description: 'Wall'
      }
    end

    {
      x: x,
      y: y,
      type: hex&.hex_type || 'normal',
      cover_object: hex&.cover_object,
      has_cover: hex&.has_cover || false,
      elevation: hex&.elevation_level || 0,
      hazard_type: hex&.hazard_type,
      hazard_symbol: HAZARD_SYMBOLS[hex&.hazard_type],
      water_type: hex&.water_type,
      difficult_terrain: hex&.difficult_terrain == true,
      traversable: hex&.traversable != false,
      surface_type: hex&.surface_type,
      wall_feature: hex&.wall_feature,
      description: hex&.type_description || 'Open floor space'
    }
  end

  # Check if a hex position is outside the room's usable polygon (zone boundary OR custom polygon)
  # @param hex_x [Integer] hex x coordinate
  # @param hex_y [Integer] hex y coordinate
  # @return [Boolean] true if hex is outside usable area
  def hex_outside_effective_polygon?(hex_x, hex_y)
    # Check if room has any polygon boundary (custom polygon OR zone clipping)
    return false unless @room.is_clipped? || @room.has_custom_polygon?

    # Convert hex coordinates to feet (room-local coordinates)
    # HexGrid standard uses HEX_SIZE_FEET (currently 2 feet per hex)
    hex_size = defined?(HexGrid::HEX_SIZE_FEET) ? HexGrid::HEX_SIZE_FEET : 4.0

    # hex_x is a direct column index (0,1,2,...)
    # hex_y is in offset coordinates where visual rows are spaced 4 apart
    # (y=0,2 → row 0; y=4,6 → row 1; etc.) so divide by 4 for the visual row
    visual_row = hex_y / 4

    bounds = @room.has_custom_polygon? ? @room.polygon_bounds : { min_x: @room.min_x, min_y: @room.min_y }
    feet_x = bounds[:min_x] + (hex_x * hex_size) + (hex_size / 2.0)
    feet_y = bounds[:min_y] + (visual_row * hex_size) + (hex_size / 2.0)

    !@room.position_valid?(feet_x, feet_y)
  end

  # Build participant data with relationships
  # @return [Array<Hash>] participant data for rendering
  def build_participant_data
    @fight.fight_participants.map do |participant|
      build_single_participant(participant)
    end
  end

  # Build monster data for multi-hex monster rendering
  # @return [Array<Hash>] monster data for rendering
  def build_monster_data
    return [] unless @fight.has_monster

    LargeMonsterInstance.where(fight_id: @fight.id).eager(:monster_template).all.map do |monster|
      build_single_monster(monster)
    end
  rescue StandardError => e
    warn "[BattleMapViewService] Error building monsters: #{e.message}"
    []
  end

  # Build data for a single monster
  # @param monster [LargeMonsterInstance]
  # @return [Hash] monster rendering data
  def build_single_monster(monster)
    template = monster.monster_template

    {
      id: monster.id,
      name: template.name,
      monster_type: template.monster_type,

      # Position and size
      center_hex_x: monster.center_hex_x,
      center_hex_y: monster.center_hex_y,
      hex_width: template.hex_width,
      hex_height: template.hex_height,
      facing_direction: monster.facing_direction || 0,

      # Visual
      image_url: template.image_url,

      # Health status
      current_hp: monster.current_hp,
      max_hp: monster.max_hp,
      hp_percent: monster.current_hp_percent,
      status: monster.status,

      # Segments for hitbox detection
      segments: build_segment_data(monster),

      # Occupied hexes (for collision/tooltip)
      occupied_hexes: monster.occupied_hexes
    }
  end

  # Build segment data for a monster
  # @param monster [LargeMonsterInstance]
  # @return [Array<Hash>] segment rendering data
  def build_segment_data(monster)
    facing = monster.facing_direction || 0

    monster.monster_segment_instances.map do |seg|
      template = seg.monster_segment_template
      hex_pos = template.position_at(monster.center_hex_x, monster.center_hex_y, facing)

      {
        id: seg.id,
        name: template.name,
        segment_type: template.segment_type,
        hex_x: hex_pos[0],
        hex_y: hex_pos[1],
        hp_percent: seg.hp_percent,
        status: seg.status,
        is_weak_point: template.is_weak_point || false,
        can_attack: seg.can_attack
      }
    end
  rescue StandardError => e
    warn "[BattleMapViewService] Error building segment data: #{e.message}"
    []
  end

  # Build data for a single participant
  # @param participant [FightParticipant]
  # @return [Hash] participant data
  def build_single_participant(participant)
    character = participant.character_instance&.character
    is_current = participant.character_instance_id == @viewer.id

    # For NPC participants (delve monsters), use NPC-specific builder
    # which hardcodes relationship as :enemy and uses npc_name.
    # Note: is_npc participants may still have a character_instance
    # (from NPC archetypes), so we check is_npc alone, not character.nil?.
    if participant.is_npc
      return build_npc_participant(participant)
    end

    data = {
      id: participant.id,
      character_id: character&.id,
      name: character&.full_name || 'Unknown',
      short_name: build_short_name(character),
      profile_pic_url: character&.picture_url,
      signature_color: character&.distinctive_color,
      hex_x: participant.hex_x || 0,
      hex_y: participant.hex_y || 0,
      is_current_character: is_current,
      relationship: determine_relationship(character),
      is_knocked_out: participant.is_knocked_out || false,
      current_hp: participant.current_hp,
      max_hp: participant.max_hp,
      wetness_level: participant.character_instance&.wetness || 0,
      injury_level: participant.wound_penalty,
      intro: build_character_intro(character, participant.character_instance)
    }

    # Add extended data for self (for GUI combat controls)
    if is_current
      data.merge!(build_self_extended_data(participant))
    end

    data
  end

  # Build data for an NPC participant (delve monster)
  # @param participant [FightParticipant]
  # @return [Hash] NPC participant data
  def build_npc_participant(participant)
    name = participant.npc_name || 'Monster'
    {
      id: participant.id,
      character_id: nil,
      name: name,
      short_name: name[0, 3].upcase,
      profile_pic_url: nil,
      signature_color: '#c04040',
      hex_x: participant.hex_x || 0,
      hex_y: participant.hex_y || 0,
      is_current_character: false,
      relationship: :enemy,
      is_knocked_out: participant.is_knocked_out || false,
      current_hp: participant.current_hp,
      max_hp: participant.max_hp,
      wetness_level: 0,
      injury_level: participant.wound_penalty,
      intro: nil,
      is_npc: true,
      side: participant.side || 2
    }
  end

  # Build extended data for the viewer's own participant
  # @param participant [FightParticipant]
  # @return [Hash] extended combat control data
  def build_self_extended_data(participant)
    {
      # Status effects
      is_burning: StatusEffectService.has_effect?(participant, 'burning'),
      is_prone: StatusEffectService.is_prone?(participant),
      is_mounted: participant.is_mounted || false,

      # Abilities
      main_abilities: build_abilities(participant.available_main_abilities),
      tactical_abilities: build_abilities(participant.available_tactical_abilities),
      selected_ability: participant.ability_id,

      # Monster mounting
      adjacent_monsters: build_adjacent_monsters(participant),

      # Weapons
      current_melee: participant.melee_weapon&.name || 'Unarmed',
      current_ranged: participant.ranged_weapon&.name,

      # Options
      autobattle: participant.autobattle_style,
      ignore_hazard: participant.ignore_hazard_avoidance || false,
      side: participant.side || 1,

      # State
      main_action_set: participant.main_action_set || false,
      willpower_dice: (participant.willpower_dice || 0).to_f
    }
  end

  # Build ability data for GUI
  # @param abilities [Array<Ability>]
  # @return [Array<Hash>]
  def build_abilities(abilities)
    return [] unless abilities

    abilities.map do |ability|
      {
        id: ability.id,
        name: ability.name,
        description: ability.short_description || StringHelper.truncate(ability.description, 50),
        on_cooldown: !ability_available?(ability)
      }
    end
  rescue StandardError => e
    warn "[BattleMapViewService] Error building abilities: #{e.message}"
    []
  end

  # Check if ability is available (not on cooldown)
  # @param ability [Ability]
  # @return [Boolean]
  def ability_available?(ability)
    return true unless ability.respond_to?(:on_cooldown?)

    !ability.on_cooldown?
  rescue StandardError => e
    warn "[BattleMapViewService] Cooldown check error: #{e.message}" if ENV['DEBUG']
    true
  end

  # Build adjacent monsters for mounting
  # @param participant [FightParticipant]
  # @return [Array<Hash>]
  def build_adjacent_monsters(participant)
    return [] unless defined?(LargeMonsterInstance)

    LargeMonsterInstance.where(fight_id: @fight.id).all.select do |monster|
      hex_distance(participant.hex_x, participant.hex_y, monster.center_hex_x, monster.center_hex_y) <= 1
    end.map do |monster|
      {
        id: monster.id,
        name: monster.display_name || 'Monster'
      }
    end
  rescue StandardError => e
    warn "[BattleMapViewService] Error building adjacent monsters: #{e.message}"
    []
  end

  # Calculate hex distance between two positions (offset coordinates)
  # @param x1 [Integer]
  # @param y1 [Integer]
  # @param x2 [Integer]
  # @param y2 [Integer]
  # @return [Integer]
  def hex_distance(x1, y1, x2, y2)
    HexGrid.hex_distance(x1, y1, x2, y2)
  end

  # Build short name (first 3 letters)
  # @param character [Character, nil]
  # @return [String]
  def build_short_name(character)
    return 'UNK' unless character

    name = character.full_name || 'Unknown'
    name[0, 3].upcase
  end

  # Build character intro for tooltip
  # @param character [Character, nil]
  # @param instance [CharacterInstance, nil]
  # @return [String, nil]
  def build_character_intro(character, instance)
    return nil unless character

    # Use short_desc if available
    return character.short_desc if character.short_desc && !character.short_desc.empty?

    # Build a brief description from physical attributes
    parts = []
    parts << "#{character.height_cm}cm" if character.height_cm
    parts << character.body_type if character.body_type
    parts << "#{character.hair_color} hair" if character.hair_color
    parts << "#{character.eye_color} eyes" if character.eye_color

    parts.empty? ? nil : parts.join(', ')
  end

  # Current game hour (0-23) for time-of-day lighting effects.
  # @return [Integer]
  def current_hour
    return 0 if forced_indoor_night_lighting?

    GameTimeService.current_time(@room&.location).hour
  rescue StandardError => e
    warn "[BattleMapViewService] current_hour failed: #{e.class}: #{e.message}"
    12 # Default to noon if time service unavailable
  end

  # Battle map effects should treat forced indoor-night rooms as non-outdoor.
  # @return [Boolean]
  def outdoor_for_effects?
    return false if forced_indoor_night_lighting?

    @room&.outdoor_room?
  end

  # Shared policy with dynamic lighting for underground and delve temp rooms.
  # @return [Boolean]
  def forced_indoor_night_lighting?
    @room&.forced_indoor_night_lighting? || false
  end

  # Normalize light source positions from image-pixel space to 0-1 UV space.
  # The WebGL shader needs UV coords, but detected_light_sources stores pixel coords.
  # @return [Array<Hash>] light sources with center_x/center_y as 0-1 UV
  def normalized_light_sources
    sources = @room&.detected_light_sources || []
    return [] if sources.empty?

    img_w, img_h = battle_map_image_dimensions
    return sources unless img_w && img_h && img_w > 0 && img_h > 0

    normalized_sources = DynamicLightingService.normalize_light_sources_for_image(@room, sources, img_w, img_h)
    max_dim = [img_w, img_h].max.to_f
    normalized_sources.map do |s|
      s = s.respond_to?(:to_hash) ? s.to_hash.dup : s.dup
      s['center_x'] = s['center_x'].to_f / img_w
      s['center_y'] = s['center_y'].to_f / img_h
      # Normalize radius and cap at 0.3 (30% of image) to prevent full-canvas glow
      s['radius_px'] = [s['radius_px'].to_f / max_dim, 0.3].min
      s
    end
  end

  # Get battle map image dimensions (width, height) from the local file.
  # @return [Array<Integer, Integer>, Array<nil, nil>]
  def battle_map_image_dimensions
    return @_image_dims if defined?(@_image_dims)

    url = @room&.battle_map_image_url
    @_image_dims = [nil, nil]
    return @_image_dims if StringHelper.blank?(url)

    path = url.start_with?('/') ? File.join('public', url) : url
    return @_image_dims unless File.exist?(path)

    require 'vips'
    img = Vips::Image.new_from_file(path, access: :sequential)
    @_image_dims = [img.width, img.height]
  rescue StandardError => e
    warn "[BattleMapViewService] Failed to read image dimensions: #{e.message}"
    @_image_dims = [nil, nil]
  end

  # Determine relationship (self, ally, enemy, neutral)
  # Uses Relationship model to determine ally/enemy/neutral status
  # @param target_character [Character, nil]
  # @return [String]
  def determine_relationship(target_character)
    return 'neutral' unless target_character
    return 'self' if @viewer.character_id == target_character.id

    viewer_character = @viewer.character

    # Check if blocked → enemy
    return 'enemy' if Relationship.blocked_between?(viewer_character, target_character)

    # Check for accepted relationship → ally
    rel = Relationship.between(viewer_character, target_character)
    return 'ally' if rel&.accepted?

    'neutral'
  end
end
