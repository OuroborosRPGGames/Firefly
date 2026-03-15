# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WeatherGrid::GridService do
  let(:world) { create(:world) }

  before do
    # Clear any existing data
    described_class.clear(world) if described_class.exists?(world)
  end

  after do
    described_class.clear(world)
  end

  describe 'constants' do
    it 'has a 64x64 grid size' do
      expect(described_class::GRID_SIZE).to eq(64)
      expect(described_class::GRID_TOTAL_CELLS).to eq(4096)
    end

    it 'has default values for all weather fields' do
      defaults = described_class::DEFAULTS
      expect(defaults[:temperature]).to eq(15.0)
      expect(defaults[:humidity]).to eq(50.0)
      expect(defaults[:pressure]).to eq(1013.0)
      expect(defaults[:wind_speed]).to eq(5.0)
    end
  end

  describe '.initialize_world' do
    it 'creates a new grid with default cells' do
      grid = described_class.initialize_world(world)

      expect(grid).not_to be_nil
      expect(grid[:cells]).to be_an(Array)
      expect(grid[:cells].length).to eq(4096)
      expect(grid[:meta]).to include('world_id' => world.id)
    end

    it 'saves the grid to Redis immediately' do
      described_class.initialize_world(world)

      expect(described_class.exists?(world)).to be true
    end

    it 'creates cells with weather field data' do
      grid = described_class.initialize_world(world)
      cell = grid[:cells].first

      expect(cell).to have_key('temperature')
      expect(cell).to have_key('humidity')
      expect(cell).to have_key('pressure')
      expect(cell).to have_key('wind_dir')
      expect(cell).to have_key('wind_speed')
      expect(cell).to have_key('cloud_cover')
      expect(cell).to have_key('precip_rate')
      expect(cell).to have_key('instability')
    end

    it 'applies latitude-based temperature variation' do
      grid = described_class.initialize_world(world)

      # Cells near y=32 (equator) should be warmer than cells at y=0 or y=63 (poles)
      equator_cell = grid[:cells][described_class.coords_to_index(32, 32)]
      pole_cell = grid[:cells][described_class.coords_to_index(32, 0)]

      expect(equator_cell['temperature']).to be > pole_cell['temperature']
    end

    it 'respects custom base_temperature option' do
      grid = described_class.initialize_world(world, base_temperature: 30.0)
      cell = grid[:cells][described_class.coords_to_index(32, 32)]

      # Should be warmer than default (15°C)
      expect(cell['temperature']).to be > 25.0
    end
  end

  describe '.load and .save' do
    it 'round-trips grid data through Redis' do
      described_class.initialize_world(world)
      original = described_class.load(world)

      # Modify a cell
      original[:cells][0]['temperature'] = 42.5

      described_class.save(world, original)
      reloaded = described_class.load(world)

      expect(reloaded[:cells][0]['temperature']).to eq(42.5)
    end

    it 'returns nil for non-existent world' do
      non_existent = World.new
      non_existent.id = 999_999

      expect(described_class.load(non_existent)).to be_nil
    end

    it 'handles nil world gracefully' do
      expect(described_class.load(nil)).to be_nil
      expect(described_class.save(nil, {})).to be false
    end
  end

  describe '.cell_at and .set_cell' do
    before { described_class.initialize_world(world) }

    it 'retrieves a specific cell by coordinates' do
      cell = described_class.cell_at(world, 10, 20)

      expect(cell).not_to be_nil
      expect(cell).to have_key('temperature')
    end

    it 'sets a specific cell by coordinates' do
      new_data = { 'temperature' => 99.0, 'humidity' => 85.0 }

      expect(described_class.set_cell(world, 10, 20, new_data)).to be true

      cell = described_class.cell_at(world, 10, 20)
      expect(cell['humidity']).to eq(85.0)
    end

    it 'clamps temperature to valid range when setting' do
      described_class.set_cell(world, 5, 5, { 'temperature' => 200.0 })
      cell = described_class.cell_at(world, 5, 5)

      expect(cell['temperature']).to eq(60.0) # Max is 60°C
    end

    it 'returns nil for invalid coordinates' do
      expect(described_class.cell_at(world, -1, 0)).to be_nil
      expect(described_class.cell_at(world, 64, 0)).to be_nil
      expect(described_class.cell_at(world, 0, 64)).to be_nil
    end
  end

  describe '.acquire_lock and .release_lock' do
    it 'acquires a lock successfully' do
      expect(described_class.acquire_lock(world)).to be true
    end

    it 'prevents double-locking' do
      expect(described_class.acquire_lock(world)).to be true
      expect(described_class.acquire_lock(world)).to be false
    end

    it 'releases lock allowing re-acquisition' do
      described_class.acquire_lock(world)
      described_class.release_lock(world)

      expect(described_class.acquire_lock(world)).to be true
    end
  end

  describe '.update_meta' do
    before { described_class.initialize_world(world) }

    it 'updates metadata in Redis' do
      described_class.update_meta(world, { last_tick_at: Time.now.iso8601, tick_count: 5 })

      grid = described_class.load(world)
      expect(grid[:meta]['tick_count']).to eq(5)
    end

    it 'merges with existing metadata' do
      described_class.update_meta(world, { custom_field: 'test' })

      grid = described_class.load(world)
      expect(grid[:meta]['world_id']).to eq(world.id)
      expect(grid[:meta]['custom_field']).to eq('test')
    end
  end

  describe '.interpolation_cells' do
    before { described_class.initialize_world(world) }

    it 'returns 4 cells for interpolation' do
      result = described_class.interpolation_cells(world, 10.5, 20.5)

      expect(result).to have_key(:top_left)
      expect(result).to have_key(:top_right)
      expect(result).to have_key(:bottom_left)
      expect(result).to have_key(:bottom_right)
      expect(result).to have_key(:fx)
      expect(result).to have_key(:fy)
    end

    it 'calculates correct fractional parts' do
      result = described_class.interpolation_cells(world, 10.3, 20.7)

      expect(result[:fx]).to be_within(0.01).of(0.3)
      expect(result[:fy]).to be_within(0.01).of(0.7)
    end

    it 'clamps coordinates to valid range' do
      result = described_class.interpolation_cells(world, 100.0, -5.0)

      # Should not raise, should return valid cells
      expect(result[:top_left]).not_to be_nil
    end
  end

  describe 'coordinate helpers' do
    it 'converts index to coordinates correctly' do
      expect(described_class.index_to_coords(0)).to eq([0, 0])
      expect(described_class.index_to_coords(63)).to eq([63, 0])
      expect(described_class.index_to_coords(64)).to eq([0, 1])
      expect(described_class.index_to_coords(4095)).to eq([63, 63])
    end

    it 'converts coordinates to index correctly' do
      expect(described_class.coords_to_index(0, 0)).to eq(0)
      expect(described_class.coords_to_index(63, 0)).to eq(63)
      expect(described_class.coords_to_index(0, 1)).to eq(64)
      expect(described_class.coords_to_index(63, 63)).to eq(4095)
    end

    it 'validates coordinates correctly' do
      expect(described_class.valid_coords?(0, 0)).to be true
      expect(described_class.valid_coords?(63, 63)).to be true
      expect(described_class.valid_coords?(-1, 0)).to be false
      expect(described_class.valid_coords?(64, 0)).to be false
      expect(described_class.valid_coords?(0, 64)).to be false
    end
  end

  describe '.latlon_to_grid_coords' do
    it 'maps equator/prime meridian to grid center' do
      gx, gy = described_class.latlon_to_grid_coords(0.0, 0.0)
      expect(gx).to be_within(0.1).of(32.0)
      expect(gy).to be_within(0.1).of(32.0)
    end

    it 'maps north pole to top of grid' do
      gx, gy = described_class.latlon_to_grid_coords(90.0, 0.0)
      expect(gy).to be_within(1.0).of(63.0)
    end

    it 'maps south pole to bottom of grid' do
      gx, gy = described_class.latlon_to_grid_coords(-90.0, 0.0)
      expect(gy).to be_within(0.1).of(0.0)
    end

    it 'maps date line to grid edges' do
      gx_west, _ = described_class.latlon_to_grid_coords(0.0, -180.0)
      gx_east, _ = described_class.latlon_to_grid_coords(0.0, 180.0)
      expect(gx_west).to be_within(0.1).of(0.0)
      expect(gx_east).to be_within(1.0).of(63.0)
    end

    it 'clamps out-of-range values' do
      gx, gy = described_class.latlon_to_grid_coords(100.0, 200.0)
      expect(gx).to be_between(0.0, 63.999)
      expect(gy).to be_between(0.0, 63.999)
    end
  end

  describe '.grid_coords_to_latlon' do
    it 'reverses latlon_to_grid_coords' do
      lat, lon = described_class.grid_coords_to_latlon(32.0, 32.0)
      expect(lat).to be_within(0.5).of(0.0)
      expect(lon).to be_within(0.5).of(0.0)
    end
  end

  describe '.clear' do
    it 'removes all weather data for a world' do
      described_class.initialize_world(world)
      expect(described_class.exists?(world)).to be true

      described_class.clear(world)
      expect(described_class.exists?(world)).to be false
    end
  end
end
