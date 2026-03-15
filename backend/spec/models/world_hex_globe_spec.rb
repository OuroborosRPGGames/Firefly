# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldHex, 'Globe Hex System' do
  let(:world) { create(:world) }

  describe 'validations' do
    describe 'globe_hex_id requirement' do
      it 'is valid with globe_hex_id' do
        hex = described_class.new(
          world: world,
          globe_hex_id: 1,
          terrain_type: 'grassy_plains',
          latitude: 45.0,
          longitude: -122.0
        )
        expect(hex).to be_valid
      end

      it 'is invalid without globe_hex_id' do
        hex = described_class.new(
          world: world,
          terrain_type: 'grassy_plains',
          latitude: 45.0,
          longitude: -122.0
        )
        expect(hex).not_to be_valid
        expect(hex.errors[:globe_hex_id]).not_to be_empty
      end
    end

    describe 'uniqueness of [world_id, globe_hex_id]' do
      it 'enforces unique globe_hex_id per world' do
        described_class.create(
          world: world,
          globe_hex_id: 100,
          terrain_type: 'grassy_plains',
          latitude: 45.0,
          longitude: -122.0
        )

        duplicate = described_class.new(
          world: world,
          globe_hex_id: 100,
          terrain_type: 'ocean',
          latitude: 46.0,
          longitude: -123.0
        )
        expect(duplicate).not_to be_valid
      end

      it 'allows same globe_hex_id in different worlds' do
        other_world = create(:world)

        described_class.create(
          world: world,
          globe_hex_id: 100,
          terrain_type: 'grassy_plains',
          latitude: 45.0,
          longitude: -122.0
        )

        hex_in_other = described_class.new(
          world: other_world,
          globe_hex_id: 100,
          terrain_type: 'ocean',
          latitude: 46.0,
          longitude: -123.0
        )
        expect(hex_in_other).to be_valid
      end
    end
  end

  describe '.find_by_globe_hex' do
    it 'finds hex by world_id and globe_hex_id' do
      hex = create(:world_hex, world: world, globe_hex_id: 42)

      result = described_class.find_by_globe_hex(world.id, 42)
      expect(result).to eq(hex)
    end

    it 'returns nil when hex does not exist' do
      result = described_class.find_by_globe_hex(world.id, 99999)
      expect(result).to be_nil
    end

    it 'does not find hex from different world' do
      other_world = create(:world)
      create(:world_hex, world: world, globe_hex_id: 42)

      result = described_class.find_by_globe_hex(other_world.id, 42)
      expect(result).to be_nil
    end
  end

  describe '.find_nearest_by_latlon' do
    before do
      # Create hexes at known locations
      # Hex at origin (0, 0)
      create(:world_hex, world: world, globe_hex_id: 1, latitude: 0.0, longitude: 0.0)
      # Hex near equator but offset
      create(:world_hex, world: world, globe_hex_id: 2, latitude: 0.5, longitude: 0.5)
      # Hex in northern hemisphere
      create(:world_hex, world: world, globe_hex_id: 3, latitude: 45.0, longitude: -122.0)
      # Hex in southern hemisphere
      create(:world_hex, world: world, globe_hex_id: 4, latitude: -33.9, longitude: 151.2)
    end

    it 'finds the nearest hex to given coordinates' do
      # Should find hex at (0,0)
      result = described_class.find_nearest_by_latlon(world.id, 0.1, 0.1)
      expect(result.globe_hex_id).to eq(1)
    end

    it 'finds nearest hex when query point is closer to another hex' do
      # Should find hex at (45, -122)
      result = described_class.find_nearest_by_latlon(world.id, 44.0, -121.0)
      expect(result.globe_hex_id).to eq(3)
    end

    it 'returns nil when world has no hexes' do
      empty_world = create(:world)
      result = described_class.find_nearest_by_latlon(empty_world.id, 0.0, 0.0)
      expect(result).to be_nil
    end

    it 'handles antimeridian correctly' do
      # Create hex near antimeridian
      create(:world_hex, world: world, globe_hex_id: 5, latitude: 0.0, longitude: 179.0)

      # Query from other side of antimeridian
      result = described_class.find_nearest_by_latlon(world.id, 0.0, -179.0)
      # Should find the hex at 179.0, which is only 2 degrees away
      expect(result.globe_hex_id).to eq(5)
    end
  end

  describe '.neighbors_of' do
    let(:center_hex) do
      create(:world_hex, world: world, globe_hex_id: 1, latitude: 45.0, longitude: -122.0)
    end

    before do
      # Create nearby hexes (within neighbor threshold of ~1 degree)
      create(:world_hex, world: world, globe_hex_id: 2, latitude: 45.5, longitude: -122.0)   # 0.5 deg north
      create(:world_hex, world: world, globe_hex_id: 3, latitude: 44.5, longitude: -122.0)   # 0.5 deg south
      create(:world_hex, world: world, globe_hex_id: 4, latitude: 45.0, longitude: -121.5)   # 0.5 deg east
      create(:world_hex, world: world, globe_hex_id: 5, latitude: 45.0, longitude: -122.5)   # 0.5 deg west

      # Create distant hex (outside threshold)
      create(:world_hex, world: world, globe_hex_id: 6, latitude: 50.0, longitude: -122.0)   # 5 deg away
    end

    it 'returns hexes within angular threshold' do
      neighbors = described_class.neighbors_of(center_hex)

      neighbor_ids = neighbors.map(&:globe_hex_id)
      expect(neighbor_ids).to include(2, 3, 4, 5)
      expect(neighbor_ids).not_to include(6)
    end

    it 'does not include the hex itself in neighbors' do
      neighbors = described_class.neighbors_of(center_hex)

      neighbor_ids = neighbors.map(&:globe_hex_id)
      expect(neighbor_ids).not_to include(1)
    end

    it 'returns empty array when no neighbors exist' do
      isolated_world = create(:world)
      isolated_hex = create(:world_hex, world: isolated_world, globe_hex_id: 1, latitude: 0.0, longitude: 0.0)

      neighbors = described_class.neighbors_of(isolated_hex)
      expect(neighbors).to eq([])
    end

    it 'handles wrapping around poles' do
      polar_hex = create(:world_hex, world: world, globe_hex_id: 10, latitude: 89.5, longitude: 0.0)
      create(:world_hex, world: world, globe_hex_id: 11, latitude: 89.6, longitude: 90.0)  # Same lat but different lon

      neighbors = described_class.neighbors_of(polar_hex)
      neighbor_ids = neighbors.map(&:globe_hex_id)

      # At the poles, hexes at similar latitude but different longitude should be neighbors
      expect(neighbor_ids).to include(11)
    end
  end

  describe '.great_circle_distance_rad' do
    it 'returns 0 for same point' do
      distance = described_class.great_circle_distance_rad(45.0, -122.0, 45.0, -122.0)
      expect(distance).to eq(0.0)
    end

    it 'calculates correct distance for known points' do
      # Distance from (0,0) to (0,1) should be approximately 1 degree in radians
      distance = described_class.great_circle_distance_rad(0.0, 0.0, 0.0, 1.0)
      expected = 1.0 * Math::PI / 180.0  # 1 degree in radians
      expect(distance).to be_within(0.001).of(expected)
    end

    it 'calculates correct quarter earth distance' do
      # From equator to north pole is 90 degrees = pi/2 radians
      distance = described_class.great_circle_distance_rad(0.0, 0.0, 90.0, 0.0)
      expect(distance).to be_within(0.001).of(Math::PI / 2)
    end

    it 'handles antimeridian crossing' do
      # From (0, 179) to (0, -179) should be ~2 degrees
      distance = described_class.great_circle_distance_rad(0.0, 179.0, 0.0, -179.0)
      expected = 2.0 * Math::PI / 180.0
      expect(distance).to be_within(0.001).of(expected)
    end
  end

  describe '#to_api_hash' do
    it 'includes globe_hex_id' do
      hex = create(:world_hex, world: world, globe_hex_id: 42)
      result = hex.to_api_hash

      expect(result[:globe_hex_id]).to eq(42)
    end

    it 'includes latitude and longitude' do
      hex = create(:world_hex, world: world, globe_hex_id: 1, latitude: 45.5, longitude: -122.5)
      result = hex.to_api_hash

      expect(result[:latitude]).to eq(45.5)
      expect(result[:longitude]).to eq(-122.5)
    end

    it 'does not include hex_x or hex_y' do
      hex = create(:world_hex, world: world, globe_hex_id: 1)
      result = hex.to_api_hash

      expect(result).not_to have_key(:hex_x)
      expect(result).not_to have_key(:hex_y)
    end

    it 'includes all standard fields' do
      hex = create(:world_hex, world: world, globe_hex_id: 1, terrain_type: 'mountain')
      result = hex.to_api_hash

      expect(result).to include(
        :id, :world_id, :globe_hex_id, :latitude, :longitude,
        :terrain_type, :altitude, :traversable, :directional_features,
        :linear_features, :movement_cost, :blocks_sight, :has_road,
        :has_river, :has_railway
      )
    end
  end

  describe '#globe_hex?' do
    it 'returns true when globe_hex_id is present' do
      hex = create(:world_hex, world: world, globe_hex_id: 1)
      expect(hex.globe_hex?).to be true
    end
  end

  describe 'NEIGHBOR_THRESHOLD_DEGREES constant' do
    it 'is defined' do
      expect(described_class::NEIGHBOR_THRESHOLD_DEGREES).to eq(1.0)
    end
  end
end
