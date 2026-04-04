# frozen_string_literal: true

class WorldHex < Sequel::Model(:world_hexes)
  plugin :validation_helpers
  plugin :timestamps
  
  many_to_one :world

  # Named feature associations (one per directional edge)
  %w[n ne se s sw nw].each do |dir|
    many_to_one :"feature_ref_#{dir}", class: :WorldFeature, key: :"feature_id_#{dir}"
  end

  # Valid terrain types (consolidated list)
  TERRAIN_TYPES = [
    # Water
    'ocean', 'lake',
    # Coastal
    'rocky_coast', 'sandy_coast',
    # Plains
    'grassy_plains', 'rocky_plains',
    # Forest
    'light_forest', 'dense_forest', 'jungle',
    # Wetland
    'swamp',
    # Mountains/Hills
    'mountain', 'grassy_hills', 'rocky_hills',
    # Cold
    'tundra',
    # Arid
    'desert',
    # Volcanic
    'volcanic',
    # Urban
    'urban', 'light_urban'
  ].freeze
  
  # Valid linear features
  FEATURE_TYPES = [
    'road', 'street', 'river', 'railway', 'highway', 'trail', 'canal'
  ].freeze

  # Valid directions for directional features (edge-to-center)
  DIRECTIONS = %w[n ne se s sw nw].freeze

  # Direction opposites for feature continuity
  DIRECTION_OPPOSITES = {
    'n' => 's', 's' => 'n',
    'ne' => 'sw', 'sw' => 'ne',
    'se' => 'nw', 'nw' => 'se'
  }.freeze

  # Feature categories for quick lookups
  ROAD_FEATURES = %w[road highway street trail].freeze
  WATER_FEATURES = %w[river canal].freeze
  RAIL_FEATURES = %w[railway].freeze

  # River width classifications (from procedural generation)
  RIVER_WIDTH_NONE = 0
  RIVER_WIDTH_STREAM = 1
  RIVER_WIDTH_RIVER = 2
  RIVER_WIDTH_MAJOR = 3

  # Default values
  DEFAULT_TERRAIN = 'grassy_plains'.freeze
  DEFAULT_ELEVATION = 0
  DEFAULT_ALTITUDE = DEFAULT_ELEVATION # Alias for backward compatibility
  DEFAULT_TRAVERSABLE = true

  # Neighbor threshold for globe hexes (in degrees)
  # At subdivision 10 (~10.5M hexes), neighbor spacing is ~0.079°.
  # This threshold is only used as a fallback when neighbor_globe_hex_ids is NULL.
  NEIGHBOR_THRESHOLD_DEGREES = 0.12

  def validate
    super
    validates_presence [:world_id, :globe_hex_id]
    validates_includes TERRAIN_TYPES, :terrain_type
    validates_integer :altitude, allow_nil: true
    validates_integer :globe_hex_id

    # Validate uniqueness of globe_hex_id within a world
    validates_unique [:world_id, :globe_hex_id]

    # Validate cross-hex linear features if present (legacy)
    validates_includes FEATURE_TYPES, :feature_nw_se, allow_nil: true
    validates_includes FEATURE_TYPES, :feature_ne_sw, allow_nil: true
    validates_includes FEATURE_TYPES, :feature_w_e, allow_nil: true

    # Validate directional features if present (edge-to-center)
    validates_includes FEATURE_TYPES, :feature_n, allow_nil: true
    validates_includes FEATURE_TYPES, :feature_ne, allow_nil: true
    validates_includes FEATURE_TYPES, :feature_se, allow_nil: true
    validates_includes FEATURE_TYPES, :feature_s, allow_nil: true
    validates_includes FEATURE_TYPES, :feature_sw, allow_nil: true
    validates_includes FEATURE_TYPES, :feature_nw, allow_nil: true
  end

  # Check if this is a globe hex (uses globe_hex_id)
  # All hexes are now globe hexes
  def globe_hex?
    !globe_hex_id.nil?
  end

  # Alias elevation to altitude for backward compatibility
  # Database column is 'altitude', some code uses 'elevation'
  def elevation
    altitude || DEFAULT_ALTITUDE
  end

  def elevation=(value)
    self.altitude = value
  end

  # Default traversable if column doesn't exist or value is nil
  def traversable
    if self.class.columns.include?(:traversable)
      value = super
      value.nil? ? DEFAULT_TRAVERSABLE : value
    else
      DEFAULT_TRAVERSABLE
    end
  end

  # Safe feature accessors that return nil if column doesn't exist
  %w[nw_se ne_sw w_e].each do |direction|
    define_method("feature_#{direction}") do
      column = "feature_#{direction}".to_sym
      self.class.columns.include?(column) ? super() : nil
    end
  end

  DIRECTIONS.each do |direction|
    define_method("feature_#{direction}") do
      column = "feature_#{direction}".to_sym
      self.class.columns.include?(column) ? super() : nil
    end
  end

  # Get all linear features present in this hex
  def linear_features
    features = {}
    features['nw_se'] = feature_nw_se if feature_nw_se
    features['ne_sw'] = feature_ne_sw if feature_ne_sw
    features['w_e'] = feature_w_e if feature_w_e
    features
  end
  
  # Check if hex has any linear features (legacy cross-hex)
  def linear_features?
    !!(feature_nw_se || feature_ne_sw || feature_w_e)
  end
  alias has_linear_features? linear_features?

  # Get all directional features (edge-to-center)
  def directional_features
    DIRECTIONS.each_with_object({}) do |dir, features|
      value = send("feature_#{dir}")
      features[dir] = value if value
    end
  end

  # Check if hex has any directional features
  def directional_features?
    DIRECTIONS.any? { |dir| send("feature_#{dir}") }
  end
  alias has_directional_features? directional_features?

  # Check if hex has any features at all
  def any_features?
    linear_features? || directional_features?
  end
  alias has_any_features? any_features?

  # Get directional feature by direction
  def directional_feature(direction)
    dir = direction.to_s.downcase
    return nil unless DIRECTIONS.include?(dir)

    send("feature_#{dir}")
  end

  # Get directional features with names and IDs
  def directional_feature_details
    DIRECTIONS.each_with_object({}) do |dir, features|
      value = send("feature_#{dir}")
      next unless value

      fid = respond_to?(:"feature_id_#{dir}") ? send("feature_id_#{dir}") : nil
      features[dir] = {
        type: value,
        feature_id: fid,
        name: fid ? send("feature_ref_#{dir}")&.name : nil
      }
    end
  end

  # Set a directional feature
  def set_directional_feature(direction, feature_type, feature_id: nil)
    dir = direction.to_s.downcase
    return false unless DIRECTIONS.include?(dir)
    return false if feature_type && !FEATURE_TYPES.include?(feature_type)

    attrs = { "feature_#{dir}" => feature_type }
    attrs["feature_id_#{dir}"] = feature_id if self.class.columns.include?(:"feature_id_#{dir}")
    update(attrs)
    true
  end

  # Remove a directional feature
  def remove_directional_feature(direction)
    set_directional_feature(direction, nil)
  end

  # Check if hex has roads (any type)
  def road?
    DIRECTIONS.any? { |dir| ROAD_FEATURES.include?(send("feature_#{dir}")) }
  end
  alias has_road? road?

  # Check if hex has water features (river, canal)
  def river?
    DIRECTIONS.any? { |dir| WATER_FEATURES.include?(send("feature_#{dir}")) }
  end
  alias has_river? river?

  # Check if hex has railway
  def railway?
    DIRECTIONS.any? { |dir| RAIL_FEATURES.include?(send("feature_#{dir}")) }
  end
  alias has_railway? railway?

  # ============================================
  # Hydrology helpers (from procedural generation)
  # ============================================

  # Get river edges as array (from procedural generation river_edges column)
  def river_edge_directions
    river_edges || []
  end

  # Check if hex has a river from procedural generation
  def procedural_river?
    !river_edge_directions.empty? || (river_width && river_width > 0)
  end
  alias has_procedural_river? procedural_river?

  # Check if hex is part of a lake
  def part_of_lake?
    !lake_id.nil?
  end

  # Get river width classification
  def river_width_class
    case river_width
    when RIVER_WIDTH_STREAM then :stream
    when RIVER_WIDTH_RIVER then :river
    when RIVER_WIDTH_MAJOR then :major_river
    else :none
    end
  end

  # Get human-readable river description
  def river_description
    return nil unless has_procedural_river?

    case river_width_class
    when :stream then 'A small stream flows through here'
    when :river then 'A river flows through here'
    when :major_river then 'A major river flows through here'
    else nil
    end
  end

  # ============================================
  # Climate helpers (from procedural generation)
  # ============================================

  # Get temperature in Celsius (nil if not set)
  def temperature_celsius
    temperature
  end

  # Get temperature in Fahrenheit
  def temperature_fahrenheit
    return nil if temperature.nil?

    (temperature * 9.0 / 5.0) + 32
  end

  # Get climate zone based on temperature
  def climate_zone
    return nil if temperature.nil?

    case temperature
    when -Float::INFINITY...0 then :polar
    when 0...10 then :subpolar
    when 10...20 then :temperate
    when 20...30 then :subtropical
    else :tropical
    end
  end

  # Get moisture classification
  def moisture_class
    return nil if moisture.nil?

    case moisture
    when 0...0.2 then :arid
    when 0.2...0.4 then :semi_arid
    when 0.4...0.6 then :moderate
    when 0.6...0.8 then :humid
    else :very_humid
    end
  end

  # Get opposite direction
  def self.opposite_direction(direction)
    DIRECTION_OPPOSITES[direction.to_s.downcase]
  end

  # API representation for JSON responses
  def to_api_hash
    {
      id: id,
      world_id: world_id,
      globe_hex_id: globe_hex_id,
      latitude: latitude,
      longitude: longitude,
      terrain_type: terrain_type,
      altitude: altitude,
      traversable: traversable,
      directional_features: directional_features,
      feature_details: directional_feature_details,
      linear_features: linear_features,
      movement_cost: movement_cost,
      blocks_sight: blocks_sight?,
      has_road: has_road?,
      has_river: has_river?,
      has_railway: has_railway?,
      # Hydrology data from procedural generation
      river_edges: river_edge_directions,
      river_width: river_width,
      lake_id: lake_id,
      # Climate data from procedural generation
      temperature: temperature,
      moisture: moisture,
      # Tectonic data
      plate_id: plate_id
    }
  end

  # Get movement cost for this terrain type
  def movement_cost
    case terrain_type
    when 'ocean', 'lake'
      10  # Requires swimming/boat
    when 'mountain'
      4   # Difficult terrain
    when 'swamp', 'tundra', 'jungle', 'volcanic'
      3   # Challenging terrain
    when 'dense_forest', 'grassy_hills', 'rocky_hills', 'rocky_coast'
      2   # Moderate terrain
    when 'desert', 'rocky_plains'
      2   # Difficult footing
    when 'urban'
      1   # Easy movement
    else
      1   # Default (grassy_plains, light_forest, sandy_coast, light_urban)
    end
  end

  # Check if terrain blocks line of sight
  def blocks_sight?
    case terrain_type
    when 'dense_forest', 'jungle', 'mountain', 'urban', 'volcanic'
      true
    else
      false
    end
  end

  # Get terrain description
  def terrain_description
    case terrain_type
    when 'ocean' then 'Deep blue ocean waters'
    when 'lake' then 'Clear lake water'
    when 'rocky_coast' then 'Rocky coastline'
    when 'sandy_coast' then 'Sandy beach'
    when 'grassy_plains' then 'Open grassland'
    when 'rocky_plains' then 'Rocky flatlands'
    when 'light_forest' then 'Scattered woodland'
    when 'dense_forest' then 'Dense forest'
    when 'jungle' then 'Tropical jungle'
    when 'swamp' then 'Murky wetlands'
    when 'mountain' then 'Rocky peaks'
    when 'grassy_hills' then 'Grassy hills'
    when 'rocky_hills' then 'Rocky hills'
    when 'tundra' then 'Frozen tundra'
    when 'desert' then 'Sandy desert'
    when 'volcanic' then 'Volcanic terrain'
    when 'urban' then 'Dense urban area'
    when 'light_urban' then 'Suburban area'
    else 'Unknown terrain'
    end
  end
  
  # Class methods for hex lookup with defaults
  # @param world [World] the world to search
  # @param globe_hex_id [Integer] the globe hex ID
  # @return [WorldHex, nil] the hex or a new unsaved hex with defaults
  def self.hex_details(world, globe_hex_id)
    # Try to find existing hex data
    existing = where(world: world, globe_hex_id: globe_hex_id).first

    if existing
      existing
    else
      # Return default values without saving to database
      new_with_defaults(world, globe_hex_id)
    end
  end

  # Create a temporary object with default values (not saved to database)
  # @param world [World] the world
  # @param globe_hex_id [Integer] the globe hex ID
  # @return [WorldHex] unsaved hex with defaults
  def self.new_with_defaults(world, globe_hex_id)
    new.tap do |hex|
      hex.world = world
      hex.globe_hex_id = globe_hex_id
      hex.terrain_type = DEFAULT_TERRAIN
      hex.altitude = DEFAULT_ALTITUDE
    end
  end

  # Get terrain type with default by globe_hex_id
  # @param world [World] the world
  # @param globe_hex_id [Integer] the globe hex ID
  # @return [String] terrain type
  def self.terrain_at(world, globe_hex_id)
    hex = hex_details(world, globe_hex_id)
    hex ? hex.terrain_type : DEFAULT_TERRAIN
  end

  # Get terrain type at latitude/longitude
  # @param world [World] the world
  # @param lat [Float] latitude in degrees
  # @param lon [Float] longitude in degrees
  # @return [String] terrain type
  def self.terrain_at_latlon(world, lat, lon)
    hex = find_nearest_by_latlon(world.id, lat, lon)
    hex ? hex.terrain_type : DEFAULT_TERRAIN
  end

  # Get altitude with default by globe_hex_id
  # @param world [World] the world
  # @param globe_hex_id [Integer] the globe hex ID
  # @return [Integer] altitude
  def self.altitude_at(world, globe_hex_id)
    hex = hex_details(world, globe_hex_id)
    hex ? hex.altitude : DEFAULT_ALTITUDE
  end

  # Check if hex is traversable by globe_hex_id
  # @param world [World] the world
  # @param globe_hex_id [Integer] the globe hex ID
  # @return [Boolean] traversable status
  def self.traversable_at?(world, globe_hex_id)
    hex = hex_details(world, globe_hex_id)
    hex ? hex.traversable : DEFAULT_TRAVERSABLE
  end

  # Get linear features at hex by globe_hex_id
  # @param world [World] the world
  # @param globe_hex_id [Integer] the globe hex ID
  # @return [Hash] linear features
  def self.linear_features_at(world, globe_hex_id)
    hex = hex_details(world, globe_hex_id)
    hex ? hex.linear_features : {}
  end

  # Bulk create or update hex data by globe_hex_id
  # @param world [World] the world
  # @param globe_hex_id [Integer] the globe hex ID
  # @param attributes [Hash] attributes to set
  # @return [WorldHex] the created or updated hex
  def self.set_hex_details(world, globe_hex_id, attributes = {})
    hex = find_or_create(world: world, globe_hex_id: globe_hex_id) do |h|
      h.terrain_type = DEFAULT_TERRAIN
      h.altitude = DEFAULT_ALTITUDE
    end

    hex.update(attributes) if hex && !attributes.empty?
    hex
  end

  # ============================================
  # Icosahedral coordinate helpers (3D globe)
  # ============================================

  # Return icosahedral coordinates as an array [face, x, y]
  def ico_coords
    [ico_face, ico_x, ico_y]
  end

  # Find a hex by its JS globe hex ID
  def self.find_by_globe_hex(world_id, globe_hex_id)
    where(world_id: world_id, globe_hex_id: globe_hex_id).first
  end

  # Find a hex by its icosahedral coordinates
  def self.find_by_ico_coords(world_id, face, x, y)
    where(world_id: world_id, ico_face: face, ico_x: x, ico_y: y).first
  end

  # Find the nearest hex to a given latitude/longitude
  # Uses bounding box filter first, then refines with great circle distance
  # @param world_id [Integer] the world ID to search
  # @param lat [Float] latitude in degrees (-90 to 90)
  # @param lon [Float] longitude in degrees (-180 to 180)
  # @return [WorldHex, nil] the nearest hex or nil if world has no hexes
  def self.find_nearest_by_latlon(world_id, lat, lon)
    # Try progressively wider bounding box searches
    [5.0, 15.0, 45.0].each do |search_radius|
      # Handle longitude wrap-around near antimeridian
      lon_min = lon - search_radius
      lon_max = lon + search_radius

      candidates = if lon_min < -180 || lon_max > 180
                     # Near antimeridian - split query
                     where(world_id: world_id)
                       .where { (latitude >= lat - search_radius) & (latitude <= lat + search_radius) }
                       .where { (longitude >= ((lon_min + 360) % 360 - 180)) | (longitude <= ((lon_max + 360) % 360 - 180)) }
                       .limit(500)
                       .all
                   else
                     where(world_id: world_id)
                       .where { (latitude >= lat - search_radius) & (latitude <= lat + search_radius) }
                       .where { (longitude >= lon_min) & (longitude <= lon_max) }
                       .limit(500)
                       .all
                   end

      next if candidates.empty?

      return candidates.min_by do |hex|
        great_circle_distance_rad(lat, lon, hex.latitude, hex.longitude)
      end
    end

    nil
  end

  # Find all neighboring hexes.
  # Fast path: uses precomputed neighbor_globe_hex_ids (populated by boundary service).
  # Fallback: spatial search within NEIGHBOR_THRESHOLD_DEGREES.
  # @param hex [WorldHex] the center hex
  # @return [Array<WorldHex>] neighboring hexes (not including the center hex)
  def self.neighbors_of(hex)
    return [] if hex.latitude.nil? || hex.longitude.nil?

    # Fast path: use precomputed neighbor IDs from boundary computation
    if hex.neighbor_globe_hex_ids && !hex.neighbor_globe_hex_ids.empty?
      return where(world_id: hex.world_id, globe_hex_id: hex.neighbor_globe_hex_ids.to_a).all
    end

    # Slow fallback: spatial search (for hexes without precomputed neighbors)
    lat = hex.latitude
    lon = hex.longitude
    threshold_rad = NEIGHBOR_THRESHOLD_DEGREES * Math::PI / 180.0

    # Bounding box filter
    lon_threshold = if lat.abs > 85
                      180.0
                    else
                      [NEIGHBOR_THRESHOLD_DEGREES / Math.cos(lat * Math::PI / 180.0), 180.0].min
                    end

    lon_min = lon - lon_threshold
    lon_max = lon + lon_threshold

    candidates = where(world_id: hex.world_id)
      .where { (latitude >= lat - NEIGHBOR_THRESHOLD_DEGREES) & (latitude <= lat + NEIGHBOR_THRESHOLD_DEGREES) }
      .exclude(id: hex.id)

    # Handle antimeridian wrapping
    if lon_min < -180
      candidates = candidates.where { (longitude >= lon_min + 360) | (longitude <= lon_max) }
    elsif lon_max > 180
      candidates = candidates.where { (longitude >= lon_min) | (longitude <= lon_max - 360) }
    else
      candidates = candidates.where { (longitude >= lon_min) & (longitude <= lon_max) }
    end

    candidates.all.select do |candidate|
      great_circle_distance_rad(lat, lon, candidate.latitude, candidate.longitude) <= threshold_rad
    end
  end

  # Calculate great circle distance between two points using Haversine formula
  # @param lat1 [Float] first point latitude in degrees
  # @param lon1 [Float] first point longitude in degrees
  # @param lat2 [Float] second point latitude in degrees
  # @param lon2 [Float] second point longitude in degrees
  # @return [Float] angular distance in radians
  def self.great_circle_distance_rad(lat1, lon1, lat2, lon2)
    # Convert to radians
    lat1_rad = lat1 * Math::PI / 180.0
    lon1_rad = lon1 * Math::PI / 180.0
    lat2_rad = lat2 * Math::PI / 180.0
    lon2_rad = lon2 * Math::PI / 180.0

    dlat = lat2_rad - lat1_rad
    dlon = lon2_rad - lon1_rad

    # Haversine formula
    a = Math.sin(dlat / 2)**2 + Math.cos(lat1_rad) * Math.cos(lat2_rad) * Math.sin(dlon / 2)**2
    2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
  end

  # Approximate hex distance between two Locations using great-circle distance.
  # Earth radius ~6371 km, 1 hex ~5 km.
  # @param origin [Location] starting location
  # @param destination [Location] ending location
  # @return [Integer] approximate hex distance, or 0 if coordinates missing
  def self.location_hex_distance(origin, destination)
    return 0 unless origin.latitude && origin.longitude && destination.latitude && destination.longitude

    distance_rad = great_circle_distance_rad(
      origin.latitude, origin.longitude,
      destination.latitude, destination.longitude
    )
    (distance_rad * 6371 / 5).round
  end

  # Determine compass direction from one hex to another using lat/lon.
  # @param from_hex [#latitude, #longitude] origin hex or location
  # @param to_hex [#latitude, #longitude] destination hex or location
  # @return [String, nil] direction string ('n','ne','se','s','sw','nw') or nil if same location
  def self.direction_between_hexes(from_hex, to_hex)
    return nil if from_hex.nil? || to_hex.nil?

    dlat = to_hex.latitude - from_hex.latitude
    dlon = to_hex.longitude - from_hex.longitude

    # Normalize longitude difference for antimeridian wrapping
    dlon -= 360 if dlon > 180
    dlon += 360 if dlon < -180

    return nil if dlat.abs < 0.01 && dlon.abs < 0.01

    angle = Math.atan2(dlon, dlat) * 180.0 / Math::PI

    case angle
    when -30..30    then 'n'
    when 30..90     then 'ne'
    when 90..150    then 'se'
    when 150..180, -180..-150 then 's'
    when -150..-90  then 'sw'
    when -90..-30   then 'nw'
    else 'n'
    end
  end

  # ============================================
  # Traversability Helpers (for globe hexes)
  # ============================================

  # Get all traversable hexes within a lat/lon bounding box
  # @param world [World] the world to query
  # @param min_lat [Float] minimum latitude in degrees
  # @param max_lat [Float] maximum latitude in degrees
  # @param min_lon [Float] minimum longitude in degrees
  # @param max_lon [Float] maximum longitude in degrees
  # @return [Sequel::Dataset] dataset of traversable hexes
  def self.traversable_in_region(world, min_lat:, max_lat:, min_lon:, max_lon:)
    where(world_id: world.id)
      .where { (latitude >= min_lat) & (latitude <= max_lat) }
      .where { (longitude >= min_lon) & (longitude <= max_lon) }
      .where(traversable: true)
  end

  # Count traversable hexes in a world
  # @param world [World] the world to query
  # @return [Integer] count of traversable hexes
  def self.count_traversable(world)
    where(world_id: world.id, traversable: true).count
  end

  # Bulk update traversability for a lat/lon bounding box
  # @param world [World] the world to update
  # @param min_lat [Float] minimum latitude in degrees
  # @param max_lat [Float] maximum latitude in degrees
  # @param min_lon [Float] minimum longitude in degrees
  # @param max_lon [Float] maximum longitude in degrees
  # @param traversable [Boolean] the traversability value to set
  # @return [Integer] number of hexes updated
  def self.set_traversable_in_region(world, min_lat:, max_lat:, min_lon:, max_lon:, traversable:)
    where(world_id: world.id)
      .where { (latitude >= min_lat) & (latitude <= max_lat) }
      .where { (longitude >= min_lon) & (longitude <= max_lon) }
      .update(traversable: traversable)
  end

  # Bulk update traversability for an entire world
  # @param world [World] the world to update
  # @param traversable [Boolean] the traversability value to set
  # @return [Integer] number of hexes updated
  def self.set_all_traversable(world, traversable:)
    where(world_id: world.id).update(traversable: traversable)
  end

  # ============================================
  # H3 Geospatial Index
  # Uses h3-pg SQL functions when available, falls back to h3 Ruby gem.
  # ============================================

  # Compute and assign h3_index from lat/lon at resolution 7 (~5 km hexes).
  # Does NOT persist — caller is responsible for saving.
  def compute_h3_index
    if latitude.nil? || longitude.nil?
      self.h3_index = nil
      return
    end

    # Prefer h3-pg SQL (faster, no Ruby overhead)
    result = DB["SELECT h3_latlng_to_cell(point(?, ?), 7)::bigint AS h3",
                 longitude.to_f, latitude.to_f].first
    self.h3_index = result[:h3]
  rescue Sequel::DatabaseError
    # h3-pg not available, fall back to Ruby gem
    self.h3_index = H3.from_geo_coordinates([latitude.to_f, longitude.to_f], 7).to_i
  rescue StandardError => e
    warn "[WorldHex] H3 computation failed: #{e.message}"
    self.h3_index = nil
  end

  # After a successful save, backfill h3_index when coordinates are present but
  # the index is missing. Uses self.this.update to avoid re-triggering hooks.
  def after_save
    super
    return unless h3_index.nil? && !latitude.nil? && !longitude.nil?

    compute_h3_index
    self.this.update(h3_index: h3_index) if h3_index
  end
end