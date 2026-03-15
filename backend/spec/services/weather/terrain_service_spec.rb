# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WeatherGrid::TerrainService do
  let(:world) { create(:world) }

  before do
    # Clear any cached data
    described_class.clear(world)
  end

  after do
    described_class.clear(world)
  end

  describe 'constants' do
    it 'defines terrain type classifications' do
      expect(described_class::WATER_TYPES).to include('ocean', 'lake')
      expect(described_class::FOREST_TYPES).to include('dense_forest', 'jungle')
      expect(described_class::MOUNTAIN_TYPES).to include('mountain')
    end

    it 'defines albedo values for all terrain types' do
      expect(described_class::TERRAIN_ALBEDO['ocean']).to be < described_class::TERRAIN_ALBEDO['desert']
      expect(described_class::TERRAIN_ALBEDO['tundra']).to be > 0.5 # Reflects a lot
    end

    it 'defines evaporation rates' do
      expect(described_class::TERRAIN_EVAPORATION['ocean']).to be > 2.0
      expect(described_class::TERRAIN_EVAPORATION['desert']).to be < 0.5
    end

    it 'defines roughness values' do
      expect(described_class::TERRAIN_ROUGHNESS['ocean']).to be < 0.2
      expect(described_class::TERRAIN_ROUGHNESS['jungle']).to be >= 1.0
    end
  end

  describe '.aggregate' do
    context 'with no hex data' do
      it 'creates cells with default values' do
        cells = described_class.aggregate(world)

        expect(cells).to be_an(Array)
        expect(cells.length).to eq(64 * 64)

        cell = cells[0]
        expect(cell).to have_key('avg_altitude')
        expect(cell).to have_key('water_pct')
        expect(cell).to have_key('albedo')
      end
    end

    context 'with hex data' do
      before do
        # Create test hexes with lat/lon in the first grid cell (cell 0,0)
        # Cell 0,0 covers lon: -180..-174.375, lat: -90..-87.1875
        create(:world_hex, world: world, globe_hex_id: 1, terrain_type: 'ocean', altitude: 0,
               latitude: -89.0, longitude: -179.0)
        create(:world_hex, world: world, globe_hex_id: 2, terrain_type: 'ocean', altitude: 0,
               latitude: -89.5, longitude: -178.0)
        create(:world_hex, world: world, globe_hex_id: 3, terrain_type: 'dense_forest', altitude: 100,
               latitude: -88.0, longitude: -177.0)
        create(:world_hex, world: world, globe_hex_id: 4, terrain_type: 'mountain', altitude: 2000,
               latitude: -88.5, longitude: -176.0)
      end

      it 'aggregates terrain statistics' do
        cells = described_class.aggregate(world)

        # First cell (0,0) should have some data
        cell = cells[0]
        expect(cell['hex_count']).to be > 0
      end

      it 'saves aggregated data to Redis' do
        described_class.aggregate(world)

        expect(described_class.cached?(world)).to be true
      end
    end
  end

  describe '.load and .save' do
    it 'round-trips terrain data through Redis' do
      test_cells = [{ 'avg_altitude' => 500, 'water_pct' => 25.0 }]

      expect(described_class.save(world, test_cells)).to be true

      loaded = described_class.load(world)
      expect(loaded).to eq(test_cells)
    end

    it 'returns nil for non-cached world' do
      expect(described_class.load(world)).to be_nil
    end
  end

  describe '.cell_at' do
    before do
      cells = Array.new(64 * 64) do |i|
        x, y = WeatherGrid::GridService.index_to_coords(i)
        {
          'cell_x' => x,
          'cell_y' => y,
          'avg_altitude' => (x + y) * 10,
          'water_pct' => 0.0
        }
      end
      described_class.save(world, cells)
    end

    it 'retrieves a specific cell' do
      cell = described_class.cell_at(world, 10, 20)

      expect(cell).not_to be_nil
      expect(cell['cell_x']).to eq(10)
      expect(cell['cell_y']).to eq(20)
      expect(cell['avg_altitude']).to eq(300) # (10 + 20) * 10
    end

    it 'returns nil for invalid coordinates' do
      expect(described_class.cell_at(world, -1, 0)).to be_nil
      expect(described_class.cell_at(world, 64, 0)).to be_nil
    end
  end

  describe '.cached?' do
    it 'returns false when no data is cached' do
      expect(described_class.cached?(world)).to be false
    end

    it 'returns true after saving data' do
      described_class.save(world, [{ 'test' => 'data' }])
      expect(described_class.cached?(world)).to be true
    end
  end

  describe '.clear' do
    it 'removes cached terrain data' do
      described_class.save(world, [{ 'test' => 'data' }])
      expect(described_class.cached?(world)).to be true

      described_class.clear(world)
      expect(described_class.cached?(world)).to be false
    end
  end

  describe '.load_or_aggregate' do
    it 'returns cached data if available' do
      test_cells = [{ 'cached' => true }]
      described_class.save(world, test_cells)

      result = described_class.load_or_aggregate(world)
      expect(result).to eq(test_cells)
    end

    it 'aggregates data if not cached' do
      expect(described_class.cached?(world)).to be false

      result = described_class.load_or_aggregate(world)

      expect(result).to be_an(Array)
      expect(result.length).to eq(64 * 64)
      expect(described_class.cached?(world)).to be true
    end
  end

  describe '.interpolate' do
    before do
      # Create a test grid with varying values
      cells = Array.new(64 * 64) do |i|
        x, y = WeatherGrid::GridService.index_to_coords(i)
        {
          'avg_altitude' => x * 100.0,  # Increases with X
          'water_pct' => y * 1.0,       # Increases with Y
          'albedo' => 0.25,
          'evaporation_rate' => 1.0,
          'roughness' => 0.5
        }
      end
      described_class.save(world, cells)
    end

    it 'interpolates values at cell center' do
      result = described_class.interpolate(world, 10.0, 20.0)

      # Should be exactly at cell (10, 20)
      expect(result['avg_altitude']).to be_within(0.1).of(1000.0)
      expect(result['water_pct']).to be_within(0.1).of(20.0)
    end

    it 'interpolates values between cells' do
      result = described_class.interpolate(world, 10.5, 20.0)

      # Should be halfway between cell 10 and cell 11 (X-axis)
      # Cell 10: avg_altitude = 1000, Cell 11: avg_altitude = 1100
      expect(result['avg_altitude']).to be_within(1.0).of(1050.0)
    end

    it 'handles edge coordinates' do
      result = described_class.interpolate(world, 63.5, 63.5)

      expect(result).to have_key('avg_altitude')
      expect(result).to have_key('water_pct')
    end

    it 'returns default values when no data cached' do
      described_class.clear(world)
      result = described_class.interpolate(world, 10.0, 20.0)

      # Should return default terrain cell values
      expect(result['albedo']).to be_within(0.1).of(0.25)
    end
  end

  describe 'terrain property calculations' do
    it 'ocean has low albedo (absorbs heat)' do
      expect(described_class::TERRAIN_ALBEDO['ocean']).to be < 0.1
    end

    it 'tundra has high albedo (reflects heat)' do
      expect(described_class::TERRAIN_ALBEDO['tundra']).to be > 0.7
    end

    it 'ocean has high evaporation rate' do
      expect(described_class::TERRAIN_EVAPORATION['ocean']).to be > 2.5
    end

    it 'jungle has highest roughness' do
      max_roughness = described_class::TERRAIN_ROUGHNESS.values.max
      expect(described_class::TERRAIN_ROUGHNESS['jungle']).to eq(max_roughness)
    end
  end
end
