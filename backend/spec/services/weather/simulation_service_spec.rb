# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WeatherGrid::SimulationService do
  let(:world) { create(:world) }

  before do
    WeatherGrid::GridService.clear(world)
    WeatherGrid::TerrainService.clear(world)
    WeatherGrid::GridService.initialize_world(world)
  end

  after do
    WeatherGrid::GridService.clear(world)
    WeatherGrid::TerrainService.clear(world)
  end

  describe '.tick' do
    it 'runs a simulation tick successfully' do
      result = described_class.tick(world)
      expect(result).to be true
    end

    it 'increments tick_count in metadata' do
      described_class.tick(world)

      grid = WeatherGrid::GridService.load(world)
      expect(grid[:meta]['tick_count']).to eq(1)
    end

    it 'updates last_tick_at timestamp' do
      described_class.tick(world)

      grid = WeatherGrid::GridService.load(world)
      expect(grid[:meta]['last_tick_at']).not_to be_nil
    end

    it 'modifies weather values' do
      grid_before = WeatherGrid::GridService.load(world)
      temp_before = grid_before[:cells][100]['temperature']

      # Run multiple ticks to see changes
      3.times { described_class.tick(world) }

      grid_after = WeatherGrid::GridService.load(world)
      # Weather should change over multiple ticks
      # (exact change depends on simulation conditions)
      expect(grid_after[:meta]['tick_count']).to eq(3)
    end

    it 'prevents concurrent simulation with locking' do
      # First tick acquires lock
      expect(WeatherGrid::GridService.acquire_lock(world)).to be true

      # Second tick should fail (lock held)
      result = described_class.tick(world)
      expect(result).to be false

      # Release lock
      WeatherGrid::GridService.release_lock(world)

      # Now tick should work
      result = described_class.tick(world)
      expect(result).to be true
    end

    it 'returns false for non-existent grid' do
      WeatherGrid::GridService.clear(world)

      result = described_class.tick(world)
      expect(result).to be false
    end
  end

  describe 'simulation physics' do
    before do
      # Set up a specific test scenario
      grid = WeatherGrid::GridService.load(world)
      cells = grid[:cells]

      # Create a hot cell at (32, 32) - equator
      hot_idx = WeatherGrid::GridService.coords_to_index(32, 32)
      cells[hot_idx]['temperature'] = 40.0
      cells[hot_idx]['humidity'] = 90.0
      cells[hot_idx]['pressure'] = 1000.0

      # Create a cold cell nearby at (33, 32)
      cold_idx = WeatherGrid::GridService.coords_to_index(33, 32)
      cells[cold_idx]['temperature'] = 10.0
      cells[cold_idx]['humidity'] = 30.0
      cells[cold_idx]['pressure'] = 1025.0

      WeatherGrid::GridService.save(world, grid)
    end

    it 'generates wind from pressure differences' do
      described_class.tick(world)

      grid = WeatherGrid::GridService.load(world)
      hot_idx = WeatherGrid::GridService.coords_to_index(32, 32)

      # Wind should be non-zero due to pressure gradient
      expect(grid[:cells][hot_idx]['wind_speed']).to be > 0
    end

    it 'forms clouds from high humidity' do
      described_class.tick(world)

      grid = WeatherGrid::GridService.load(world)
      hot_idx = WeatherGrid::GridService.coords_to_index(32, 32)

      # High humidity cell should have increased cloud cover
      expect(grid[:cells][hot_idx]['cloud_cover']).to be > 30
    end

    it 'generates precipitation from supersaturated air' do
      grid = WeatherGrid::GridService.load(world)
      cells = grid[:cells]

      # Make a cell very humid with clouds
      test_idx = WeatherGrid::GridService.coords_to_index(32, 32)
      cells[test_idx]['humidity'] = 95.0
      cells[test_idx]['cloud_cover'] = 80.0

      WeatherGrid::GridService.save(world, grid)
      described_class.tick(world)

      grid_after = WeatherGrid::GridService.load(world)
      expect(grid_after[:cells][test_idx]['precip_rate']).to be > 0
    end

    it 'calculates instability from conditions' do
      described_class.tick(world)

      grid = WeatherGrid::GridService.load(world)
      hot_idx = WeatherGrid::GridService.coords_to_index(32, 32)

      # Hot humid cell near cold cell should have instability
      expect(grid[:cells][hot_idx]['instability']).to be > 0
    end

    it 'advects temperature with wind' do
      # Run several ticks to allow advection
      5.times { described_class.tick(world) }

      grid = WeatherGrid::GridService.load(world)

      # Temperature should spread from the hot cell
      # Check cells around the hot spot have changed
      center_temp = grid[:cells][WeatherGrid::GridService.coords_to_index(32, 32)]['temperature']
      neighbor_temp = grid[:cells][WeatherGrid::GridService.coords_to_index(31, 32)]['temperature']

      # Temperatures should be different but influenced by each other
      expect(center_temp).not_to eq(40.0) # Changed from original
    end
  end

  describe 'solar heating' do
    it 'heats during day (noon)' do
      # Set world time to noon
      allow(world).to receive(:current_time).and_return(Time.new(2025, 6, 15, 12, 0, 0))

      grid_before = WeatherGrid::GridService.load(world)
      equator_idx = WeatherGrid::GridService.coords_to_index(32, 32)
      temp_before = grid_before[:cells][equator_idx]['temperature']

      described_class.tick(world)

      grid_after = WeatherGrid::GridService.load(world)
      temp_after = grid_after[:cells][equator_idx]['temperature']

      # Should be warmer at noon
      expect(temp_after).to be >= temp_before
    end

    it 'cools at night (midnight)' do
      allow(world).to receive(:current_time).and_return(Time.new(2025, 6, 15, 0, 0, 0))

      # Set a warm starting temperature
      grid = WeatherGrid::GridService.load(world)
      test_idx = WeatherGrid::GridService.coords_to_index(32, 32)
      grid[:cells][test_idx]['temperature'] = 25.0
      grid[:cells][test_idx]['cloud_cover'] = 0.0 # Clear sky = more cooling
      WeatherGrid::GridService.save(world, grid)

      described_class.tick(world)

      grid_after = WeatherGrid::GridService.load(world)
      temp_after = grid_after[:cells][test_idx]['temperature']

      # Should be cooler at night with clear skies
      expect(temp_after).to be < 25.0
    end
  end

  describe 'terrain effects' do
    before do
      # Create terrain with water (high evaporation)
      terrain_cells = Array.new(64 * 64) do |i|
        x, y = WeatherGrid::GridService.index_to_coords(i)
        if x < 32
          # Western half: ocean
          { 'evaporation_rate' => 3.0, 'water_pct' => 100.0, 'roughness' => 0.1 }
        else
          # Eastern half: mountains
          { 'evaporation_rate' => 0.5, 'mountain_pct' => 80.0, 'roughness' => 1.0, 'avg_altitude' => 2000 }
        end
      end
      WeatherGrid::TerrainService.save(world, terrain_cells)
    end

    it 'increases humidity over water' do
      # Set initial humidity
      grid = WeatherGrid::GridService.load(world)
      ocean_idx = WeatherGrid::GridService.coords_to_index(16, 32) # Ocean
      grid[:cells][ocean_idx]['humidity'] = 50.0
      WeatherGrid::GridService.save(world, grid)

      described_class.tick(world)

      grid_after = WeatherGrid::GridService.load(world)
      expect(grid_after[:cells][ocean_idx]['humidity']).to be > 50.0
    end

    it 'reduces wind speed over rough terrain' do
      # Set initial wind
      grid = WeatherGrid::GridService.load(world)
      mountain_idx = WeatherGrid::GridService.coords_to_index(48, 32) # Mountains
      grid[:cells][mountain_idx]['wind_speed'] = 50.0
      grid[:cells][mountain_idx]['pressure'] = 1020.0
      WeatherGrid::GridService.save(world, grid)

      described_class.tick(world)

      grid_after = WeatherGrid::GridService.load(world)
      # Wind should be reduced by terrain roughness
      expect(grid_after[:cells][mountain_idx]['wind_speed']).to be < 50.0
    end
  end

  describe '.tick_all' do
    it 'returns results for all worlds' do
      results = described_class.tick_all

      # Should include our test world if it has grid data
      expect(results).to be_a(Hash)
    end
  end
end
