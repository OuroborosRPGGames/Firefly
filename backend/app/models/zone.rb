# frozen_string_literal: true

class Zone < Sequel::Model
  include SeasonalContentCore

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :world
  one_to_many :locations

  # Valid zone subtypes (primarily for 'area' zone_type)
  ZONE_SUBTYPES = %w[lake mountain mountain_range forest swamp jungle desert volcano].freeze

  # Terrain compatibility for each zone subtype
  # core: terrains that always belong in this zone type
  # edge: terrains allowed only near the zone boundary (transitional)
  SUBTYPE_TERRAIN_MAP = {
    'lake'           => { core: %w[lake], edge: %w[swamp sandy_coast rocky_coast grassy_plains light_forest] },
    'mountain'       => { core: %w[mountain mountain_peak rocky_hills], edge: %w[grassy_hills rocky_plains light_forest tundra] },
    'mountain_range' => { core: %w[mountain mountain_peak rocky_hills grassy_hills], edge: %w[rocky_plains light_forest tundra dense_forest] },
    'forest'         => { core: %w[dense_forest light_forest], edge: %w[grassy_plains grassy_hills jungle swamp] },
    'swamp'          => { core: %w[swamp], edge: %w[lake light_forest grassy_plains jungle] },
    'jungle'         => { core: %w[jungle], edge: %w[dense_forest swamp grassy_plains light_forest] },
    'desert'         => { core: %w[desert rocky_plains], edge: %w[grassy_plains rocky_hills sandy_coast tundra] },
    'volcano'        => { core: %w[volcanic mountain mountain_peak], edge: %w[rocky_hills rocky_plains desert] }
  }.freeze

  def validate
    super
    validates_presence [:name, :world_id]
    validates_unique [:world_id, :name]
    validates_max_length 100, :name
    validates_includes %w[political area location city wilderness], :zone_type
    validates_integer :danger_level, range: 1..10
    validates_includes ZONE_SUBTYPES, :zone_subtype, allow_nil: true
    if zone_subtype && zone_type != 'area'
      errors.add(:zone_subtype, 'is only allowed for area zones')
    end

    # Validate geographic coordinates if provided (legacy support)
    validates_numeric :min_longitude, range: -180..180, allow_nil: true
    validates_numeric :max_longitude, range: -180..180, allow_nil: true
    validates_numeric :min_latitude, range: -90..90, allow_nil: true
    validates_numeric :max_latitude, range: -90..90, allow_nil: true

    # Validate that min coordinates are less than max coordinates
    if min_longitude && max_longitude && min_longitude > max_longitude
      errors.add(:min_longitude, 'must be less than max_longitude')
    end

    if min_latitude && max_latitude && min_latitude > max_latitude
      errors.add(:min_latitude, 'must be less than max_latitude')
    end
  end

  def active_locations
    locations.where(active: true)
  end

  # ===== POLYGON METHODS =====

  # Get polygon points as array of hashes
  # @return [Array<Hash>] Array of {x:, y:} coordinate hashes
  def polygon_points
    pts = self[:polygon_points]
    return [] if pts.nil?
    return [] if pts.is_a?(Array) && pts.empty?
    return [] if pts.is_a?(String) && pts.strip.empty?

    pts.is_a?(String) ? JSON.parse(pts) : pts
  end

  # Set polygon points from array of hashes
  # @param points [Array<Hash>] Array of {x:, y:} or {'x' =>, 'y' =>} hashes
  def polygon_points=(points)
    @polygon_changed = true
    self[:polygon_points] = if points.nil?
                              Sequel.pg_jsonb_wrap([])
                            elsif points.is_a?(String)
                              Sequel.pg_jsonb_wrap(JSON.parse(points))
                            else
                              Sequel.pg_jsonb_wrap(points)
                            end
  end

  # Hook: after saving, recalculate room polygons if polygon changed
  def after_save
    super
    if @polygon_changed
      @polygon_changed = false
      recalculate_location_rooms
    end
  end

  # Recalculate effective polygons for all rooms in all locations in this zone
  # Called automatically when polygon_points changes
  # @return [Hash] aggregate results from all locations
  def recalculate_location_rooms
    return { locations: 0, kept: 0, deleted: 0 } unless has_polygon?

    RoomPolygonService.recalculate_zone(self)
  rescue StandardError => e
    warn "[Zone] Error recalculating room polygons: #{e.message}"
    { locations: 0, kept: 0, deleted: 0, error: e.message }
  end

  # Clear the polygon (removes zone boundary)
  # Resets all rooms to full usable area
  def clear_polygon!
    locations.each do |location|
      RoomPolygonService.reset_location_polygon_status(location)
    end
    update(polygon_points: [])
  end

  # Check if zone has valid polygon (at least 3 points)
  def has_polygon?
    polygon_points.length >= 3
  end
  alias polygon? has_polygon?

  # Point-in-polygon using ray casting algorithm
  # @param x [Numeric] X coordinate to test
  # @param y [Numeric] Y coordinate to test
  # @return [Boolean] true if point is inside polygon
  def contains_point?(x, y)
    points = polygon_points
    return false if points.length < 3

    inside = false
    j = points.length - 1

    points.each_with_index do |point_i, i|
      xi = (point_i['x'] || point_i[:x]).to_f
      yi = (point_i['y'] || point_i[:y]).to_f
      xj = (points[j]['x'] || points[j][:x]).to_f
      yj = (points[j]['y'] || points[j][:y]).to_f

      if ((yi > y) != (yj > y)) &&
         (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
        inside = !inside
      end
      j = i
    end

    inside
  end

  # Check if hex is within polygon bounds
  # @param hex_x [Integer] Hex X coordinate
  # @param hex_y [Integer] Hex Y coordinate
  # @return [Boolean]
  def contains_hex?(hex_x, hex_y)
    contains_point?(hex_x, hex_y)
  end

  # Calculate bounding box from polygon (for quick rejection in queries)
  # @return [Hash, nil] {min_x:, max_x:, min_y:, max_y:} or nil if no polygon
  def bounding_box
    points = polygon_points
    return nil if points.empty?

    xs = points.map { |p| (p['x'] || p[:x]).to_f }
    ys = points.map { |p| (p['y'] || p[:y]).to_f }

    {
      min_x: xs.min, max_x: xs.max,
      min_y: ys.min, max_y: ys.max
    }
  end

  # Center point of polygon (centroid)
  # @return [Hash, nil] {x:, y:} or nil if no polygon
  def center_point
    points = polygon_points
    return nil if points.empty?

    sum_x = points.sum { |p| (p['x'] || p[:x]).to_f }
    sum_y = points.sum { |p| (p['y'] || p[:y]).to_f }

    { x: sum_x / points.length, y: sum_y / points.length }
  end

  # Calculate polygon area using shoelace formula
  # Used for finding "innermost" (smallest) zone at a point
  # @return [Float] Area in square units
  def polygon_area
    points = polygon_points
    return 0.0 if points.length < 3

    sum = 0.0
    points.each_with_index do |p1, i|
      p2 = points[(i + 1) % points.length]
      x1 = (p1['x'] || p1[:x]).to_f
      y1 = (p1['y'] || p1[:y]).to_f
      x2 = (p2['x'] || p2[:x]).to_f
      y2 = (p2['y'] || p2[:y]).to_f
      sum += (x1 * y2) - (x2 * y1)
    end
    (sum / 2.0).abs
  end

  # Check if this zone overlaps with another zone
  # Uses bounding box for quick rejection, then vertex containment
  # @param other_zone [Zone] Zone to check overlap with
  # @return [Boolean]
  def overlaps_with?(other_zone)
    # Quick rejection via bounding box
    bb1 = bounding_box
    bb2 = other_zone.bounding_box
    return false if bb1.nil? || bb2.nil?

    return false if bb1[:max_x] < bb2[:min_x] || bb2[:max_x] < bb1[:min_x]
    return false if bb1[:max_y] < bb2[:min_y] || bb2[:max_y] < bb1[:min_y]

    # If bounding boxes overlap, check if any vertex is inside the other
    polygon_points.any? { |p| other_zone.contains_point?(p['x'] || p[:x], p['y'] || p[:y]) } ||
      other_zone.polygon_points.any? { |p| contains_point?(p['x'] || p[:x], p['y'] || p[:y]) }
  end

  # ===== POLYGON COORDINATE SCALE METHODS =====

  # Get the coordinate scale of this polygon
  # @return [String] 'world' (hex coordinates) or 'local' (feet)
  def polygon_scale
    self[:polygon_scale] || 'world'
  end

  # Check if polygon uses local/feet coordinates
  # @return [Boolean]
  def local_scale?
    polygon_scale == 'local'
  end

  # Check if polygon uses world/hex coordinates
  # @return [Boolean]
  def world_scale?
    polygon_scale != 'local'
  end

  # Check if a point (in local/feet coordinates) is inside the polygon
  # Automatically transforms coordinates if polygon uses world scale
  # @param local_x [Numeric] X coordinate in feet (city-local)
  # @param local_y [Numeric] Y coordinate in feet (city-local)
  # @param origin_x [Numeric] World hex X where city is anchored
  # @param origin_y [Numeric] World hex Y where city is anchored
  # @return [Boolean] true if point is inside polygon
  def contains_local_point?(local_x, local_y, origin_x: 0, origin_y: 0)
    return true unless has_polygon?

    if local_scale?
      # Local-scale polygon - coordinates are already in feet
      contains_point?(local_x, local_y)
    else
      # World-scale polygon - transform local (feet) → world (hex) first
      # World hex size is ~3 miles = 15,840 feet
      hex_size = 15_840.0
      world_x = origin_x + (local_x / hex_size)
      world_y = origin_y + (local_y / hex_size)
      contains_point?(world_x, world_y)
    end
  end

  # ===== LEGACY GEOGRAPHIC METHODS (for backward compatibility) =====

  # Check if zone has geographic bounds defined (legacy rectangular bounds)
  def has_geographic_bounds?
    min_longitude && max_longitude && min_latitude && max_latitude
  end
  alias geographic_bounds? has_geographic_bounds?

  # Get the geographic bounds as a hash (legacy)
  def geographic_bounds
    if has_geographic_bounds?
      {
        min_longitude: min_longitude,
        max_longitude: max_longitude,
        min_latitude: min_latitude,
        max_latitude: max_latitude
      }
    end
  end

  # Set geographic bounds from a hash or array (legacy)
  def geographic_bounds=(bounds)
    if bounds.is_a?(Hash)
      self.min_longitude = bounds[:min_longitude] || bounds['min_longitude']
      self.max_longitude = bounds[:max_longitude] || bounds['max_longitude']
      self.min_latitude = bounds[:min_latitude] || bounds['min_latitude']
      self.max_latitude = bounds[:max_latitude] || bounds['max_latitude']
    elsif bounds.is_a?(Array) && bounds.length >= 4
      # [min_lon, min_lat, max_lon, max_lat]
      self.min_longitude = bounds[0]
      self.min_latitude = bounds[1]
      self.max_longitude = bounds[2]
      self.max_latitude = bounds[3]
    end
  end

  # Calculate the zone size in square degrees (legacy)
  def geographic_area
    return nil unless has_geographic_bounds?

    (max_longitude - min_longitude) * (max_latitude - min_latitude)
  end

  # ===== ZONE GRID METHODS =====

  # Convert zone grid coordinates to longitude/latitude
  def zone_grid_to_lonlat(grid_x, grid_y)
    require_relative '../lib/zone_grid'
    ZoneGrid.zone_grid_to_lonlat(grid_x, grid_y, self)
  end

  # Convert zone grid coordinates to world hex
  def zone_grid_to_world_hex(grid_x, grid_y)
    require_relative '../lib/zone_grid'
    ZoneGrid.zone_grid_to_world_hex(grid_x, grid_y, self)
  end

  # Find innermost room at zone grid coordinates
  def innermost_room_at(grid_x, grid_y, grid_z)
    require_relative '../lib/zone_grid'
    ZoneGrid.innermost_room_at(grid_x, grid_y, grid_z, self)
  end

  # ===== CLIMATE METHODS =====

  CLIMATE_TYPES = %w[tropical subtropical temperate subarctic arctic].freeze

  # Calculate climate based on center latitude
  # Can be overridden via zone.climate_override column
  # @return [String] Climate type
  def climate
    override = begin
      self[:climate_override]
    rescue StandardError => e
      warn "[Zone] Failed to read climate_override: #{e.message}"
      nil
    end
    return override if StringHelper.present?(override)

    # Use polygon center if available, otherwise geographic bounds
    center = center_point
    if center
      latitude = center[:y].abs
    elsif has_geographic_bounds?
      latitude = ((min_latitude + max_latitude) / 2.0).abs
    else
      return 'temperate'
    end

    case latitude
    when 0..23.5    then 'tropical'     # Near equator (tropics)
    when 23.5..35   then 'subtropical'  # Sub-tropics
    when 35..55     then 'temperate'    # Mid-latitudes
    when 55..66.5   then 'subarctic'    # High latitudes
    else                 'arctic'       # Polar regions (66.5+)
    end
  end

  # ===== SEASONAL CONTENT METHODS =====

  # Resolve description for a given time/season from this zone's defaults
  # @param time [Symbol] :dawn, :day, :dusk, :night
  # @param season [Symbol] :spring, :summer, :fall, :winter
  # @return [String, nil]
  def resolve_description(time, season)
    resolve_seasonal_content(default_descriptions, time, season) ||
      default_description
  end

  # Resolve background URL for a given time/season from this zone's defaults
  # @param time [Symbol] :dawn, :day, :dusk, :night
  # @param season [Symbol] :spring, :summer, :fall, :winter
  # @return [String, nil]
  def resolve_background(time, season)
    resolve_seasonal_content(default_backgrounds, time, season) ||
      default_background_url
  end

  # Set a default seasonal description for this zone
  def set_default_description!(time, season, desc)
    key = build_seasonal_key(time, season)
    descs = (default_descriptions || {}).to_h.dup
    descs[key] = desc
    update(default_descriptions: Sequel.pg_jsonb_wrap(descs))
  end

  # Set a default seasonal background for this zone
  def set_default_background!(time, season, url)
    key = build_seasonal_key(time, season)
    bgs = (default_backgrounds || {}).to_h.dup
    bgs[key] = url
    update(default_backgrounds: Sequel.pg_jsonb_wrap(bgs))
  end

  # ===== ZONE SUBTYPE METHODS =====

  # Check if a hex's terrain is compatible with this zone's subtype.
  # Uses core/edge terrain classification — core terrains always belong,
  # edge terrains only belong if the hex is near the zone boundary.
  #
  # @param hex [WorldHex] The hex to check
  # @return [Boolean] true if hex terrain fits the zone subtype
  def hex_in_zone?(hex)
    return true if zone_subtype.nil?

    terrain_map = SUBTYPE_TERRAIN_MAP[zone_subtype]
    return true if terrain_map.nil?

    terrain = hex.terrain_type
    return true if terrain_map[:core].include?(terrain)

    if terrain_map[:edge].include?(terrain)
      return edge_hex?(hex)
    end

    false
  end

  # Infer a zone subtype from a zone name using keyword matching.
  # Checks multi-word patterns first (mountain_range) before single-word ones.
  #
  # @param name [String] The zone name to analyze
  # @return [String, nil] Matching subtype or nil
  def self.infer_subtype_from_name(name)
    return nil if name.nil? || name.strip.empty?

    n = name.downcase

    # Check multi-word patterns first (order matters)
    return 'volcano'        if n.match?(/\b(volcano|volcanic|caldera)\b/)
    return 'mountain_range' if n.match?(/\b(mountain range|mountains|sierra|ridge|cordillera)\b/)
    return 'mountain'       if n.match?(/\b(mountain|mount|peak)\b/) || n.match?(/\bmt\b/)
    return 'jungle'         if n.match?(/\b(jungle|rainforest)\b/)
    return 'forest'         if n.match?(/\b(forest|woods?|grove|timberland)\b/)
    return 'swamp'          if n.match?(/\b(swamp|marsh|bog|wetland|fen|mire)\b/)
    return 'lake'           if n.match?(/\b(lake|pond|lagoon|loch)\b/)
    return 'desert'         if n.match?(/\b(desert|dunes?|wasteland|badlands)\b/)

    nil
  end

  private

  # Check if a hex is on the edge of this zone (has at least one neighbor outside)
  # Without a polygon, there's no boundary — treat all hexes as core.
  #
  # @param hex [WorldHex] The hex to check
  # @return [Boolean] true if any neighbor is outside the zone polygon
  def edge_hex?(hex)
    return false unless has_polygon?

    neighbors = WorldHex.neighbors_of(hex)
    return true if neighbors.empty?

    neighbors.any? { |n| !contains_hex?(n.longitude, n.latitude) }
  end

  # (resolve_seasonal_content, build_seasonal_key provided by SeasonalContentCore)
end

# Backward compatibility alias
Area = Zone
