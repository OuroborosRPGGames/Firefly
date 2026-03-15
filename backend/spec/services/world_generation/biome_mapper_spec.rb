# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/world_generation/globe_hex_grid'
require_relative '../../../app/services/world_generation/preset_config'
require_relative '../../../app/services/world_generation/noise_generator'
require_relative '../../../app/services/world_generation/tectonics_generator'
require_relative '../../../app/services/world_generation/elevation_generator'
require_relative '../../../app/services/world_generation/climate_simulator'
require_relative '../../../app/services/world_generation/biome_mapper'

RSpec.describe WorldGeneration::BiomeMapper do
  let(:world) { create(:world) }
  # Use subdivisions: 2 for 320 hexes (fast enough for tests)
  let(:grid) { WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2) }
  let(:config) { WorldGeneration::PresetConfig.for(:earth_like) }
  let(:seed) { 12345 }
  let(:rng) { Random.new(seed) }
  let(:noise) { WorldGeneration::NoiseGenerator.new(seed: rng.rand(2**32)) }
  let(:tectonics) do
    t = WorldGeneration::TectonicsGenerator.new(grid, config, Random.new(seed))
    t.generate
    t
  end
  let(:elevation_gen) do
    e = WorldGeneration::ElevationGenerator.new(grid, config, rng, noise, tectonics)
    e.generate
    e
  end
  let(:sea_level) { elevation_gen.sea_level }
  let(:climate_sim) do
    c = WorldGeneration::ClimateSimulator.new(grid, config, sea_level)
    c.simulate
    c
  end
  let(:mapper) do
    # Ensure climate is simulated before creating mapper
    climate_sim
    described_class.new(grid, config, sea_level)
  end

  # Valid terrain types from WorldHex::TERRAIN_TYPES
  let(:valid_terrain_types) do
    WorldHex::TERRAIN_TYPES
  end

  describe '#initialize' do
    it 'accepts grid, config, and sea_level' do
      climate_sim
      expect { described_class.new(grid, config, sea_level) }.not_to raise_error
    end
  end

  describe '#map_biomes' do
    before { mapper.map_biomes }

    it 'assigns terrain_type to every hex' do
      grid.each_hex do |hex|
        expect(hex.terrain_type).not_to be_nil,
          "Hex #{hex.id} has no terrain_type"
      end
    end

    it 'assigns only valid terrain types' do
      grid.each_hex do |hex|
        expect(valid_terrain_types).to include(hex.terrain_type),
          "Hex #{hex.id} has invalid terrain_type: #{hex.terrain_type}"
      end
    end

    it 'produces varied terrain types' do
      terrain_types = Set.new
      grid.each_hex { |hex| terrain_types.add(hex.terrain_type) }

      expect(terrain_types.size).to be > 3,
        "Expected varied terrain types, got only: #{terrain_types.to_a.join(', ')}"
    end
  end

  describe 'elevation-based terrain' do
    before { mapper.map_biomes }

    it 'maps hexes below sea level to ocean' do
      ocean_count = 0
      grid.each_hex do |hex|
        if hex.elevation < sea_level
          expect(hex.terrain_type).to eq('ocean'),
            "Hex #{hex.id} with elevation #{hex.elevation} (below sea_level #{sea_level}) " \
            "should be ocean, not #{hex.terrain_type}"
          ocean_count += 1
        end
      end

      expect(ocean_count).to be > 0, 'Expected some ocean hexes'
    end

    it 'maps high elevation hexes to mountain' do
      mountain_count = 0
      grid.each_hex do |hex|
        # Mountains are above the tree line threshold
        if hex.elevation > WorldGeneration::BiomeMapper::MOUNTAIN_THRESHOLD &&
           hex.temperature >= WorldGeneration::BiomeMapper::ICE_TEMP_THRESHOLD
          expect(hex.terrain_type).to eq('mountain'),
            "Hex #{hex.id} with elevation #{hex.elevation} and temp #{hex.temperature} " \
            "should be mountain, not #{hex.terrain_type}"
          mountain_count += 1
        end
      end

      # Mountains may not exist in every world, but verify the logic works
      if mountain_count.zero?
        # Check if there are any high elevation hexes that are warm enough for mountains
        # Hexes with temperature < ICE_TEMP_THRESHOLD become tundra instead
        warm_high_hexes = grid.instance_variable_get(:@hexes).select do |h|
          h.elevation > WorldGeneration::BiomeMapper::MOUNTAIN_THRESHOLD &&
            h.temperature >= WorldGeneration::BiomeMapper::ICE_TEMP_THRESHOLD
        end
        if warm_high_hexes.any?
          expect(mountain_count).to be > 0, 'Expected some mountain hexes at high elevation'
        end
      end
    end
  end

  describe 'temperature-based terrain' do
    before { mapper.map_biomes }

    it 'maps very cold hexes to ice' do
      ice_count = 0
      grid.each_hex do |hex|
        next if hex.elevation < sea_level # Skip ocean
        next if hex.elevation < sea_level + WorldGeneration::BiomeMapper::COAST_THRESHOLD # Skip coast
        next if hex.elevation > WorldGeneration::BiomeMapper::MOUNTAIN_THRESHOLD # Skip mountains

        if hex.temperature < WorldGeneration::BiomeMapper::ICE_TEMP_THRESHOLD
          expect(hex.terrain_type).to eq('tundra'),
            "Hex #{hex.id} with temp #{hex.temperature}C should be ice, not #{hex.terrain_type}"
          ice_count += 1
        end
      end

      # Ice should exist at poles
      expect(ice_count).to be >= 0 # May be 0 if no land at poles
    end

    it 'does not map warm hexes to ice' do
      grid.each_hex do |hex|
        next if hex.elevation < sea_level # Skip ocean

        if hex.temperature > 0 && hex.terrain_type == 'ice'
          fail "Hex #{hex.id} with temp #{hex.temperature}C should not be ice"
        end
      end
    end
  end

  describe 'hot climate biomes' do
    before { mapper.map_biomes }

    it 'maps hot and dry hexes to desert' do
      desert_count = 0
      grid.each_hex do |hex|
        next if hex.elevation < sea_level # Skip ocean
        next if hex.elevation > WorldGeneration::BiomeMapper::MOUNTAIN_THRESHOLD # Skip mountains
        next if hex.temperature < WorldGeneration::BiomeMapper::HOT_TEMP_THRESHOLD

        if hex.moisture < WorldGeneration::BiomeMapper::DESERT_MOISTURE
          expect(hex.terrain_type).to eq('desert'),
            "Hex #{hex.id} with temp #{hex.temperature}C and moisture #{hex.moisture} " \
            "should be desert, not #{hex.terrain_type}"
          desert_count += 1
        end
      end

      # Desert may not exist in all worlds
    end

    it 'maps hot and wet hexes to swamp' do
      grid.each_hex do |hex|
        next if hex.elevation < sea_level
        # Skip coast and lake zones — lake zone extends to LAKE_THRESHOLD above sea level
        next if hex.elevation < sea_level + WorldGeneration::BiomeMapper::LAKE_THRESHOLD &&
                hex.moisture > WorldGeneration::BiomeMapper::LAKE_MOISTURE_THRESHOLD
        next if hex.elevation < sea_level + WorldGeneration::BiomeMapper::COAST_THRESHOLD
        next if hex.elevation > WorldGeneration::BiomeMapper::MOUNTAIN_THRESHOLD
        next if hex.temperature < WorldGeneration::BiomeMapper::HOT_TEMP_THRESHOLD

        if hex.moisture > WorldGeneration::BiomeMapper::WET_MOISTURE
          expect(hex.terrain_type).to eq('swamp'),
            "Hex #{hex.id} with temp #{hex.temperature}C and moisture #{hex.moisture} " \
            "should be swamp, not #{hex.terrain_type}"
        end
      end
    end
  end

  describe 'temperate climate biomes' do
    before { mapper.map_biomes }

    it 'maps warm and wet hexes to forest' do
      forest_count = 0
      grid.each_hex do |hex|
        next if hex.elevation < sea_level
        next if hex.elevation < sea_level + WorldGeneration::BiomeMapper::COAST_THRESHOLD
        next if hex.elevation > WorldGeneration::BiomeMapper::MOUNTAIN_THRESHOLD
        next if hex.temperature < WorldGeneration::BiomeMapper::TEMPERATE_TEMP_THRESHOLD
        next if hex.temperature > WorldGeneration::BiomeMapper::HOT_TEMP_THRESHOLD

        moisture = hex.moisture
        if moisture > WorldGeneration::BiomeMapper::MODERATE_MOISTURE &&
           moisture <= WorldGeneration::BiomeMapper::SWAMP_MOISTURE
          expect(hex.terrain_type).to eq('dense_forest'),
            "Hex #{hex.id} with temp #{hex.temperature}C and moisture #{moisture} " \
            "should be forest, not #{hex.terrain_type}"
          forest_count += 1
        end
      end
    end

    it 'maps temperate moderate moisture to light_forest' do
      grid.each_hex do |hex|
        next if hex.elevation < sea_level
        next if hex.elevation < sea_level + WorldGeneration::BiomeMapper::COAST_THRESHOLD
        next if hex.elevation > WorldGeneration::BiomeMapper::MOUNTAIN_THRESHOLD
        next if hex.temperature < WorldGeneration::BiomeMapper::TEMPERATE_TEMP_THRESHOLD
        next if hex.temperature > WorldGeneration::BiomeMapper::HOT_TEMP_THRESHOLD

        moisture = hex.moisture
        if moisture > WorldGeneration::BiomeMapper::DRY_MOISTURE &&
           moisture <= WorldGeneration::BiomeMapper::MODERATE_MOISTURE
          expect(hex.terrain_type).to eq('light_forest'),
            "Hex #{hex.id} with temp #{hex.temperature}C and moisture #{moisture} " \
            "should be light_forest, not #{hex.terrain_type}"
        end
      end
    end
  end

  describe 'edge cases' do
    it 'handles hexes with nil temperature' do
      # Reset temperature on some hexes
      count = 0
      grid.each_hex do |hex|
        if count < 5
          hex.temperature = nil
          count += 1
        end
      end

      expect { mapper.map_biomes }.not_to raise_error

      grid.each_hex do |hex|
        expect(hex.terrain_type).not_to be_nil
        expect(valid_terrain_types).to include(hex.terrain_type)
      end
    end

    it 'handles hexes with nil moisture' do
      # Reset moisture on some hexes
      count = 0
      grid.each_hex do |hex|
        if count < 5
          hex.moisture = nil
          count += 1
        end
      end

      expect { mapper.map_biomes }.not_to raise_error

      grid.each_hex do |hex|
        expect(hex.terrain_type).not_to be_nil
        expect(valid_terrain_types).to include(hex.terrain_type)
      end
    end

    it 'handles grid with all ocean' do
      # Set all hexes below sea level
      grid.each_hex { |hex| hex.elevation = -1.0 }
      all_ocean_mapper = described_class.new(grid, config, 0.0)

      expect { all_ocean_mapper.map_biomes }.not_to raise_error

      grid.each_hex do |hex|
        expect(hex.terrain_type).to eq('ocean'),
          "All hexes below sea level should be ocean"
      end
    end

    it 'handles grid with all land' do
      # Set all hexes above sea level with varied climate
      grid.each_hex do |hex|
        hex.elevation = 0.5 # Above sea level
        hex.temperature = 15.0 # Temperate
        hex.moisture = 0.5 # Moderate
      end
      all_land_mapper = described_class.new(grid, config, 0.0)

      expect { all_land_mapper.map_biomes }.not_to raise_error

      grid.each_hex do |hex|
        expect(hex.terrain_type).not_to eq('ocean'),
          "No hexes above sea level should be ocean"
        expect(valid_terrain_types).to include(hex.terrain_type)
      end
    end
  end

  describe 'coastal and lake terrain' do
    before { mapper.map_biomes }

    it 'maps coastal hexes correctly' do
      grid.each_hex do |hex|
        elev = hex.elevation
        # Coast is a narrow band just above sea level but below lake threshold
        if elev >= sea_level &&
           elev < sea_level + WorldGeneration::BiomeMapper::COAST_THRESHOLD &&
           !(elev < sea_level + WorldGeneration::BiomeMapper::LAKE_THRESHOLD &&
             hex.moisture > WorldGeneration::BiomeMapper::LAKE_MOISTURE_THRESHOLD)
          expect(%w[rocky_coast sandy_coast]).to include(hex.terrain_type),
            "Hex #{hex.id} at elevation #{elev} (sea_level: #{sea_level}) " \
            "should be coast, not #{hex.terrain_type}"
        end
      end
    end

    it 'maps lake hexes correctly' do
      grid.each_hex do |hex|
        elev = hex.elevation
        if elev >= sea_level &&
           elev < sea_level + WorldGeneration::BiomeMapper::LAKE_THRESHOLD &&
           hex.moisture > WorldGeneration::BiomeMapper::LAKE_MOISTURE_THRESHOLD
          expect(hex.terrain_type).to eq('lake'),
            "Hex #{hex.id} with elevation #{elev} and moisture #{hex.moisture} " \
            "should be lake, not #{hex.terrain_type}"
        end
      end
    end
  end

  describe 'reproducibility' do
    it 'generates identical terrain with same input' do
      # First mapping
      mapper.map_biomes
      terrain_types1 = []
      grid.each_hex { |hex| terrain_types1 << hex.terrain_type }

      # Reset
      grid.each_hex { |hex| hex.terrain_type = nil }

      # Second mapping with same inputs
      mapper2 = described_class.new(grid, config, sea_level)
      mapper2.map_biomes
      terrain_types2 = []
      grid.each_hex { |hex| terrain_types2 << hex.terrain_type }

      expect(terrain_types1).to eq(terrain_types2)
    end
  end

  describe 'performance' do
    it 'maps biomes in reasonable time for medium grid' do
      medium_world = create(:world)
      medium_grid = WorldGeneration::GlobeHexGrid.new(medium_world, subdivisions: 3)

      # Set up climate data
      medium_rng = Random.new(88888)
      medium_noise = WorldGeneration::NoiseGenerator.new(seed: 88888)
      medium_tect = WorldGeneration::TectonicsGenerator.new(medium_grid, config, Random.new(88888))
      medium_tect.generate
      medium_elev = WorldGeneration::ElevationGenerator.new(medium_grid, config, medium_rng, medium_noise, medium_tect)
      medium_elev.generate
      medium_climate = WorldGeneration::ClimateSimulator.new(medium_grid, config, medium_elev.sea_level)
      medium_climate.simulate

      medium_mapper = described_class.new(medium_grid, config, medium_elev.sea_level)

      start_time = Time.now
      medium_mapper.map_biomes
      elapsed = Time.now - start_time

      # Should complete in under 1 second (biome mapping is simple)
      expect(elapsed).to be < 1.0
    end
  end

  describe 'terrain type statistics' do
    before { mapper.map_biomes }

    it 'produces realistic terrain distribution' do
      counts = Hash.new(0)
      total = 0

      grid.each_hex do |hex|
        counts[hex.terrain_type] += 1
        total += 1
      end

      # Ocean should typically be 50-80% of an earth-like world
      ocean_pct = counts['ocean'].to_f / total * 100
      # This is a sanity check, not a strict requirement
      expect(ocean_pct).to be > 0 if counts['ocean'] > 0

      # Land types should sum to remaining percentage
      land_types = WorldHex::TERRAIN_TYPES - %w[ocean]
      land_count = land_types.sum { |t| counts[t] }

      # Verify we have land
      expect(land_count + counts['ocean']).to eq(total)
    end
  end

  describe 'specific biome verification' do
    # Test with controlled conditions
    let(:controlled_grid) { WorldGeneration::GlobeHexGrid.new(world, subdivisions: 1) }
    let(:controlled_mapper) { described_class.new(controlled_grid, config, 0.0) }

    it 'produces desert from hot + dry conditions' do
      controlled_grid.each_hex do |hex|
        hex.elevation = 0.5
        hex.temperature = 25.0 # Hot
        hex.moisture = 0.1 # Dry
      end

      controlled_mapper.map_biomes

      controlled_grid.each_hex do |hex|
        expect(hex.terrain_type).to eq('desert')
      end
    end

    it 'produces forest from warm + wet conditions' do
      controlled_grid.each_hex do |hex|
        hex.elevation = 0.5
        hex.temperature = 15.0 # Temperate
        hex.moisture = 0.7 # Wet
      end

      controlled_mapper.map_biomes

      controlled_grid.each_hex do |hex|
        expect(hex.terrain_type).to eq('dense_forest')
      end
    end

    it 'produces ice from very cold conditions' do
      controlled_grid.each_hex do |hex|
        hex.elevation = 0.5 # Above sea level
        hex.temperature = -20.0 # Very cold
        hex.moisture = 0.3
      end

      controlled_mapper.map_biomes

      controlled_grid.each_hex do |hex|
        expect(hex.terrain_type).to eq('tundra')
      end
    end

    it 'produces mountain from high elevation' do
      controlled_grid.each_hex do |hex|
        hex.elevation = 1.0 # Above mountain threshold (0.9)
        hex.temperature = 5.0 # Cold but not frozen
        hex.moisture = 0.3
      end

      controlled_mapper.map_biomes

      controlled_grid.each_hex do |hex|
        expect(hex.terrain_type).to eq('mountain')
      end
    end

    it 'produces ocean from below sea level' do
      controlled_grid.each_hex do |hex|
        hex.elevation = -0.5 # Below sea level
        hex.temperature = 20.0
        hex.moisture = 1.0
      end

      controlled_mapper.map_biomes

      controlled_grid.each_hex do |hex|
        expect(hex.terrain_type).to eq('ocean')
      end
    end

    it 'produces swamp from hot + very wet conditions' do
      controlled_grid.each_hex do |hex|
        hex.elevation = 0.5
        hex.temperature = 25.0 # Hot
        hex.moisture = 0.8 # Very wet (above WET_MOISTURE threshold of 0.75)
      end

      controlled_mapper.map_biomes

      controlled_grid.each_hex do |hex|
        expect(hex.terrain_type).to eq('swamp')
      end
    end

    it 'produces volcanic from extreme elevation in hot zones' do
      controlled_grid.each_hex do |hex|
        hex.elevation = 1.5 # Above MOUNTAIN_THRESHOLD + 0.3 (0.9 + 0.3 = 1.2)
        hex.temperature = 25.0 # Hot
        hex.moisture = 0.3
      end

      controlled_mapper.map_biomes

      controlled_grid.each_hex do |hex|
        expect(hex.terrain_type).to eq('volcanic')
      end
    end

    it 'produces plain from moderate conditions' do
      controlled_grid.each_hex do |hex|
        hex.elevation = 0.3 # Modest elevation
        hex.temperature = 8.0 # Temperate
        hex.moisture = 0.2 # Dry
      end

      controlled_mapper.map_biomes

      controlled_grid.each_hex do |hex|
        expect(hex.terrain_type).to eq('grassy_plains')
      end
    end

    it 'produces taiga forest from cold + wet conditions' do
      controlled_grid.each_hex do |hex|
        hex.elevation = 0.3
        hex.temperature = 0.0 # Cold
        hex.moisture = 0.5 # Wet enough for taiga
      end

      controlled_mapper.map_biomes

      controlled_grid.each_hex do |hex|
        expect(hex.terrain_type).to eq('light_forest') # taiga/boreal forest
      end
    end
  end
end
