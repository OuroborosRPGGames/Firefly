# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EarthImport::CoordinateConverter do
  let(:converter) { described_class.new }

  describe '#point_to_hex' do
    it 'converts lat/lon to nearest hex on grid' do
      # Create a simple test grid
      grid = WorldGeneration::GlobeHexGrid.new(nil, subdivisions: 2)
      hex = converter.point_to_hex(0.0, 0.0, grid)

      expect(hex).to be_a(WorldGeneration::HexData)
    end

    it 'finds hex for various coordinates' do
      grid = WorldGeneration::GlobeHexGrid.new(nil, subdivisions: 2)

      # Test different locations
      hex1 = converter.point_to_hex(45.0, 0.0, grid)   # Europe
      hex2 = converter.point_to_hex(-30.0, -60.0, grid) # South America
      hex3 = converter.point_to_hex(35.0, 135.0, grid)  # Japan

      expect(hex1).not_to be_nil
      expect(hex2).not_to be_nil
      expect(hex3).not_to be_nil
    end

    it 'finds different hexes for distant locations' do
      grid = WorldGeneration::GlobeHexGrid.new(nil, subdivisions: 2)

      # North pole vs south pole should be different hexes
      north_pole = converter.point_to_hex(89.0, 0.0, grid)
      south_pole = converter.point_to_hex(-89.0, 0.0, grid)

      expect(north_pole.id).not_to eq(south_pole.id)
    end
  end

  describe '#line_to_hexes' do
    let(:grid) { WorldGeneration::GlobeHexGrid.new(nil, subdivisions: 2) }

    it 'returns array of hex updates along a line' do
      # Simple north-south line
      coords = [[10, 0], [0, 0], [-10, 0]]
      result = converter.line_to_hexes(coords, grid)

      expect(result).to be_an(Array)
      expect(result.length).to be >= 1
    end

    it 'includes hex and directions in each result' do
      coords = [[10, 0], [0, 0]]
      result = converter.line_to_hexes(coords, grid)

      result.each do |info|
        expect(info).to include(:hex)
        expect(info).to include(:directions)
        expect(info[:directions]).to be_an(Array)
      end
    end

    it 'returns empty array for single point' do
      result = converter.line_to_hexes([[0, 0]], grid)
      expect(result).to eq([])
    end

    it 'returns empty array for nil coordinates' do
      result = converter.line_to_hexes(nil, grid)
      expect(result).to eq([])
    end

    it 'returns empty array for empty coordinates' do
      result = converter.line_to_hexes([], grid)
      expect(result).to eq([])
    end

    it 'does not duplicate consecutive same hexes' do
      # Very short line within same hex should not duplicate
      coords = [[0.0, 0.0], [0.001, 0.001]]
      result = converter.line_to_hexes(coords, grid)

      # Should have at most 1 unique hex for such a short line
      expect(result.length).to be <= 1
    end
  end

  describe '#polygon_contains?' do
    let(:square_polygon) do
      [[-10, -10], [-10, 10], [10, 10], [10, -10], [-10, -10]]
    end

    it 'returns true for point inside polygon' do
      expect(converter.polygon_contains?(square_polygon, 0, 0)).to be true
    end

    it 'returns false for point outside polygon' do
      expect(converter.polygon_contains?(square_polygon, 50, 50)).to be false
    end

    it 'returns false for nil polygon' do
      expect(converter.polygon_contains?(nil, 0, 0)).to be false
    end

    it 'returns false for empty polygon' do
      expect(converter.polygon_contains?([], 0, 0)).to be false
    end

    it 'returns false for polygon with only 2 points' do
      expect(converter.polygon_contains?([[0, 0], [1, 1]], 0.5, 0.5)).to be false
    end

    it 'handles complex polygon shapes' do
      # L-shaped polygon
      l_polygon = [
        [0, 0], [0, 10], [5, 10], [5, 5], [10, 5], [10, 0], [0, 0]
      ]

      # Point inside the L
      expect(converter.polygon_contains?(l_polygon, 2, 2)).to be true

      # Point outside the L (in the cut-out area)
      expect(converter.polygon_contains?(l_polygon, 7, 7)).to be false
    end
  end

  describe '#hexes_in_polygon' do
    let(:grid) { WorldGeneration::GlobeHexGrid.new(nil, subdivisions: 2) }

    it 'returns hexes within a polygon' do
      # Large polygon around the equator
      polygon = [[-20, -20], [-20, 20], [20, 20], [20, -20], [-20, -20]]
      hexes = converter.hexes_in_polygon(polygon, grid)

      expect(hexes).to be_an(Array)
      expect(hexes.all? { |h| h.is_a?(WorldGeneration::HexData) }).to be true
    end

    it 'returns empty array for nil polygon' do
      expect(converter.hexes_in_polygon(nil, grid)).to eq([])
    end

    it 'returns empty array for empty polygon' do
      expect(converter.hexes_in_polygon([], grid)).to eq([])
    end
  end

  describe '#degrees_to_radians' do
    it 'converts 0 degrees to 0 radians' do
      expect(converter.degrees_to_radians(0)).to eq(0)
    end

    it 'converts 180 degrees to PI radians' do
      expect(converter.degrees_to_radians(180)).to be_within(0.0001).of(Math::PI)
    end

    it 'converts 90 degrees to PI/2 radians' do
      expect(converter.degrees_to_radians(90)).to be_within(0.0001).of(Math::PI / 2)
    end

    it 'converts negative degrees correctly' do
      expect(converter.degrees_to_radians(-90)).to be_within(0.0001).of(-Math::PI / 2)
    end
  end

  describe '#radians_to_degrees' do
    it 'converts 0 radians to 0 degrees' do
      expect(converter.radians_to_degrees(0)).to eq(0)
    end

    it 'converts PI radians to 180 degrees' do
      expect(converter.radians_to_degrees(Math::PI)).to be_within(0.0001).of(180)
    end

    it 'converts PI/2 radians to 90 degrees' do
      expect(converter.radians_to_degrees(Math::PI / 2)).to be_within(0.0001).of(90)
    end
  end
end
