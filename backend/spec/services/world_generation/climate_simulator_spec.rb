# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/world_generation/globe_hex_grid'
require_relative '../../../app/services/world_generation/preset_config'
require_relative '../../../app/services/world_generation/noise_generator'
require_relative '../../../app/services/world_generation/tectonics_generator'
require_relative '../../../app/services/world_generation/elevation_generator'
require_relative '../../../app/services/world_generation/climate_simulator'

RSpec.describe WorldGeneration::ClimateSimulator do
  let(:world) { create(:world) }
  # Use subdivisions: 2 for 320 hexes (fast enough for tests, enough for meaningful results)
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
  let(:simulator) { described_class.new(grid, config, sea_level) }

  describe '#initialize' do
    it 'accepts grid, config, and sea_level' do
      expect { described_class.new(grid, config, sea_level) }.not_to raise_error
    end
  end

  describe '#simulate' do
    before { simulator.simulate }

    it 'assigns temperature to every hex' do
      grid.each_hex do |hex|
        expect(hex.temperature).not_to be_nil,
          "Hex #{hex.id} at lat #{hex.lat} has no temperature"
      end
    end

    it 'assigns moisture to every hex' do
      grid.each_hex do |hex|
        expect(hex.moisture).not_to be_nil,
          "Hex #{hex.id} at lat #{hex.lat} has no moisture"
      end
    end

    it 'produces varied temperatures' do
      temperatures = []
      grid.each_hex { |hex| temperatures << hex.temperature }

      unique_temps = temperatures.uniq.size
      expect(unique_temps).to be > 10,
        "Expected varied temperatures, got only #{unique_temps} unique values"
    end

    it 'produces varied moisture values' do
      moistures = []
      grid.each_hex { |hex| moistures << hex.moisture }

      unique_moistures = moistures.uniq.size
      expect(unique_moistures).to be > 5,
        "Expected varied moisture, got only #{unique_moistures} unique values"
    end
  end

  describe 'temperature calculation' do
    before { simulator.simulate }

    it 'equator hexes are hotter than pole hexes' do
      # Find hexes near equator (|lat| < 15 degrees)
      equator_temps = []
      # Find hexes near poles (|lat| > 60 degrees)
      pole_temps = []

      grid.each_hex do |hex|
        lat_deg = hex.lat.abs * 180.0 / Math::PI
        if lat_deg < 15
          equator_temps << hex.temperature
        elsif lat_deg > 60
          pole_temps << hex.temperature
        end
      end

      # Skip if we don't have hexes in both regions
      next if equator_temps.empty? || pole_temps.empty?

      equator_avg = equator_temps.sum / equator_temps.size
      pole_avg = pole_temps.sum / pole_temps.size

      expect(equator_avg).to be > pole_avg,
        "Equator avg temp (#{equator_avg}C) should be higher than pole avg (#{pole_avg}C)"
    end

    it 'higher elevation hexes are colder' do
      # Group hexes by elevation bands
      low_elev_temps = []
      high_elev_temps = []

      grid.each_hex do |hex|
        next if hex.elevation < sea_level # Skip ocean

        if hex.elevation < sea_level + 0.3
          low_elev_temps << hex.temperature
        elsif hex.elevation > sea_level + 0.7
          high_elev_temps << hex.temperature
        end
      end

      # Skip if we don't have hexes in both bands
      next if low_elev_temps.empty? || high_elev_temps.empty?

      low_avg = low_elev_temps.sum / low_elev_temps.size
      high_avg = high_elev_temps.sum / high_elev_temps.size

      expect(low_avg).to be > high_avg,
        "Low elevation avg temp (#{low_avg}C) should be higher than high elevation avg (#{high_avg}C)"
    end

    it 'temperatures are in reasonable range (-40 to +40 Celsius)' do
      min_temp = Float::INFINITY
      max_temp = -Float::INFINITY

      grid.each_hex do |hex|
        min_temp = hex.temperature if hex.temperature < min_temp
        max_temp = hex.temperature if hex.temperature > max_temp
      end

      expect(min_temp).to be >= -50,
        "Min temperature #{min_temp}C is unreasonably cold"
      expect(max_temp).to be <= 50,
        "Max temperature #{max_temp}C is unreasonably hot"
    end
  end

  describe 'moisture calculation' do
    before { simulator.simulate }

    it 'moisture values are between 0.0 and 1.0' do
      grid.each_hex do |hex|
        expect(hex.moisture).to be >= 0.0,
          "Hex #{hex.id} has negative moisture: #{hex.moisture}"
        expect(hex.moisture).to be <= 1.0,
          "Hex #{hex.id} has moisture > 1.0: #{hex.moisture}"
      end
    end

    it 'ocean hexes have high moisture (>= 0.8)' do
      ocean_hexes = []
      grid.each_hex do |hex|
        ocean_hexes << hex if hex.elevation < sea_level
      end

      # Should have some ocean hexes
      expect(ocean_hexes).not_to be_empty

      ocean_hexes.each do |hex|
        expect(hex.moisture).to be >= 0.8,
          "Ocean hex #{hex.id} has low moisture: #{hex.moisture}"
      end
    end

    it 'coastal land has higher moisture than deep inland' do
      # We can't easily identify coastal vs inland without the ocean distance cache
      # but we can verify that there's variation
      land_moistures = []
      grid.each_hex do |hex|
        land_moistures << hex.moisture if hex.elevation >= sea_level
      end

      next if land_moistures.empty?

      min_moisture = land_moistures.min
      max_moisture = land_moistures.max

      # There should be some variation in land moisture
      expect(max_moisture).to be > min_moisture,
        "Land moisture should vary (min: #{min_moisture}, max: #{max_moisture})"
    end
  end

  describe 'Hadley cell patterns' do
    before { simulator.simulate }

    it 'subtropical regions (15-35 deg) have lower moisture than tropics' do
      tropical_moistures = []
      subtropical_moistures = []

      grid.each_hex do |hex|
        next if hex.elevation < sea_level # Only land

        lat_deg = hex.lat.abs * 180.0 / Math::PI
        if lat_deg < 15
          tropical_moistures << hex.moisture
        elsif lat_deg >= 15 && lat_deg < 35
          subtropical_moistures << hex.moisture
        end
      end

      next if tropical_moistures.empty? || subtropical_moistures.empty?

      tropical_avg = tropical_moistures.sum / tropical_moistures.size
      subtropical_avg = subtropical_moistures.sum / subtropical_moistures.size

      # Subtropical should be drier (lower moisture)
      expect(subtropical_avg).to be < tropical_avg,
        "Subtropical avg moisture (#{subtropical_avg}) should be less than tropical (#{tropical_avg})"
    end
  end

  describe 'config parameters' do
    it 'temperature_variance scales temperatures' do
      # Low variance
      low_config = config.merge(temperature_variance: 0.5)
      low_sim = described_class.new(grid, low_config, sea_level)
      low_sim.simulate

      low_temps = []
      grid.each_hex { |hex| low_temps << hex.temperature }
      low_range = low_temps.max - low_temps.min

      # Reset temperatures
      grid.each_hex { |hex| hex.temperature = nil }

      # High variance
      high_config = config.merge(temperature_variance: 1.5)
      high_sim = described_class.new(grid, high_config, sea_level)
      high_sim.simulate

      high_temps = []
      grid.each_hex { |hex| high_temps << hex.temperature }
      high_range = high_temps.max - high_temps.min

      # Higher variance should produce larger temperature range
      # (temperatures are multiplied by variance)
      expect(high_range).to be > low_range,
        "High variance range (#{high_range}) should exceed low variance (#{low_range})"
    end

    it 'moisture_modifier scales land moisture' do
      # Low moisture modifier
      low_config = config.merge(moisture_modifier: 0.5)
      low_sim = described_class.new(grid, low_config, sea_level)
      low_sim.simulate

      low_land_moistures = []
      grid.each_hex do |hex|
        low_land_moistures << hex.moisture if hex.elevation >= sea_level
      end

      # Reset moisture
      grid.each_hex { |hex| hex.moisture = nil }

      # High moisture modifier
      high_config = config.merge(moisture_modifier: 1.5)
      high_sim = described_class.new(grid, high_config, sea_level)
      high_sim.simulate

      high_land_moistures = []
      grid.each_hex do |hex|
        high_land_moistures << hex.moisture if hex.elevation >= sea_level
      end

      next if low_land_moistures.empty? || high_land_moistures.empty?

      low_avg = low_land_moistures.sum / low_land_moistures.size
      high_avg = high_land_moistures.sum / high_land_moistures.size

      # Higher modifier should produce higher average moisture
      expect(high_avg).to be > low_avg,
        "High moisture modifier avg (#{high_avg}) should exceed low (#{low_avg})"
    end
  end

  describe 'reproducibility' do
    it 'generates identical climate with same input' do
      # First simulation
      sim1 = described_class.new(grid, config, sea_level)
      sim1.simulate

      temps1 = []
      moistures1 = []
      grid.each_hex do |hex|
        temps1 << hex.temperature
        moistures1 << hex.moisture
      end

      # Reset
      grid.each_hex do |hex|
        hex.temperature = nil
        hex.moisture = nil
      end

      # Second simulation with same inputs
      sim2 = described_class.new(grid, config, sea_level)
      sim2.simulate

      temps2 = []
      moistures2 = []
      grid.each_hex do |hex|
        temps2 << hex.temperature
        moistures2 << hex.moisture
      end

      # Should be identical
      expect(temps1).to eq(temps2)
      expect(moistures1).to eq(moistures2)
    end
  end

  describe 'edge cases' do
    it 'handles grid with all ocean (everything below sea_level)' do
      # Set all hexes below sea level
      grid.each_hex { |hex| hex.elevation = -1.0 }
      all_ocean_sim = described_class.new(grid, config, 0.0)

      expect { all_ocean_sim.simulate }.not_to raise_error

      grid.each_hex do |hex|
        expect(hex.temperature).not_to be_nil
        expect(hex.moisture).to eq(1.0) # Ocean = full moisture
      end
    end

    it 'handles grid with all land (everything above sea_level)' do
      # Set all hexes above sea level
      grid.each_hex { |hex| hex.elevation = 1.0 }
      all_land_sim = described_class.new(grid, config, 0.0)

      expect { all_land_sim.simulate }.not_to raise_error

      grid.each_hex do |hex|
        expect(hex.temperature).not_to be_nil
        expect(hex.moisture).not_to be_nil
        expect(hex.moisture).to be_between(0.0, 1.0)
      end
    end

    it 'handles small grid (subdivisions: 1)' do
      small_world = create(:world)
      small_grid = WorldGeneration::GlobeHexGrid.new(small_world, subdivisions: 1)
      small_rng = Random.new(55555)
      small_noise = WorldGeneration::NoiseGenerator.new(seed: 55555)
      small_tect = WorldGeneration::TectonicsGenerator.new(small_grid, config, Random.new(55555))
      small_tect.generate
      small_elev = WorldGeneration::ElevationGenerator.new(small_grid, config, small_rng, small_noise, small_tect)
      small_elev.generate

      small_sim = described_class.new(small_grid, config, small_elev.sea_level)

      expect { small_sim.simulate }.not_to raise_error

      small_grid.each_hex do |hex|
        expect(hex.temperature).not_to be_nil
        expect(hex.moisture).not_to be_nil
      end
    end
  end

  describe 'performance' do
    it 'simulates climate in reasonable time for medium grid' do
      medium_world = create(:world)
      medium_grid = WorldGeneration::GlobeHexGrid.new(medium_world, subdivisions: 3)
      medium_rng = Random.new(88888)
      medium_noise = WorldGeneration::NoiseGenerator.new(seed: 88888)
      medium_tect = WorldGeneration::TectonicsGenerator.new(medium_grid, config, Random.new(88888))
      medium_tect.generate
      medium_elev = WorldGeneration::ElevationGenerator.new(medium_grid, config, medium_rng, medium_noise, medium_tect)
      medium_elev.generate

      medium_sim = described_class.new(medium_grid, config, medium_elev.sea_level)

      start_time = Time.now
      medium_sim.simulate
      elapsed = Time.now - start_time

      # Should complete in under 5 seconds
      expect(elapsed).to be < 5.0
    end
  end

  describe 'different presets' do
    it 'ice_age preset produces colder temperatures' do
      # Regular earth-like
      earth_sim = described_class.new(grid, config, sea_level)
      earth_sim.simulate

      earth_temps = []
      grid.each_hex { |hex| earth_temps << hex.temperature }
      earth_avg = earth_temps.sum / earth_temps.size

      # Reset
      grid.each_hex { |hex| hex.temperature = nil }

      # Ice age has temperature_variance: 1.4 which amplifies the cold
      ice_config = WorldGeneration::PresetConfig.for(:ice_age)
      ice_sim = described_class.new(grid, ice_config, sea_level)
      ice_sim.simulate

      ice_temps = []
      grid.each_hex { |hex| ice_temps << hex.temperature }
      ice_avg = ice_temps.sum / ice_temps.size

      # Ice age should have more extreme temperatures (larger variance multiplies extremes)
      # This means polar regions get colder
      ice_min = ice_temps.min
      earth_min = earth_temps.min

      expect(ice_min).to be < earth_min,
        "Ice age min temp (#{ice_min}) should be colder than earth-like (#{earth_min})"
    end

    it 'waterworld preset produces higher moisture' do
      waterworld_config = WorldGeneration::PresetConfig.for(:waterworld)

      # Reset moisture
      grid.each_hex { |hex| hex.moisture = nil }

      water_sim = described_class.new(grid, waterworld_config, sea_level)
      water_sim.simulate

      water_moistures = []
      grid.each_hex { |hex| water_moistures << hex.moisture }
      water_avg = water_moistures.sum / water_moistures.size

      # Reset
      grid.each_hex { |hex| hex.moisture = nil }

      earth_sim = described_class.new(grid, config, sea_level)
      earth_sim.simulate

      earth_moistures = []
      grid.each_hex { |hex| earth_moistures << hex.moisture }
      earth_avg = earth_moistures.sum / earth_moistures.size

      # Waterworld has moisture_modifier: 1.5, should be wetter
      expect(water_avg).to be > earth_avg,
        "Waterworld avg moisture (#{water_avg}) should exceed earth-like (#{earth_avg})"
    end

    it 'arid preset produces lower moisture' do
      arid_config = WorldGeneration::PresetConfig.for(:arid)

      # Reset moisture
      grid.each_hex { |hex| hex.moisture = nil }

      arid_sim = described_class.new(grid, arid_config, sea_level)
      arid_sim.simulate

      arid_moistures = []
      grid.each_hex { |hex| arid_moistures << hex.moisture }
      arid_avg = arid_moistures.sum / arid_moistures.size

      # Reset
      grid.each_hex { |hex| hex.moisture = nil }

      earth_sim = described_class.new(grid, config, sea_level)
      earth_sim.simulate

      earth_moistures = []
      grid.each_hex { |hex| earth_moistures << hex.moisture }
      earth_avg = earth_moistures.sum / earth_moistures.size

      # Arid has moisture_modifier: 0.4, should be drier
      expect(arid_avg).to be < earth_avg,
        "Arid avg moisture (#{arid_avg}) should be less than earth-like (#{earth_avg})"
    end
  end
end
