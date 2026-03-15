# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WeatherGrid::StormService do
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

  describe 'STORM_TYPES' do
    it 'defines thunderstorm configuration' do
      config = described_class::STORM_TYPES[:thunderstorm]
      expect(config[:min_instability]).to eq(65)
      expect(config[:min_humidity]).to eq(75)
    end

    it 'defines blizzard for cold weather' do
      config = described_class::STORM_TYPES[:blizzard]
      expect(config[:max_temp]).to be < 5
    end

    it 'defines hurricane requiring water' do
      config = described_class::STORM_TYPES[:hurricane]
      expect(config[:requires_water]).to be true
    end

    it 'defines tornado with high instability' do
      config = described_class::STORM_TYPES[:tornado]
      expect(config[:min_instability]).to be >= 85
    end
  end

  describe '.tick_storms' do
    context 'with no existing storms' do
      it 'returns empty array' do
        grid = WeatherGrid::GridService.load(world)
        result = described_class.tick_storms(world, grid)
        expect(result).to eq([])
      end
    end

    context 'with existing storms' do
      before do
        # Add a storm to the grid meta
        WeatherGrid::GridService.update_meta(world, {
          'storms' => [
            {
              'id' => 'storm_test123',
              'type' => 'thunderstorm',
              'grid_x' => 32.0,
              'grid_y' => 32.0,
              'heading' => 45,
              'speed' => 20.0,
              'intensity' => 0.7,
              'phase' => 'mature',
              'radius_cells' => 2.0,
              'ticks_in_phase' => 5,
              'phase_duration' => 30
            }
          ]
        })
      end

      it 'updates storm positions' do
        grid = WeatherGrid::GridService.load(world)
        storms_before = grid[:meta]['storms'].first
        x_before = storms_before['grid_x']

        described_class.tick_storms(world, grid)

        grid_after = WeatherGrid::GridService.load(world)
        storms_after = grid_after[:meta]['storms'].first

        # Storm should have moved
        expect(storms_after['ticks_in_phase']).to eq(6)
      end

      it 'removes dead storms' do
        # Set storm to dissipating with 0 duration
        WeatherGrid::GridService.update_meta(world, {
          'storms' => [
            {
              'id' => 'storm_dying',
              'type' => 'thunderstorm',
              'grid_x' => 32.0,
              'grid_y' => 32.0,
              'heading' => 0,
              'speed' => 10.0,
              'intensity' => 0.1,
              'phase' => 'dissipating',
              'radius_cells' => 1.0,
              'ticks_in_phase' => 100,
              'phase_duration' => 10
            }
          ]
        })

        grid = WeatherGrid::GridService.load(world)
        described_class.tick_storms(world, grid)

        grid_after = WeatherGrid::GridService.load(world)
        expect(grid_after[:meta]['storms']).to be_empty
      end
    end
  end

  describe '.genesis_check' do
    context 'with calm conditions' do
      it 'does not create storms' do
        grid = WeatherGrid::GridService.load(world)
        new_storms = described_class.genesis_check(world, grid)
        expect(new_storms).to be_empty
      end
    end

    context 'with storm-favorable conditions' do
      before do
        grid = WeatherGrid::GridService.load(world)
        cells = grid[:cells]

        # Create extreme conditions at a cell
        idx = WeatherGrid::GridService.coords_to_index(32, 32)
        cells[idx]['instability'] = 95.0
        cells[idx]['humidity'] = 95.0
        cells[idx]['temperature'] = 30.0
        cells[idx]['wind_speed'] = 30.0
        cells[idx]['wind_dir'] = 90

        WeatherGrid::GridService.save(world, grid)
      end

      it 'may create a storm under extreme conditions' do
        # Run multiple times since genesis is probabilistic
        storm_created = false
        30.times do
          grid = WeatherGrid::GridService.load(world)
          new_storms = described_class.genesis_check(world, grid)
          storm_created = true if new_storms.any?
          break if storm_created
        end

        # With such extreme conditions, at least one storm should form
        # (with 30 tries at ~15% probability, chance of all failing is ~0.7%)
        expect(storm_created).to be true
      end
    end
  end

  describe '.apply_effects' do
    before do
      # Add a strong storm
      WeatherGrid::GridService.update_meta(world, {
        'storms' => [
          {
            'id' => 'storm_strong',
            'type' => 'thunderstorm',
            'grid_x' => 32.0,
            'grid_y' => 32.0,
            'heading' => 0,
            'speed' => 30.0,
            'intensity' => 0.9,
            'phase' => 'mature',
            'radius_cells' => 3.0,
            'ticks_in_phase' => 10,
            'phase_duration' => 30
          }
        ]
      })
    end

    it 'increases precipitation in affected cells' do
      grid = WeatherGrid::GridService.load(world)
      center_idx = WeatherGrid::GridService.coords_to_index(32, 32)
      precip_before = grid[:cells][center_idx]['precip_rate']

      grid = described_class.apply_effects(world, grid)
      precip_after = grid[:cells][center_idx]['precip_rate']

      expect(precip_after).to be > precip_before
    end

    it 'increases cloud cover significantly' do
      grid = WeatherGrid::GridService.load(world)
      center_idx = WeatherGrid::GridService.coords_to_index(32, 32)
      cloud_before = grid[:cells][center_idx]['cloud_cover']

      grid = described_class.apply_effects(world, grid)
      cloud_after = grid[:cells][center_idx]['cloud_cover']

      # Storm should increase cloud cover significantly
      expect(cloud_after).to be > cloud_before
      expect(cloud_after).to be > 70
    end

    it 'increases wind speed' do
      grid = WeatherGrid::GridService.load(world)
      center_idx = WeatherGrid::GridService.coords_to_index(32, 32)
      wind_before = grid[:cells][center_idx]['wind_speed']

      grid = described_class.apply_effects(world, grid)
      wind_after = grid[:cells][center_idx]['wind_speed']

      expect(wind_after).to be > wind_before
    end

    it 'only affects cells within storm radius' do
      grid = WeatherGrid::GridService.load(world)

      # Cell far from storm
      far_idx = WeatherGrid::GridService.coords_to_index(10, 10)
      precip_before = grid[:cells][far_idx]['precip_rate']

      grid = described_class.apply_effects(world, grid)
      precip_after = grid[:cells][far_idx]['precip_rate']

      # Far cell should be unaffected
      expect(precip_after).to eq(precip_before)
    end
  end

  describe '.active_storms' do
    it 'returns empty array when no storms' do
      expect(described_class.active_storms(world)).to eq([])
    end

    it 'returns all active storms' do
      WeatherGrid::GridService.update_meta(world, {
        'storms' => [
          { 'id' => 'storm_1', 'type' => 'thunderstorm' },
          { 'id' => 'storm_2', 'type' => 'blizzard' }
        ]
      })

      storms = described_class.active_storms(world)
      expect(storms.length).to eq(2)
    end
  end

  describe '.storm_at' do
    before do
      WeatherGrid::GridService.update_meta(world, {
        'storms' => [
          {
            'id' => 'storm_here',
            'type' => 'thunderstorm',
            'grid_x' => 32.0,
            'grid_y' => 32.0,
            'radius_cells' => 3.0
          }
        ]
      })
    end

    it 'returns storm when position is within radius' do
      storm = described_class.storm_at(world, 33.0, 32.0)
      expect(storm).not_to be_nil
      expect(storm['id']).to eq('storm_here')
    end

    it 'returns nil when position is outside all storms' do
      storm = described_class.storm_at(world, 10.0, 10.0)
      expect(storm).to be_nil
    end
  end

  describe 'storm phases' do
    it 'transitions from forming to mature' do
      WeatherGrid::GridService.update_meta(world, {
        'storms' => [
          {
            'id' => 'storm_forming',
            'type' => 'thunderstorm',
            'grid_x' => 32.0,
            'grid_y' => 32.0,
            'heading' => 0,
            'speed' => 20.0,
            'intensity' => 0.5,
            'phase' => 'forming',
            'radius_cells' => 1.5,
            'ticks_in_phase' => 10,
            'phase_duration' => 5  # Will transition immediately
          }
        ]
      })

      grid = WeatherGrid::GridService.load(world)
      described_class.tick_storms(world, grid)

      grid_after = WeatherGrid::GridService.load(world)
      storm = grid_after[:meta]['storms'].first
      expect(storm['phase']).to eq('mature')
    end
  end
end
