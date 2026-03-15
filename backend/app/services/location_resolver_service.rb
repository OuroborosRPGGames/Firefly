# frozen_string_literal: true

# LocationResolverService resolves coordinates to locations for world building
#
# Can either find an existing location near coordinates or create a new one.
# Handles the full hierarchy: World -> Zone -> Location
#
# @example Find or create location for city building
#   result = LocationResolverService.resolve(
#     longitude: -74.0060,
#     latitude: 40.7128,
#     name: 'New York City',
#     location_type: 'building'
#   )
#   location = result[:location]
#
class LocationResolverService
  DEFAULT_WORLD_NAME = 'Default World'
  DEFAULT_ZONE_NAME = 'Generated Zone'

  class << self
    # Resolve coordinates to a location, creating if necessary
    # @param longitude [Float] longitude (-180 to 180)
    # @param latitude [Float] latitude (-90 to 90)
    # @param name [String] name for the new location
    # @param location_type [String] 'building', 'outdoor', etc.
    # @param world [World, nil] optional specific world to use
    # @param options [Hash] additional options
    # @return [Hash] { success:, location:, created:, zone:, error: }
    def resolve(longitude:, latitude:, name:, location_type: 'building', world: nil, options: {})
      # Validate coordinates
      unless valid_coordinates?(longitude, latitude)
        return { success: false, error: 'Invalid coordinates' }
      end

      # Get or create world
      world ||= find_or_create_default_world

      # Find zone containing these coordinates
      zone = find_zone_containing(world, longitude, latitude)

      # If no zone found, create one
      if zone.nil?
        zone = create_zone_for_coordinates(world, longitude, latitude, options)
      end

      # Check for existing location at/near these coordinates
      existing = find_existing_location(zone, longitude, latitude, name)
      if existing
        return { success: true, location: existing, created: false, zone: zone }
      end

      # Create new location
      location = create_location(
        zone: zone,
        name: name,
        longitude: longitude,
        latitude: latitude,
        location_type: location_type,
        options: options
      )

      if location
        { success: true, location: location, created: true, zone: zone }
      else
        { success: false, error: 'Failed to create location' }
      end
    rescue StandardError => e
      { success: false, error: e.message }
    end

    # Find location by coordinates (within tolerance)
    # @param longitude [Float]
    # @param latitude [Float]
    # @param tolerance [Float] degrees of tolerance (default 0.001 ~= 100m)
    # @return [Location, nil]
    def find_by_coordinates(longitude:, latitude:, tolerance: 0.001)
      # First find the zone (database query with bounding box filter)
      zone = Zone.where(
        Sequel.lit(
          'min_longitude <= ? AND max_longitude >= ? AND min_latitude <= ? AND max_latitude >= ?',
          longitude, longitude, latitude, latitude
        )
      ).first
      return nil unless zone

      # Search for locations in that zone with matching coordinates
      # Note: This assumes locations have longitude/latitude fields
      zone.locations_dataset.where(
        Sequel.lit(
          'ABS(COALESCE(longitude, 0) - ?) < ? AND ABS(COALESCE(latitude, 0) - ?) < ?',
          longitude, tolerance, latitude, tolerance
        )
      ).first
    end

    private

    def valid_coordinates?(longitude, latitude)
      longitude.is_a?(Numeric) &&
        latitude.is_a?(Numeric) &&
        longitude >= -180 && longitude <= 180 &&
        latitude >= -90 && latitude <= 90
    end

    def find_or_create_default_world
      World.first || World.create(
        name: DEFAULT_WORLD_NAME,
        description: 'Auto-generated world for content generation'
      )
    end

    def find_zone_containing(world, longitude, latitude)
      # Try polygon containment first, fall back to geographic bounding box
      world.zones.find do |zone|
        if zone.has_polygon?
          zone.contains_point?(longitude, latitude)
        elsif zone.has_geographic_bounds?
          longitude >= zone.min_longitude && longitude <= zone.max_longitude &&
            latitude >= zone.min_latitude && latitude <= zone.max_latitude
        else
          false
        end
      end
    end

    def create_zone_for_coordinates(world, longitude, latitude, options)
      # Create a zone centered on the coordinates with a reasonable size
      # Default to 0.1 degree box (~11km at equator) as a 4-point polygon
      size = options[:zone_size] || 0.1

      Zone.create(
        world_id: world.id,
        name: options[:zone_name] || "#{DEFAULT_ZONE_NAME} (#{longitude.round(2)}, #{latitude.round(2)})",
        zone_type: options[:zone_type] || 'city',
        danger_level: options[:danger_level] || 1,
        min_longitude: longitude - size,
        max_longitude: longitude + size,
        min_latitude: latitude - size,
        max_latitude: latitude + size,
        polygon_points: [
          { 'x' => longitude - size, 'y' => latitude - size },
          { 'x' => longitude + size, 'y' => latitude - size },
          { 'x' => longitude + size, 'y' => latitude + size },
          { 'x' => longitude - size, 'y' => latitude + size }
        ]
      )
    end

    def find_existing_location(zone, longitude, latitude, name)
      # Check by name first
      existing_by_name = zone.locations_dataset.where(name: name).first
      return existing_by_name if existing_by_name

      # Check by coordinates (within ~100m)
      find_by_coordinates(longitude: longitude, latitude: latitude, tolerance: 0.001)
    end

    def create_location(zone:, name:, longitude:, latitude:, location_type:, options:)
      # Calculate globe_hex_id if world has hex grid
      globe_hex_id = calculate_globe_hex_id(zone.world, longitude, latitude)

      Location.create(
        zone_id: zone.id,
        world_id: zone.world_id,
        name: name,
        location_type: location_type,
        longitude: longitude,
        latitude: latitude,
        globe_hex_id: globe_hex_id,
        is_active: true
      )
    rescue Sequel::ValidationFailed => e
      # Handle validation errors gracefully
      nil
    end

    def calculate_globe_hex_id(world, longitude, latitude)
      # Use world's hex grid method if available
      return nil unless world&.respond_to?(:lonlat_to_globe_hex_id)

      world.lonlat_to_globe_hex_id(longitude, latitude)
    rescue StandardError => e
      warn "[LocationResolverService] Failed to calculate globe hex id: #{e.message}"
      nil
    end
  end
end
