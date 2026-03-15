# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/world_generation/globe_hex_grid'

RSpec.describe WorldGeneration::GlobeHexGrid do
  let(:world) { create(:world) }

  describe '#initialize' do
    it 'creates a grid with default subdivisions' do
      grid = described_class.new(world)
      expect(grid.subdivisions).to eq(5)
    end

    it 'accepts custom subdivision count' do
      grid = described_class.new(world, subdivisions: 3)
      expect(grid.subdivisions).to eq(3)
    end

    it 'stores the world reference' do
      grid = described_class.new(world)
      expect(grid.world).to eq(world)
    end
  end

  describe '#hex_count' do
    it 'returns 20 hexes for 0 subdivisions (icosahedron faces)' do
      grid = described_class.new(world, subdivisions: 0)
      expect(grid.hex_count).to eq(20)
    end

    it 'returns 80 hexes for 1 subdivision' do
      grid = described_class.new(world, subdivisions: 1)
      expect(grid.hex_count).to eq(80)
    end

    it 'returns 320 hexes for 2 subdivisions' do
      grid = described_class.new(world, subdivisions: 2)
      expect(grid.hex_count).to eq(320)
    end

    it 'returns 20480 hexes for 5 subdivisions' do
      grid = described_class.new(world, subdivisions: 5)
      expect(grid.hex_count).to eq(20_480)
    end

    it 'follows the 20 * 4^n formula' do
      (0..4).each do |n|
        grid = described_class.new(world, subdivisions: n)
        expected = 20 * (4**n)
        expect(grid.hex_count).to eq(expected), "Expected #{expected} for subdivisions=#{n}, got #{grid.hex_count}"
      end
    end
  end

  describe '#each_hex' do
    let(:grid) { described_class.new(world, subdivisions: 1) }

    it 'yields each hex' do
      hexes = []
      grid.each_hex { |hex| hexes << hex }
      expect(hexes.size).to eq(80)
    end

    it 'yields HexData objects' do
      grid.each_hex do |hex|
        expect(hex).to be_a(WorldGeneration::HexData)
      end
    end

    it 'returns an enumerator without a block' do
      expect(grid.each_hex).to be_a(Enumerator)
    end
  end

  describe '#hex_by_id' do
    let(:grid) { described_class.new(world, subdivisions: 1) }

    it 'returns the hex with matching id' do
      hex = grid.hex_by_id(0)
      expect(hex).to be_a(WorldGeneration::HexData)
      expect(hex.id).to eq(0)
    end

    it 'returns nil for non-existent id' do
      hex = grid.hex_by_id(999_999)
      expect(hex).to be_nil
    end

    it 'can find any hex by its id' do
      grid.each_hex do |hex|
        found = grid.hex_by_id(hex.id)
        expect(found).to eq(hex)
      end
    end
  end

  describe '#neighbors_of' do
    let(:grid) { described_class.new(world, subdivisions: 2) }

    it 'returns approximately 6-7 neighbors' do
      hex = grid.hex_by_id(50)
      neighbors = grid.neighbors_of(hex)
      expect(neighbors.size).to be_between(5, 7)
    end

    it 'returns HexData objects' do
      hex = grid.hex_by_id(50)
      neighbors = grid.neighbors_of(hex)
      neighbors.each do |neighbor|
        expect(neighbor).to be_a(WorldGeneration::HexData)
      end
    end

    it 'does not include the hex itself' do
      hex = grid.hex_by_id(50)
      neighbors = grid.neighbors_of(hex)
      expect(neighbors).not_to include(hex)
    end

    it 'returns nearby hexes based on angular distance' do
      hex = grid.hex_by_id(50)
      neighbors = grid.neighbors_of(hex)

      neighbors.each do |neighbor|
        # Calculate angular distance using dot product
        dot = hex.x * neighbor.x + hex.y * neighbor.y + hex.z * neighbor.z
        angle = Math.acos(dot.clamp(-1.0, 1.0))

        # Neighbors should be relatively close
        expect(angle).to be < 0.5 # radians, ~28 degrees
      end
    end
  end

  describe '#hex_at_latlon' do
    let(:grid) { described_class.new(world, subdivisions: 3) }

    it 'finds a hex near the equator and prime meridian' do
      hex = grid.hex_at_latlon(0.0, 0.0)
      expect(hex).to be_a(WorldGeneration::HexData)
      expect(hex.lat).to be_within(0.3).of(0.0)
      expect(hex.lon).to be_within(0.3).of(0.0)
    end

    it 'finds a hex at the north pole' do
      hex = grid.hex_at_latlon(Math::PI / 2, 0.0)
      expect(hex).to be_a(WorldGeneration::HexData)
      expect(hex.lat).to be > 1.0 # Close to PI/2
    end

    it 'finds a hex at the south pole' do
      hex = grid.hex_at_latlon(-Math::PI / 2, 0.0)
      expect(hex).to be_a(WorldGeneration::HexData)
      expect(hex.lat).to be < -1.0 # Close to -PI/2
    end

    it 'finds a hex at various locations' do
      locations = [
        [0.5, 1.0],   # Northern hemisphere, east
        [-0.5, -1.0], # Southern hemisphere, west
        [1.0, 3.0],   # Near pole, far east
      ]

      locations.each do |lat, lon|
        hex = grid.hex_at_latlon(lat, lon)
        expect(hex).to be_a(WorldGeneration::HexData)
      end
    end
  end

  describe '#latitude_of and #longitude_of' do
    let(:grid) { described_class.new(world, subdivisions: 1) }

    it 'returns latitude in radians' do
      hex = grid.hex_by_id(0)
      lat = grid.latitude_of(hex)
      expect(lat).to be_between(-Math::PI / 2, Math::PI / 2)
    end

    it 'returns longitude in radians' do
      hex = grid.hex_by_id(0)
      lon = grid.longitude_of(hex)
      expect(lon).to be_between(-Math::PI, Math::PI)
    end

    it 'matches the hex lat/lon fields' do
      grid.each_hex do |hex|
        expect(grid.latitude_of(hex)).to eq(hex.lat)
        expect(grid.longitude_of(hex)).to eq(hex.lon)
      end
    end
  end

  describe '#to_db_records' do
    let(:grid) { described_class.new(world, subdivisions: 1) }

    it 'returns an array of hashes' do
      records = grid.to_db_records
      expect(records).to be_an(Array)
      expect(records.first).to be_a(Hash)
    end

    it 'returns a record for each hex' do
      records = grid.to_db_records
      expect(records.size).to eq(grid.hex_count)
    end

    it 'includes required WorldHex fields' do
      records = grid.to_db_records
      record = records.first

      expect(record).to have_key(:world_id)
      expect(record).to have_key(:globe_hex_id)
      expect(record).to have_key(:terrain_type)
      expect(record).to have_key(:altitude)
      expect(record).to have_key(:latitude)
      expect(record).to have_key(:longitude)
    end

    it 'sets world_id correctly' do
      records = grid.to_db_records
      records.each do |record|
        expect(record[:world_id]).to eq(world.id)
      end
    end

    it 'sets unique globe_hex_ids' do
      records = grid.to_db_records
      ids = records.map { |r| r[:globe_hex_id] }
      expect(ids.uniq.size).to eq(ids.size)
    end

    it 'sets latitude between -90 and 90 and longitude between -180 and 180' do
      records = grid.to_db_records
      records.each do |record|
        expect(record[:latitude]).to be_between(-90, 90)
        expect(record[:longitude]).to be_between(-180, 180)
      end
    end

    it 'defaults terrain_type to plain' do
      records = grid.to_db_records
      records.each do |record|
        expect(record[:terrain_type]).to eq('grassy_plains')
      end
    end
  end

  describe WorldGeneration::HexData do
    describe '#ocean?' do
      it 'returns true for negative elevation' do
        hex = WorldGeneration::HexData.new(elevation: -0.5)
        expect(hex.ocean?).to be true
      end

      it 'returns false for positive elevation' do
        hex = WorldGeneration::HexData.new(elevation: 0.5)
        expect(hex.ocean?).to be false
      end

      it 'returns false for zero elevation' do
        hex = WorldGeneration::HexData.new(elevation: 0.0)
        expect(hex.ocean?).to be false
      end

      it 'returns false for nil elevation' do
        hex = WorldGeneration::HexData.new(elevation: nil)
        expect(hex.ocean?).to be false
      end
    end

    describe '#land?' do
      it 'returns false for negative elevation' do
        hex = WorldGeneration::HexData.new(elevation: -0.5)
        expect(hex.land?).to be false
      end

      it 'returns true for positive elevation' do
        hex = WorldGeneration::HexData.new(elevation: 0.5)
        expect(hex.land?).to be true
      end

      it 'returns true for zero elevation' do
        hex = WorldGeneration::HexData.new(elevation: 0.0)
        expect(hex.land?).to be true
      end

      it 'returns true for nil elevation' do
        hex = WorldGeneration::HexData.new(elevation: nil)
        expect(hex.land?).to be true
      end
    end

    it 'supports keyword initialization' do
      hex = WorldGeneration::HexData.new(
        id: 42,
        x: 0.5,
        y: 0.5,
        z: 0.707,
        lat: 0.78,
        lon: 0.78,
        face_index: 5,
        plate_id: 3,
        elevation: 0.25,
        temperature: 0.7,
        moisture: 0.4,
        terrain_type: 'dense_forest',
        river_directions: %w[n ne]
      )

      expect(hex.id).to eq(42)
      expect(hex.x).to eq(0.5)
      expect(hex.face_index).to eq(5)
      expect(hex.terrain_type).to eq('dense_forest')
      expect(hex.river_directions).to eq(%w[n ne])
    end
  end

  describe 'spherical properties' do
    let(:grid) { described_class.new(world, subdivisions: 2) }

    it 'all hexes lie on the unit sphere' do
      grid.each_hex do |hex|
        length = Math.sqrt(hex.x**2 + hex.y**2 + hex.z**2)
        expect(length).to be_within(0.001).of(1.0)
      end
    end

    it 'lat/lon are consistent with xyz coordinates' do
      grid.each_hex do |hex|
        # Reconstruct xyz from lat/lon
        expected_x = Math.cos(hex.lat) * Math.cos(hex.lon)
        expected_y = Math.cos(hex.lat) * Math.sin(hex.lon)
        expected_z = Math.sin(hex.lat)

        expect(hex.x).to be_within(0.001).of(expected_x)
        expect(hex.y).to be_within(0.001).of(expected_y)
        expect(hex.z).to be_within(0.001).of(expected_z)
      end
    end

    it 'hexes are reasonably evenly distributed' do
      # Check that we have hexes in both hemispheres
      northern = grid.hexes.count { |h| h.z > 0 }
      southern = grid.hexes.count { |h| h.z < 0 }

      # Should be roughly equal
      expect(northern).to be_within(grid.hex_count * 0.1).of(southern)
    end
  end

  describe 'performance' do
    it 'generates grid in reasonable time' do
      start_time = Time.now
      # Use subdivision 4 for performance test (5120 hexes is reasonable for testing)
      described_class.new(world, subdivisions: 4)
      elapsed = Time.now - start_time

      # Should complete in under 10 seconds for 5120 hexes
      # Full grid (subdivisions: 5 = 20480 hexes) takes ~25-30 seconds which is acceptable
      # for background world generation jobs
      expect(elapsed).to be < 10.0
    end

    it 'can look up hexes by id quickly' do
      grid = described_class.new(world, subdivisions: 4)

      start_time = Time.now
      1000.times do |i|
        grid.hex_by_id(i % grid.hex_count)
      end
      elapsed = Time.now - start_time

      # 1000 lookups should be very fast
      expect(elapsed).to be < 0.1
    end
  end
end
