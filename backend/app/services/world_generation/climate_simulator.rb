# frozen_string_literal: true

module WorldGeneration
  # Simulates climate for each hex based on latitude, elevation, and ocean proximity.
  # Calculates temperature using latitude and elevation lapse rate.
  # Calculates moisture using Hadley cell patterns, ocean distance, and rain shadows.
  #
  # @example
  #   grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 5)
  #   config = WorldGeneration::PresetConfig.for(:earth_like)
  #   # ... run elevation generator to set elevations and sea_level ...
  #
  #   climate = WorldGeneration::ClimateSimulator.new(grid, config, sea_level)
  #   climate.simulate
  #
  #   grid.each_hex { |hex| puts "Temp: #{hex.temperature}C, Moisture: #{hex.moisture}" }
  #
  class ClimateSimulator
    # Temperature at equator (0 latitude) in Celsius
    EQUATOR_TEMP = 30.0

    # Temperature at poles (90 degrees latitude) in Celsius
    POLE_TEMP = -30.0

    # Temperature lapse rate: degrees Celsius lost per 1000 meters elevation
    LAPSE_RATE = 6.0

    # Ocean moderating temperature target
    OCEAN_MODERATE_TEMP = 15.0

    # How strongly oceans moderate adjacent land temperatures (0-1)
    OCEAN_TEMP_INFLUENCE = 0.3

    # Maximum distance (in hex steps) for ocean moisture to reach inland
    MAX_OCEAN_MOISTURE_DISTANCE = 20

    # @param grid [GlobeHexGrid] The hex grid with elevation data
    # @param config [Hash] Preset configuration with :temperature_variance, :moisture_modifier
    # @param sea_level [Float] Sea level from ElevationGenerator
    def initialize(grid, config, sea_level)
      @grid = grid
      @config = config
      @sea_level = sea_level
      @ocean_distance_cache = {}
    end

    # Simulate climate for all hexes.
    # Sets temperature and moisture on each hex.
    def simulate
      calculate_ocean_distances
      calculate_temperatures
      calculate_moisture
    end

    private

    # Precompute distance from ocean for each land hex using BFS.
    # Ocean hexes get distance 0.
    def calculate_ocean_distances
      # Identify ocean hexes
      ocean_hexes = []
      @grid.each_hex do |hex|
        if hex.elevation < @sea_level
          @ocean_distance_cache[hex.id] = 0
          ocean_hexes << hex
        end
      end

      # BFS from ocean hexes
      queue = ocean_hexes.map { |hex| [hex, 0] }
      visited = Set.new(ocean_hexes.map(&:id))

      until queue.empty?
        current_hex, distance = queue.shift
        next if distance >= MAX_OCEAN_MOISTURE_DISTANCE

        @grid.neighbors_of(current_hex).each do |neighbor|
          next if visited.include?(neighbor.id)

          visited.add(neighbor.id)
          new_distance = distance + 1
          @ocean_distance_cache[neighbor.id] = new_distance
          queue << [neighbor, new_distance]
        end
      end

      # Any remaining hexes are beyond max distance
      @grid.each_hex do |hex|
        @ocean_distance_cache[hex.id] ||= MAX_OCEAN_MOISTURE_DISTANCE + 1
      end
    end

    # Calculate temperature for each hex based on latitude and elevation.
    def calculate_temperatures
      temperature_variance = @config[:temperature_variance] || 1.0

      @grid.each_hex do |hex|
        # Base temperature from latitude
        # lat is in radians, convert to degrees for calculation
        lat_deg = hex.lat.abs * 180.0 / Math::PI
        lat_factor = lat_deg / 90.0 # 0 at equator, 1 at poles

        base_temp = EQUATOR_TEMP + (POLE_TEMP - EQUATOR_TEMP) * lat_factor

        # Elevation adjustment (lapse rate)
        # Elevation is normalized (-1 to +2 range typically after generation)
        # Convert to meters: assume normalized 0 = sea level, +1 = ~2000m, -0.5 = -1000m
        elevation_meters = (hex.elevation - @sea_level) * 2000.0
        elevation_meters = [elevation_meters, 0.0].max # Only apply lapse rate above sea level
        elevation_adjustment = -(elevation_meters / 1000.0) * LAPSE_RATE

        # Calculate temperature before ocean moderation
        temp = base_temp + elevation_adjustment

        # Apply temperature variance from config
        temp *= temperature_variance

        # Ocean hexes pull toward moderate temperature
        if hex.elevation < @sea_level
          temp = temp * (1.0 - OCEAN_TEMP_INFLUENCE) + OCEAN_MODERATE_TEMP * OCEAN_TEMP_INFLUENCE
        end

        hex.temperature = temp
      end
    end

    # Calculate moisture for each hex using Hadley cells, ocean distance, and rain shadows.
    def calculate_moisture
      moisture_modifier = @config[:moisture_modifier] || 1.0

      @grid.each_hex do |hex|
        moisture = if hex.elevation < @sea_level
          # Ocean hexes have full moisture
          1.0
        else
          calculate_land_moisture(hex)
        end

        # Apply config modifier and clamp
        moisture *= moisture_modifier
        hex.moisture = moisture.clamp(0.0, 1.0)
      end
    end

    # Calculate moisture for a land hex.
    def calculate_land_moisture(hex)
      # Base moisture from Hadley cell latitude bands
      lat_deg = hex.lat.abs * 180.0 / Math::PI
      base_moisture = hadley_cell_moisture(lat_deg)

      # Reduce based on distance from ocean
      ocean_distance = @ocean_distance_cache[hex.id] || MAX_OCEAN_MOISTURE_DISTANCE
      distance_factor = 1.0 - (ocean_distance.to_f / (MAX_OCEAN_MOISTURE_DISTANCE + 1))
      distance_factor = [distance_factor, 0.15].max # Minimum moisture

      moisture = base_moisture * distance_factor

      # Apply rain shadow effect
      rain_shadow_factor = calculate_rain_shadow(hex)
      moisture *= rain_shadow_factor

      moisture
    end

    # Return base moisture based on Hadley cell latitude bands.
    # Models real-world atmospheric circulation patterns.
    #
    # @param lat_deg [Float] Absolute latitude in degrees (0-90)
    # @return [Float] Base moisture (0.0-1.0)
    def hadley_cell_moisture(lat_deg)
      case lat_deg
      when 0...15
        # Tropical/ITCZ - high precipitation
        0.8
      when 15...35
        # Subtropical high pressure - dry (deserts)
        0.35
      when 35...60
        # Temperate/Ferrel cell - moderate moisture
        0.6
      else
        # Polar - cold and dry
        0.4
      end
    end

    # Calculate rain shadow reduction factor.
    # Hexes behind high terrain (relative to ocean) get reduced moisture.
    #
    # @param hex [HexData] The hex to check
    # @return [Float] Factor from 0.3 (deep shadow) to 1.0 (no shadow)
    def calculate_rain_shadow(hex)
      return 1.0 if @ocean_distance_cache[hex.id] == 0

      # Find the direction toward the nearest ocean by checking neighbors
      ocean_direction_hex = nil
      min_ocean_dist = @ocean_distance_cache[hex.id]

      @grid.neighbors_of(hex).each do |neighbor|
        neighbor_dist = @ocean_distance_cache[neighbor.id] || MAX_OCEAN_MOISTURE_DISTANCE
        if neighbor_dist < min_ocean_dist
          min_ocean_dist = neighbor_dist
          ocean_direction_hex = neighbor
        end
      end

      return 1.0 if ocean_direction_hex.nil?

      # Check if there's high terrain between us and ocean
      # If the neighbor toward ocean is higher than us, we're in rain shadow
      if ocean_direction_hex.elevation > hex.elevation + 0.2
        # In rain shadow - reduce moisture significantly
        elevation_diff = ocean_direction_hex.elevation - hex.elevation
        shadow_factor = [1.0 - elevation_diff * 2.0, 0.3].max
        shadow_factor
      else
        1.0
      end
    end
  end
end
