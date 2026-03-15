# frozen_string_literal: true

module ZoneGrid
  # Each 2 distance units = 1 meter in zone grid
  DISTANCE_UNITS_PER_METER = 2.0
  METERS_PER_DISTANCE_UNIT = 1.0 / DISTANCE_UNITS_PER_METER

  # Convert longitude/latitude to zone grid coordinates within a zone
  # Returns [grid_x, grid_y, zone] or nil if coordinates are not within any zone of this world
  def self.lonlat_to_zone_grid(longitude, latitude, world)
    # Find the zone that contains this longitude/latitude
    zone = world.zones.find { |z| z.contains_point?(longitude, latitude) }
    return nil unless zone

    # Calculate the position within the zone's bounding box
    bb = zone.bounding_box
    return nil unless bb

    zone_width = bb[:max_x] - bb[:min_x]
    zone_height = bb[:max_y] - bb[:min_y]

    # For polygon zones using lon/lat as x/y, we convert to meters
    # At the equator, 1 degree longitude ≈ 111,320 meters
    # Latitude degrees are always ≈ 111,320 meters
    meters_per_degree_latitude = 111_320.0
    meters_per_degree_longitude = 111_320.0 * Math.cos(latitude * Math::PI / 180.0)

    zone_width_meters = zone_width * meters_per_degree_longitude
    zone_height_meters = zone_height * meters_per_degree_latitude

    # Calculate position within the zone (0.0 to 1.0)
    relative_x = (longitude - bb[:min_x]) / zone_width
    relative_y = (latitude - bb[:min_y]) / zone_height

    # Convert to zone grid coordinates (in distance units, where 2 units = 1 meter)
    grid_x = (relative_x * zone_width_meters * DISTANCE_UNITS_PER_METER).round
    grid_y = (relative_y * zone_height_meters * DISTANCE_UNITS_PER_METER).round

    [grid_x, grid_y, zone]
  end

  # Convert zone grid coordinates to longitude/latitude
  def self.zone_grid_to_lonlat(grid_x, grid_y, zone)
    bb = zone&.bounding_box
    return nil unless bb

    zone_width = bb[:max_x] - bb[:min_x]
    zone_height = bb[:max_y] - bb[:min_y]

    # Calculate approximate center latitude for longitude scaling
    center_y = (bb[:min_y] + bb[:max_y]) / 2.0

    # Convert degrees to meters at this latitude
    meters_per_degree_latitude = 111_320.0
    meters_per_degree_longitude = 111_320.0 * Math.cos(center_y * Math::PI / 180.0)

    zone_width_meters = zone_width * meters_per_degree_longitude
    zone_height_meters = zone_height * meters_per_degree_latitude

    # Convert grid coordinates to meters
    position_x_meters = grid_x * METERS_PER_DISTANCE_UNIT
    position_y_meters = grid_y * METERS_PER_DISTANCE_UNIT

    # Convert to relative position within zone (0.0 to 1.0)
    relative_x = position_x_meters / zone_width_meters
    relative_y = position_y_meters / zone_height_meters

    # Convert to longitude/latitude
    longitude = bb[:min_x] + (relative_x * zone_width)
    latitude = bb[:min_y] + (relative_y * zone_height)

    [longitude, latitude]
  end

  # Get the world hex for a given zone grid position
  # Returns the WorldHex record at the lat/lon position, or nil if not found
  def self.zone_grid_to_world_hex(grid_x, grid_y, zone)
    lonlat = zone_grid_to_lonlat(grid_x, grid_y, zone)
    return nil unless lonlat

    world = zone.world
    return nil unless world

    # Use the globe system to find nearest hex by lat/lon
    WorldHex.find_nearest_by_latlon(world.id, lonlat[1], lonlat[0])
  end

  # Convert world hex to zone grid coordinates (if the hex is within a zone)
  # @param world_hex [WorldHex] the world hex record
  # @param world [World] the world object
  # @return [Array, nil] [grid_x, grid_y, zone] or nil if not within a zone
  def self.world_hex_to_zone_grid(world_hex, world)
    return nil unless world_hex && world_hex.latitude && world_hex.longitude

    lonlat_to_zone_grid(world_hex.longitude, world_hex.latitude, world)
  end

  # Find the innermost room at given zone grid coordinates
  def self.innermost_room_at(grid_x, grid_y, grid_z, zone)
    return nil unless zone

    # Get all locations in this zone
    candidate_rooms = []

    zone.locations.each do |location|
      location.rooms.each do |room|
        candidate_rooms << room if room_contains_point?(room, grid_x, grid_y, grid_z)
      end
    end

    return nil if candidate_rooms.empty?

    # Find the innermost room (smallest volume that contains the point)
    candidate_rooms.min_by do |room|
      volume = room_volume(room)
      # If volume is 0 or nil, treat as infinitely large (shouldn't happen but safety)
      volume && volume.positive? ? volume : Float::INFINITY
    end
  end

  # Check if room contains a point in zone grid coordinates
  def self.room_contains_point?(room, grid_x, grid_y, grid_z)
    return false unless room.min_x && room.max_x && room.min_y && room.max_y

    # Check X and Y bounds
    x_in_bounds = grid_x >= room.min_x && grid_x <= room.max_x
    y_in_bounds = grid_y >= room.min_y && grid_y <= room.max_y

    # Check Z bounds if they exist
    z_in_bounds = true
    if room.min_z && room.max_z
      z_in_bounds = grid_z >= room.min_z && grid_z <= room.max_z
    end

    x_in_bounds && y_in_bounds && z_in_bounds
  end

  # Calculate room volume for finding innermost room
  def self.room_volume(room)
    return nil unless room.min_x && room.max_x && room.min_y && room.max_y

    width = room.max_x - room.min_x
    height = room.max_y - room.min_y
    depth = 1.0 # Default depth

    if room.min_z && room.max_z
      depth = room.max_z - room.min_z
    end

    width * height * depth
  end

  # Convert meters to zone grid distance units
  def self.meters_to_grid_units(meters)
    meters * DISTANCE_UNITS_PER_METER
  end

  # Convert zone grid distance units to meters
  def self.grid_units_to_meters(units)
    units * METERS_PER_DISTANCE_UNIT
  end
end
