# frozen_string_literal: true

module WorldGeneration
  # Maps climate data (temperature, moisture, elevation) to terrain types.
  # Converts continuous climate values into discrete biome classifications.
  #
  # Terrain types follow realistic climate-to-biome rules:
  # - Ocean/water bodies based on elevation and moisture
  # - Temperature-based zones (polar, temperate, tropical)
  # - Moisture gradients within each zone (desert to rainforest)
  # - Elevation effects (mountains, hills)
  #
  # @example
  #   grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 5)
  #   # ... run elevation, climate generators ...
  #
  #   biome = WorldGeneration::BiomeMapper.new(grid, config, sea_level)
  #   biome.map_biomes
  #
  #   grid.each_hex { |hex| puts "Terrain: #{hex.terrain_type}" }
  #
  class BiomeMapper
    # Elevation threshold above sea level for mountains (tree line)
    MOUNTAIN_THRESHOLD = 0.9

    # Elevation threshold for coastal zone (just above sea level)
    COAST_THRESHOLD = 0.1

    # Elevation threshold for inland lakes
    LAKE_THRESHOLD = 0.15

    # Moisture threshold for inland lakes
    LAKE_MOISTURE_THRESHOLD = 0.75

    # Temperature threshold for ice/frozen terrain (Celsius)
    ICE_TEMP_THRESHOLD = -10

    # Temperature threshold for hot/tropical climates (Celsius)
    HOT_TEMP_THRESHOLD = 20

    # Temperature threshold for temperate climates (Celsius)
    TEMPERATE_TEMP_THRESHOLD = 5

    # Moisture thresholds
    DESERT_MOISTURE = 0.2
    DRY_MOISTURE = 0.3
    MODERATE_MOISTURE = 0.4
    WET_MOISTURE = 0.75
    SWAMP_MOISTURE = 0.75
    VERY_WET_MOISTURE = 0.9

    # Elevation thresholds for hills
    TEMPERATE_HILL_ELEVATION = 0.6
    COLD_HILL_ELEVATION = 0.5

    # Cold climate forest (taiga) moisture threshold
    TAIGA_MOISTURE = 0.3

    # @param grid [GlobeHexGrid] The hex grid with elevation, temperature, and moisture data
    # @param config [Hash] Preset configuration (reserved for future biome modifiers)
    # @param sea_level [Float] Sea level from ElevationGenerator
    def initialize(grid, config, sea_level)
      @grid = grid
      @config = config
      @sea_level = sea_level
    end

    # Map biomes for all hexes.
    # Sets terrain_type on each hex based on elevation, temperature, and moisture.
    def map_biomes
      @grid.each_hex do |hex|
        hex.terrain_type = determine_terrain_type(hex)
      end
    end

    private

    # Determine terrain type for a single hex.
    #
    # @param hex [HexData] The hex to classify
    # @return [String] One of WorldHex::TERRAIN_TYPES
    def determine_terrain_type(hex)
      elevation = hex.elevation
      temperature = hex.temperature || 0.0
      moisture = hex.moisture || 0.0

      # Check elevation-based terrain first (order matters!)

      # Ocean: below sea level
      return 'ocean' if elevation < @sea_level

      # Lake: just above sea level but very wet
      return 'lake' if elevation < @sea_level + LAKE_THRESHOLD && moisture > LAKE_MOISTURE_THRESHOLD

      # Coast: narrow band just above sea level
      if elevation < @sea_level + COAST_THRESHOLD
        return moisture > 0.5 ? 'sandy_coast' : 'rocky_coast'
      end

      # Tundra: very cold regions regardless of elevation
      return 'tundra' if temperature < ICE_TEMP_THRESHOLD

      # Volcanic: very high elevation in hot zones (rare)
      if elevation > MOUNTAIN_THRESHOLD + 0.3 && temperature > HOT_TEMP_THRESHOLD
        return 'volcanic'
      end

      # Mountain: above tree line
      return 'mountain' if elevation > MOUNTAIN_THRESHOLD

      # Climate-based biomes for remaining land
      determine_climate_biome(temperature, moisture, elevation)
    end

    # Determine biome based on temperature and moisture.
    #
    # @param temperature [Float] Temperature in Celsius
    # @param moisture [Float] Moisture from 0.0 to 1.0
    # @param elevation [Float] Elevation (normalized)
    # @return [String] Terrain type
    def determine_climate_biome(temperature, moisture, elevation)
      if temperature > HOT_TEMP_THRESHOLD
        # Hot/tropical climate
        hot_climate_biome(moisture)
      elsif temperature > TEMPERATE_TEMP_THRESHOLD
        # Temperate climate
        temperate_climate_biome(moisture, elevation)
      else
        # Cold climate (but not frozen - ice was already checked)
        cold_climate_biome(moisture, elevation)
      end
    end

    # Determine biome for hot/tropical climates.
    #
    # @param moisture [Float] Moisture from 0.0 to 1.0
    # @return [String] Terrain type
    def hot_climate_biome(moisture)
      if moisture < DESERT_MOISTURE
        'desert'
      elsif moisture > WET_MOISTURE
        'swamp'
      elsif moisture > MODERATE_MOISTURE
        'jungle'
      elsif moisture > DRY_MOISTURE
        'grassy_plains'
      else
        'desert'
      end
    end

    # Determine biome for temperate climates.
    #
    # @param moisture [Float] Moisture from 0.0 to 1.0
    # @param elevation [Float] Elevation (normalized)
    # @return [String] Terrain type
    def temperate_climate_biome(moisture, elevation)
      if moisture > SWAMP_MOISTURE
        'swamp'
      elsif moisture > MODERATE_MOISTURE
        'dense_forest'
      elsif moisture > DRY_MOISTURE
        'light_forest'
      elsif elevation > TEMPERATE_HILL_ELEVATION
        'grassy_hills'
      else
        'grassy_plains'
      end
    end

    # Determine biome for cold climates.
    #
    # @param moisture [Float] Moisture from 0.0 to 1.0
    # @param elevation [Float] Elevation (normalized)
    # @return [String] Terrain type
    def cold_climate_biome(moisture, elevation)
      if moisture > TAIGA_MOISTURE
        'light_forest' # taiga/boreal forest
      elsif elevation > COLD_HILL_ELEVATION
        'rocky_hills'
      else
        'rocky_plains' # cold steppe
      end
    end
  end
end
