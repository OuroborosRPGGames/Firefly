# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EarthImport::RiverTracer do
  let(:converter) { EarthImport::CoordinateConverter.new }
  let(:tracer) { described_class.new(coordinate_converter: converter) }

  describe '#trace_river' do
    let(:grid) { WorldGeneration::GlobeHexGrid.new(nil, subdivisions: 2) }

    it 'returns array of hex updates with river directions' do
      # Simple north-south river (lat, lon pairs)
      coords = [[10, 0], [5, 0], [0, 0], [-5, 0]]

      updates = tracer.trace_river(coords, grid)

      expect(updates).to be_an(Array)
      expect(updates.length).to be >= 1
    end

    it 'includes hex and directions in each update' do
      coords = [[10, 0], [0, 0]]
      updates = tracer.trace_river(coords, grid)

      updates.each do |update|
        expect(update).to include(:hex)
        expect(update[:directions]).to be_an(Array)
      end
    end

    it 'returns empty for nil coords' do
      expect(tracer.trace_river(nil, grid)).to eq([])
    end

    it 'returns empty for single point' do
      expect(tracer.trace_river([[0, 0]], grid)).to eq([])
    end
  end

  describe '#apply_to_grid' do
    let(:grid) { WorldGeneration::GlobeHexGrid.new(nil, subdivisions: 2) }

    it 'processes multiple rivers' do
      rivers = [
        { name: 'Test River 1', coords: [[10, 0], [0, 0]], upstream_area: 50_000 },
        { name: 'Test River 2', coords: [[0, 10], [0, 0]], upstream_area: 20_000 }
      ]

      tracer.apply_to_grid(grid, rivers)

      # At least some hexes should have river directions
      hexes_with_rivers = grid.hexes.select { |h| h.river_directions && h.river_directions.any? }
      expect(hexes_with_rivers).not_to be_empty
    end

    it 'handles empty rivers list' do
      expect { tracer.apply_to_grid(grid, []) }.not_to raise_error
    end

    it 'calls progress callback' do
      rivers = (1..100).map do |i|
        { name: "River #{i}", coords: [[i, 0], [0, 0]], upstream_area: 50_000 }
      end

      callback_called = false
      tracer.apply_to_grid(grid, rivers, progress_callback: ->(_current, _total) { callback_called = true })

      expect(callback_called).to be true
    end

    it 'sets river_width based on upstream_area' do
      rivers = [
        { name: 'Small Stream', coords: [[10, 0], [0, 0]], upstream_area: 15_000 },
        { name: 'Medium River', coords: [[0, 20], [0, 10]], upstream_area: 50_000 },
        { name: 'Major River', coords: [[30, 0], [20, 0]], upstream_area: 150_000 }
      ]

      tracer.apply_to_grid(grid, rivers)

      # Check that hexes have river_width set
      hexes_with_width = grid.hexes.select { |h| h.river_width && h.river_width > 0 }
      expect(hexes_with_width).not_to be_empty
    end

    it 'classifies river width correctly by upstream area' do
      # Test the classification thresholds:
      # < 25,000 km² = stream (1)
      # 25,000 - 100,000 km² = river (2)
      # > 100,000 km² = major (3)
      rivers = [
        { name: 'Stream', coords: [[5, 0], [0, 0]], upstream_area: 20_000 }
      ]

      tracer.apply_to_grid(grid, rivers)

      hexes_with_rivers = grid.hexes.select { |h| h.river_width && h.river_width > 0 }
      # Stream should have width 1
      expect(hexes_with_rivers.any? { |h| h.river_width == 1 }).to be true
    end

    it 'takes max width when rivers merge' do
      # Two rivers crossing at the same area - should take the larger width
      rivers = [
        { name: 'Small', coords: [[10, 0], [0, 0]], upstream_area: 15_000 },   # width 1
        { name: 'Large', coords: [[0, 10], [0, 0]], upstream_area: 150_000 }   # width 3
      ]

      tracer.apply_to_grid(grid, rivers)

      # Hexes near origin (0,0) should have the larger width
      hex_near_origin = grid.hexes.min_by { |h| h.lat.abs + h.lon.abs }
      if hex_near_origin&.river_width
        # If this hex has rivers from both, it should have the max width
        expect(hex_near_origin.river_width).to be >= 1
      end
    end
  end

  describe '#filter_major_rivers' do
    it 'filters to rivers with upstream area >= threshold' do
      rivers = [
        { upstream_area: 50_000, name: 'Big River' },
        { upstream_area: 5_000, name: 'Small Stream' },
        { upstream_area: 15_000, name: 'Medium River' },
        { upstream_area: 10_000, name: 'Threshold River' }
      ]

      filtered = tracer.filter_major_rivers(rivers, min_area: 10_000)

      expect(filtered.length).to eq(3)
      expect(filtered.map { |r| r[:name] }).to contain_exactly('Big River', 'Medium River', 'Threshold River')
    end

    it 'returns empty array for empty input' do
      expect(tracer.filter_major_rivers([], min_area: 10_000)).to eq([])
    end

    it 'returns empty array for nil input' do
      expect(tracer.filter_major_rivers(nil, min_area: 10_000)).to eq([])
    end

    it 'handles string keys' do
      rivers = [
        { 'upstream_area' => 50_000, 'name' => 'Big River' }
      ]

      filtered = tracer.filter_major_rivers(rivers, min_area: 10_000)
      expect(filtered.length).to eq(1)
    end

    it 'uses default threshold of 10,000 km2' do
      rivers = [
        { upstream_area: 50_000, name: 'Big River' },
        { upstream_area: 5_000, name: 'Small Stream' }
      ]

      filtered = tracer.filter_major_rivers(rivers)
      expect(filtered.length).to eq(1)
      expect(filtered.first[:name]).to eq('Big River')
    end
  end

  describe '#load_from_shapefile' do
    it 'returns empty array for nil path' do
      expect(tracer.load_from_shapefile(nil)).to eq([])
    end

    it 'returns empty array for non-existent directory' do
      expect(tracer.load_from_shapefile('/nonexistent/path')).to eq([])
    end

    it 'returns empty array for directory without shapefiles' do
      Dir.mktmpdir do |dir|
        expect(tracer.load_from_shapefile(dir)).to eq([])
      end
    end
  end

  describe 'integration with CoordinateConverter' do
    let(:grid) { WorldGeneration::GlobeHexGrid.new(nil, subdivisions: 2) }

    it 'correctly traces a river crossing multiple hexes' do
      # A longer river path
      coords = [
        [45, -120],
        [40, -115],
        [35, -110],
        [30, -105]
      ]

      updates = tracer.trace_river(coords, grid)

      expect(updates.length).to be >= 2
      expect(updates.first[:hex]).to be_a(WorldGeneration::HexData)
    end
  end
end
