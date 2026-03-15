# frozen_string_literal: true

class RoomHex < Sequel::Model(:room_hexes)
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :room

  # Safe defaults for columns that may not exist yet in the database
  # These prevent NoMethodError when code references planned-but-not-yet-migrated columns
  %i[movement_modifier is_ramp is_stairs is_ladder blocks_line_of_sight
     cover_height is_potential_hazard potential_trigger is_explosive
     explosion_radius explosion_damage explosion_trigger hazard_damage_per_round
     hit_points majority_floor passable_edges wall_feature].each do |col|
    unless columns.include?(col)
      define_method(col) { nil }
    end
  end

  # Column aliases - database has hex_type and hazard_type columns
  # terrain_type is kept as an alias for backward compatibility
  def terrain_type
    hex_type
  end

  def terrain_type=(value)
    self[:hex_type] = value
  end

  # hazard_damage_type is kept as an alias for backward compatibility
  def hazard_damage_type
    hazard_type
  end

  def hazard_damage_type=(value)
    self[:hazard_type] = value
  end

  # Valid hex types (extended for battle maps)
  HEX_TYPES = [
    'normal', 'trap', 'fire', 'water', 'pit', 'wall', 'furniture',
    'door', 'window', 'stairs', 'hazard', 'safe', 'treasure',
    'cover', 'difficult', 'explosive', 'debris', 'concealed'
  ].freeze

  # Valid hazard types (extended)
  # Includes both damage types (fire, electricity, etc.) and trap types
  HAZARD_TYPES = [
    'trap', 'fire', 'poison', 'electricity', 'electric', 'cold', 'acid', 'magic',
    'pressure_plate', 'spike_trap', 'arrow_trap', 'gas', 'unstable_floor',
    'sharp', 'radiation', 'slippery', 'physical'
  ].freeze

  # Water types (new)
  WATER_TYPES = %w[puddle wading swimming deep].freeze

  # Cover objects (reference - actual list in CoverObjectType)
  COVER_OBJECTS = %w[
    bed car boulder tree desk counter pillar crate barrel dumpster
    table couch wall_low sandbags debris machinery shelf chair
    truck motorcycle bush log rock
  ].freeze

  # Surface types
  SURFACE_TYPES = %w[
    floor concrete grass sand carpet wood metal tile stone dirt
    gravel water ice mud asphalt rubber
  ].freeze

  # Potential hazard triggers
  POTENTIAL_TRIGGERS = %w[flammable electrifiable collapsible pressurized].freeze

  # Explosion triggers
  EXPLOSION_TRIGGERS = %w[hit fire electric pressure].freeze

  # Default values
  DEFAULT_HEX_TYPE = 'normal'.freeze
  DEFAULT_TRAVERSABLE = true
  DEFAULT_DANGER_LEVEL = 0

  def validate
    super
    validates_presence [:room_id, :hex_x, :hex_y]
    validates_unique [:room_id, :hex_x, :hex_y]
    validates_includes HEX_TYPES, :terrain_type, allow_nil: true  # Database column is terrain_type
    validates_integer :hex_x
    validates_integer :hex_y
    validates_integer :danger_level
    validates_includes HAZARD_TYPES, :hazard_damage_type, allow_nil: true  # Database column is hazard_damage_type

    # New validations for battle map columns
    validates_includes WATER_TYPES, :water_type, allow_nil: true
    # cover_object is not validated against COVER_OBJECTS — AI generation produces
    # arbitrary names (bookshelf, console_station, etc.) that aren't in the static list.
    validates_includes SURFACE_TYPES, :surface_type, allow_nil: true
    # potential_trigger and explosion_trigger stored in special_properties JSONB
    # validates_includes POTENTIAL_TRIGGERS, :potential_trigger, allow_nil: true
    # validates_includes EXPLOSION_TRIGGERS, :explosion_trigger, allow_nil: true

    # Danger level must be 0-10 (validates_integer doesn't have range option in Sequel)
    if danger_level && (danger_level < 0 || danger_level > 10)
      errors.add(:danger_level, 'must be between 0 and 10')
    end

    # Elevation must be -10 to +10
    if elevation_level && (elevation_level < -10 || elevation_level > 10)
      errors.add(:elevation_level, 'must be between -10 and 10')
    end

    # Validate that hex coordinates are within room bounds if room has bounds
    if room && room_has_bounds?
      unless hex_within_room_bounds?
        errors.add(:hex_x, 'hex coordinates outside room bounds')
        errors.add(:hex_y, 'hex coordinates outside room bounds')
      end
    end
  end

  # Check if room has defined bounds
  def room_has_bounds?
    room && room.min_x && room.max_x && room.min_y && room.max_y
  end

  # Check if hex coordinates are within room bounds.
  # When a battle map exists, the hex data IS the bounds — skip feet-based validation.
  def hex_within_room_bounds?
    return true unless room_has_bounds?
    return true if room.has_battle_map

    room_width = room.max_x - room.min_x
    room_height = room.max_y - room.min_y
    arena_w, arena_h = HexGrid.arena_dimensions_from_feet(room_width, room_height)
    hex_max_x = [arena_w - 1, 0].max
    hex_max_y = [(arena_h - 1) * 4 + 2, 0].max

    hex_x >= 0 && hex_x <= hex_max_x &&
      hex_y >= 0 && hex_y <= hex_max_y
  end

  # Check if this hex is dangerous
  def dangerous?
    danger_level.to_i > 0 || !hazard_type.nil?
  end

  # Check if this hex blocks movement
  def blocks_movement?
    !traversable || hex_type == 'wall' || hex_type == 'pit' || hex_type == 'off_map'
  end

  # Direction → bit position (matches HexGrid.hex_neighbors order: N,NE,SE,S,SW,NW)
  EDGE_DIRECTION_BITS = { 'N' => 0, 'NE' => 1, 'SE' => 2, 'S' => 3, 'SW' => 4, 'NW' => 5 }.freeze
  OPPOSITE_EDGES      = { 'N' => 'S', 'NE' => 'SW', 'SE' => 'NW',
                          'S' => 'N', 'SW' => 'NE', 'NW' => 'SE' }.freeze

  # Can this hex be entered from the given travel direction?
  # direction = the direction of movement ('N','NE','SE','S','SW','NW')
  # We check the OPPOSITE edge (the one we crossed to enter).
  # Falls back to true when no pixel data exists (defers to blocks_movement?).
  def passable_from?(direction)
    return true if passable_edges.nil?   # no pixel data, defer to blocks_movement?
    entry_dir = OPPOSITE_EDGES[direction.to_s.upcase]
    bit = EDGE_DIRECTION_BITS[entry_dir]
    return true unless bit
    passable_edges[bit] == 1
  end

  # ========================================
  # Cover System
  # ========================================

  # Check if this hex provides cover
  # @return [Boolean]
  def provides_cover?
    has_cover
  end

  # Get cover description
  # @return [String]
  def cover_description
    return 'no cover' unless provides_cover?

    if cover_object
      "cover (#{cover_object.gsub('_', ' ')})"
    else
      'cover'
    end
  end

  # Destroy this cover object (convert to debris)
  # @return [Boolean] success
  def destroy_cover!
    return false unless provides_cover?
    return false unless destroyable

    update(
      hex_type: 'debris',
      cover_object: 'debris',
      has_cover: false,
      destroyable: false,
      difficult_terrain: true
    )
    true
  end

  # ========================================
  # Water System
  # ========================================

  # Check if this hex has water
  # @return [Boolean]
  def is_water?
    !water_type.nil?
  end

  # Get movement cost multiplier for water
  # @return [Float]
  def water_movement_cost
    case water_type
    when 'puddle' then 1.0
    when 'wading' then 2.0
    when 'swimming' then 3.0
    when 'deep' then Float::INFINITY # requires swimming ability
    else 1.0
    end
  end

  # Check if swimming is required
  # @return [Boolean]
  def requires_swim_check?
    %w[swimming deep].include?(water_type)
  end

  # ========================================
  # Hazard System
  # ========================================

  # Check if this is an active hazard
  # @return [Boolean]
  def is_hazard?
    danger_level.to_i > 0 || !hazard_type.nil?
  end

  # Trigger a potential hazard
  # @param trigger_type [String] what triggered it (flammable, electrifiable, etc.)
  # @return [Boolean] whether it triggered
  def trigger_potential_hazard!(trigger_type)
    return false unless is_potential_hazard && potential_trigger == trigger_type

    case trigger_type
    when 'flammable'
      update(
        hex_type: 'fire',
        hazard_type: 'fire',
        hazard_damage_per_round: 2,
        hazard_damage_type: 'fire',
        is_potential_hazard: false,
        danger_level: 3
      )
    when 'electrifiable'
      update(
        hex_type: 'hazard',
        hazard_type: 'electricity',
        hazard_damage_per_round: 3,
        hazard_damage_type: 'electricity',
        is_potential_hazard: false,
        danger_level: 4
      )
    when 'collapsible'
      update(
        hex_type: 'pit',
        traversable: false,
        is_potential_hazard: false,
        danger_level: 5
      )
    when 'pressurized'
      update(
        hex_type: 'hazard',
        hazard_type: 'gas',
        hazard_damage_per_round: 1,
        hazard_damage_type: 'poison',
        is_potential_hazard: false,
        danger_level: 2
      )
    else
      return false
    end

    true
  end

  # ========================================
  # Explosive System
  # ========================================

  # Trigger an explosion
  # @param fight [Fight] the current fight (for tracking)
  # @return [Hash, nil] explosion data if triggered
  def trigger_explosion!(fight = nil)
    return nil unless is_explosive

    explosion_data = {
      center_x: hex_x,
      center_y: hex_y,
      radius: explosion_radius || 1,
      damage: explosion_damage || 10,
      damage_type: 'explosion'
    }

    # Mark as exploded and convert to fire
    update(
      is_explosive: false,
      hex_type: 'fire',
      hazard_type: 'fire',
      hazard_damage_per_round: 1,
      hazard_damage_type: 'fire',
      danger_level: 2,
      destroyable: false,
      has_cover: false,
      cover_object: nil
    )

    explosion_data
  end

  # Check if this hex should explode based on trigger
  # @param trigger_type [String] what caused the trigger
  # @return [Boolean]
  def should_explode?(trigger_type)
    return false unless is_explosive

    explosion_trigger == trigger_type || trigger_type == 'hit'
  end

  # ========================================
  # Elevation System
  # ========================================

  # Calculate combat modifier based on elevation difference
  # @param attacker_elevation [Integer]
  # @param defender_elevation [Integer]
  # @return [Integer] modifier (+/- based on high/low ground)
  def self.elevation_modifier_for_combat(attacker_elevation, defender_elevation)
    diff = attacker_elevation.to_i - defender_elevation.to_i
    return 0 if diff == 0

    # +1 attack per level up (max +2), -1 per level down (max -2)
    diff.clamp(-2, 2)
  end

  # Check if movement can transition to target hex (elevation)
  # Characters can climb/descend up to 5 elevation levels without
  # special terrain (ramps/stairs/ladders are needed for larger gaps).
  # @param target_hex [RoomHex]
  # @return [Boolean]
  def can_transition_to?(target_hex)
    return true unless target_hex

    elevation_diff = ((target_hex.elevation_level || 0) - (elevation_level || 0)).abs

    return true if elevation_diff == 0
    return true if is_ramp || target_hex.is_ramp
    return true if is_stairs || target_hex.is_stairs
    return true if is_ladder || target_hex.is_ladder

    elevation_diff < 6
  end

  # ========================================
  # Line of Sight
  # ========================================

  # Check if this hex blocks line of sight at a given viewer elevation
  # @param viewer_elevation [Integer]
  # @return [Boolean]
  def blocks_los_at_elevation?(viewer_elevation)
    return false unless blocks_line_of_sight

    # Cover height determines if it blocks LoS
    cover_top = (elevation_level || 0) + (cover_height || 0)
    viewer_elevation.to_i < cover_top
  end

  # ========================================
  # Movement Cost (Extended)
  # ========================================

  # Get calculated movement cost including all terrain factors
  # @return [Float]
  def calculated_movement_cost
    return Float::INFINITY unless traversable

    base_cost = 1.0

    # Apply movement modifier if set
    base_cost *= (movement_modifier || 1.0)

    # Terrain penalties: use the GREATEST penalty, not multiplicative
    # This prevents excessive stacking (difficult + deep water = 2x3 = 6x would be too harsh)
    terrain_penalties = [1.0]
    terrain_penalties << 2.0 if difficult_terrain
    terrain_penalties << water_movement_cost if is_water?
    base_cost *= terrain_penalties.max

    base_cost
  end

  # Legacy movement_cost method (kept for compatibility)
  def movement_cost
    calculated_movement_cost
  end

  # Get special properties as parsed hash
  # Note: special_properties column removed - return empty hash for compatibility
  def parsed_special_properties
    {}
  end

  # Set special properties from hash
  # Note: special_properties column removed - no-op for compatibility
  def set_special_properties(_props_hash)
    # No-op - column removed
  end

  # Get hex type description (extended)
  def type_description
    case hex_type
    when 'normal' then 'Open floor space'
    when 'trap' then 'Hidden trap'
    when 'fire' then 'Burning area'
    when 'water' then water_type ? "#{water_type.capitalize} water" : 'Shallow water'
    when 'pit' then 'Deep pit'
    when 'wall' then 'Solid wall'
    when 'furniture' then 'Furniture or obstruction'
    when 'door' then 'Doorway'
    when 'window' then 'Window'
    when 'stairs' then 'Staircase'
    when 'hazard' then hazard_type ? "#{hazard_type.capitalize} hazard" : 'Environmental hazard'
    when 'safe' then 'Safe area'
    when 'treasure' then 'Treasure location'
    when 'cover' then cover_object ? "#{cover_object.gsub('_', ' ').capitalize}" : 'Cover'
    when 'difficult' then 'Difficult terrain'
    when 'explosive' then 'Explosive'
    when 'debris' then 'Debris'
    when 'concealed' then 'Obscured area'
    else 'Unknown hex type'
    end
  end

  # ========================================
  # Class Methods
  # ========================================

  # Class methods for hex lookup with defaults
  def self.hex_details(room, hex_x, hex_y)
    existing = where(room: room, hex_x: hex_x, hex_y: hex_y).first

    if existing
      existing
    else
      new_with_defaults(room, hex_x, hex_y)
    end
  end

  # Create a temporary object with default values (not saved to database)
  # Missing hexes default to traversable floor — the hex classification pipeline
  # explicitly creates wall/off_map hexes, so anything it didn't classify is
  # open space.  Previously this defaulted to wall for battlemap rooms which
  # blocked pathfinding through unclassified gaps in the hex grid.
  def self.new_with_defaults(room, hex_x, hex_y)
    new.tap do |hex|
      hex.room = room
      hex.hex_x = hex_x
      hex.hex_y = hex_y
      hex.terrain_type = DEFAULT_HEX_TYPE
      hex.traversable = DEFAULT_TRAVERSABLE
      hex.danger_level = DEFAULT_DANGER_LEVEL
      hex.hazard_damage_type = nil
      hex.has_cover = false
      hex.elevation_level = 0
    end
  end

  # Get hex type with default
  def self.hex_type_at(room, hex_x, hex_y)
    hex = hex_details(room, hex_x, hex_y)
    return hex.hex_type if hex

    DEFAULT_HEX_TYPE
  end

  # Check if hex is traversable (considers pixel wall coverage via blocks_movement?)
  def self.traversable_at?(room, hex_x, hex_y)
    hex = hex_details(room, hex_x, hex_y)
    return DEFAULT_TRAVERSABLE unless hex

    !hex.blocks_movement?
  end

  # Check if hex is playable (not blocked AND inside the room polygon).
  # Use this for spawn placement to avoid putting characters in wall/off-map hexes.
  def self.playable_at?(room, hex_x, hex_y)
    # Only hexes with actual DB records are playable — missing hexes are not valid
    room_id = room.respond_to?(:id) ? room.id : room
    return false unless room_id
    hex = where(room_id: room_id, hex_x: hex_x, hex_y: hex_y).first
    return false unless hex

    # blocks_movement? covers hex_type wall/pit/off_map, !traversable, and majority_floor==false
    return false if hex.blocks_movement?

    # wall_feature 'wall' means the hex is visually a wall (from wall mask analysis)
    # even if hex_type is 'normal' — don't spawn characters there
    return false if hex.respond_to?(:wall_feature) && hex.wall_feature == 'wall'

    # If the room has a polygon boundary, verify the hex is inside it
    if room.respond_to?(:is_clipped?) && (room.is_clipped? || room.has_custom_polygon?)
      hex_size = defined?(HexGrid::HEX_SIZE_FEET) ? HexGrid::HEX_SIZE_FEET : 4.0
      # hex_y is in offset coords (visual rows spaced 4 apart), convert to row index
      visual_row = hex_y / 4
      bounds = room.has_custom_polygon? ? room.polygon_bounds : { min_x: room.min_x, min_y: room.min_y }
      feet_x = bounds[:min_x] + (hex_x * hex_size) + (hex_size / 2.0)
      feet_y = bounds[:min_y] + (visual_row * hex_size) + (hex_size / 2.0)
      return false unless room.position_valid?(feet_x, feet_y)
    end

    true
  end

  # Get danger level with default
  def self.danger_level_at(room, hex_x, hex_y)
    hex = hex_details(room, hex_x, hex_y)
    hex ? hex.danger_level : DEFAULT_DANGER_LEVEL
  end

  # Check if hex is dangerous
  def self.dangerous_at?(room, hex_x, hex_y)
    hex = hex_details(room, hex_x, hex_y)
    hex ? hex.dangerous? : false
  end

  # Get elevation at hex
  def self.elevation_at(room, hex_x, hex_y)
    hex = hex_details(room, hex_x, hex_y)
    hex ? (hex.elevation_level || 0) : 0
  end

  # Bulk create or update hex data
  def self.set_hex_details(room, hex_x, hex_y, attributes = {})
    hex = find_or_create(room: room, hex_x: hex_x, hex_y: hex_y) do |h|
      h.hex_type = DEFAULT_HEX_TYPE
      h.traversable = DEFAULT_TRAVERSABLE
      h.danger_level = DEFAULT_DANGER_LEVEL
    end

    hex.update(attributes) if hex && !attributes.empty?
    hex
  end

  # Get all dangerous hexes in a room
  def self.dangerous_hexes_in_room(room)
    where(room: room).where { danger_level > 0 }.or(hazard_type: HAZARD_TYPES)
  end

  # Get all impassable hexes in a room
  def self.impassable_hexes_in_room(room)
    where(room: room, traversable: false)
      .or(hex_type: %w[wall pit])
  end

  # Get all cover hexes in a room
  def self.cover_hexes_in_room(room)
    where(room: room, has_cover: true)
  end

  # Get all explosive hexes in a room
  def self.explosive_hexes_in_room(room)
    where(room: room, is_explosive: true)
  end

  # Get all hexes at a specific elevation
  def self.hexes_at_elevation(room, elevation)
    where(room: room, elevation_level: elevation)
  end
end
