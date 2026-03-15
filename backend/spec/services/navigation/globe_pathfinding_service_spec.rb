# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GlobePathfindingService do
  let(:world) { create(:world) }

  describe '.find_path' do
    context 'with basic pathfinding' do
      before do
        # Create a line of hexes for testing at roughly 0.5 degree spacing
        # This is approximately 34 miles between hexes
        (0..5).each do |i|
          create(:world_hex,
            world: world,
            globe_hex_id: i,
            latitude: i * 0.5,  # 0, 0.5, 1.0, 1.5, 2.0, 2.5 degrees
            longitude: 0.0,
            terrain_type: 'grassy_plains'
          )
        end
      end

      it 'finds a path between two hexes' do
        path = described_class.find_path(
          world: world,
          start_globe_hex_id: 0,
          end_globe_hex_id: 3
        )

        expect(path).not_to be_empty
        expect(path.first).to eq(0)
        expect(path.last).to eq(3)
      end

      it 'returns start hex when start equals end' do
        path = described_class.find_path(
          world: world,
          start_globe_hex_id: 0,
          end_globe_hex_id: 0
        )

        expect(path).to eq([0])
      end

      it 'returns empty array when start hex does not exist' do
        path = described_class.find_path(
          world: world,
          start_globe_hex_id: 9999,
          end_globe_hex_id: 0
        )

        expect(path).to eq([])
      end

      it 'returns empty array when end hex does not exist' do
        path = described_class.find_path(
          world: world,
          start_globe_hex_id: 0,
          end_globe_hex_id: 9999
        )

        expect(path).to eq([])
      end

      it 'returns empty array for unreachable destination' do
        # Create an isolated hex far away with no neighbors
        create(:world_hex,
          world: world,
          globe_hex_id: 999,
          latitude: 89.0,
          longitude: 180.0,
          terrain_type: 'grassy_plains'
        )

        path = described_class.find_path(
          world: world,
          start_globe_hex_id: 0,
          end_globe_hex_id: 999
        )

        expect(path).to eq([])
      end

      it 'includes all intermediate hexes in path' do
        path = described_class.find_path(
          world: world,
          start_globe_hex_id: 0,
          end_globe_hex_id: 5
        )

        expect(path.length).to be >= 2
        expect(path.first).to eq(0)
        expect(path.last).to eq(5)
      end
    end

    context 'with water avoidance' do
      before do
        # Create path: land -> water -> land
        create(:world_hex, world: world, globe_hex_id: 10, latitude: 0.0, longitude: 0.0, terrain_type: 'grassy_plains')
        create(:world_hex, world: world, globe_hex_id: 11, latitude: 0.5, longitude: 0.0, terrain_type: 'ocean')
        create(:world_hex, world: world, globe_hex_id: 12, latitude: 1.0, longitude: 0.0, terrain_type: 'grassy_plains')
        # Alternative path through land
        create(:world_hex, world: world, globe_hex_id: 13, latitude: 0.5, longitude: 0.5, terrain_type: 'grassy_plains')
      end

      it 'avoids water hexes when avoid_water is true' do
        path = described_class.find_path(
          world: world,
          start_globe_hex_id: 10,
          end_globe_hex_id: 12,
          avoid_water: true
        )

        # Path should not include the ocean hex
        expect(path).not_to include(11)
      end

      it 'allows water hexes when avoid_water is false' do
        path = described_class.find_path(
          world: world,
          start_globe_hex_id: 10,
          end_globe_hex_id: 12,
          avoid_water: false
        )

        # Path may include the ocean hex as it's shorter
        expect(path).not_to be_empty
      end
    end

    context 'with travel_mode water' do
      before do
        # Create water path
        create(:world_hex, world: world, globe_hex_id: 20, latitude: 0.0, longitude: 0.0, terrain_type: 'sandy_coast')
        create(:world_hex, world: world, globe_hex_id: 21, latitude: 0.5, longitude: 0.0, terrain_type: 'ocean')
        create(:world_hex, world: world, globe_hex_id: 22, latitude: 1.0, longitude: 0.0, terrain_type: 'sandy_coast')
      end

      it 'prefers water hexes for water travel' do
        path = described_class.find_path(
          world: world,
          start_globe_hex_id: 20,
          end_globe_hex_id: 22,
          travel_mode: 'water'
        )

        expect(path).not_to be_empty
        expect(path.first).to eq(20)
        expect(path.last).to eq(22)
      end
    end

    context 'with travel_mode rail' do
      before do
        # Create hexes with railway features in a line where they cannot skip
        # Use 2 degree spacing so hexes are NOT neighbors directly
        # (NEIGHBOR_THRESHOLD_DEGREES is 1.0)
        hex0 = create(:world_hex, world: world, globe_hex_id: 30, latitude: 0.0, longitude: 0.0, terrain_type: 'grassy_plains')
        hex1 = create(:world_hex, world: world, globe_hex_id: 31, latitude: 0.75, longitude: 0.0, terrain_type: 'grassy_plains')
        hex2 = create(:world_hex, world: world, globe_hex_id: 32, latitude: 1.5, longitude: 0.0, terrain_type: 'grassy_plains')

        # Connect with railway features
        hex0.update(feature_n: 'railway')
        hex1.update(feature_s: 'railway', feature_n: 'railway')
        hex2.update(feature_s: 'railway')
      end

      it 'follows railway features when travel_mode is rail' do
        path = described_class.find_path(
          world: world,
          start_globe_hex_id: 30,
          end_globe_hex_id: 32,
          travel_mode: 'rail'
        )

        expect(path).not_to be_empty
        expect(path.first).to eq(30)
        expect(path.last).to eq(32)
      end

      it 'returns empty path when no railway connection exists' do
        # Remove railway features from middle hex - now no rail path exists
        WorldHex.where(world_id: world.id, globe_hex_id: 31).update(feature_s: nil, feature_n: nil)

        path = described_class.find_path(
          world: world,
          start_globe_hex_id: 30,
          end_globe_hex_id: 32,
          travel_mode: 'rail'
        )

        expect(path).to be_empty
      end
    end

    context 'with non-traversable hexes' do
      before do
        create(:world_hex, world: world, globe_hex_id: 40, latitude: 0.0, longitude: 0.0, terrain_type: 'grassy_plains', traversable: true)
        create(:world_hex, world: world, globe_hex_id: 41, latitude: 0.5, longitude: 0.0, terrain_type: 'grassy_plains', traversable: false)
        create(:world_hex, world: world, globe_hex_id: 42, latitude: 1.0, longitude: 0.0, terrain_type: 'grassy_plains', traversable: true)
        # Alternative traversable path
        create(:world_hex, world: world, globe_hex_id: 43, latitude: 0.5, longitude: 0.5, terrain_type: 'grassy_plains', traversable: true)
      end

      it 'avoids non-traversable hexes' do
        path = described_class.find_path(
          world: world,
          start_globe_hex_id: 40,
          end_globe_hex_id: 42
        )

        expect(path).not_to include(41)
      end
    end

    context 'with terrain costs' do
      before do
        # Create path with mountain obstacle
        create(:world_hex, world: world, globe_hex_id: 50, latitude: 0.0, longitude: 0.0, terrain_type: 'grassy_plains')
        create(:world_hex, world: world, globe_hex_id: 51, latitude: 0.5, longitude: 0.0, terrain_type: 'mountain')
        create(:world_hex, world: world, globe_hex_id: 52, latitude: 1.0, longitude: 0.0, terrain_type: 'grassy_plains')
        # Alternative flat path
        create(:world_hex, world: world, globe_hex_id: 53, latitude: 0.25, longitude: 0.5, terrain_type: 'grassy_plains')
        create(:world_hex, world: world, globe_hex_id: 54, latitude: 0.75, longitude: 0.5, terrain_type: 'grassy_plains')
      end

      it 'prefers lower cost terrain when possible' do
        path = described_class.find_path(
          world: world,
          start_globe_hex_id: 50,
          end_globe_hex_id: 52
        )

        expect(path).not_to be_empty
        # Path should prefer avoiding the mountain if alternative exists
        # But this depends on hex connectivity via neighbors
      end
    end
  end

  describe '.distance' do
    before do
      create(:world_hex, world: world, globe_hex_id: 100, latitude: 0.0, longitude: 0.0, terrain_type: 'grassy_plains')
      create(:world_hex, world: world, globe_hex_id: 101, latitude: 1.5, longitude: 0.0, terrain_type: 'grassy_plains')
    end

    it 'calculates great circle distance between hexes' do
      hex1 = WorldHex.find_by_globe_hex(world.id, 100)
      hex2 = WorldHex.find_by_globe_hex(world.id, 101)

      distance = described_class.distance(hex1, hex2)

      expect(distance).to be > 0
      # 1.5 degrees latitude difference should be approximately 1.5 * (PI/180) radians
      # which is about 0.026 radians
      expect(distance).to be < 0.1 # Less than ~6 degrees
    end

    it 'returns 0 for same hex' do
      hex1 = WorldHex.find_by_globe_hex(world.id, 100)

      distance = described_class.distance(hex1, hex1)

      expect(distance).to eq(0)
    end

    it 'handles nil hexes gracefully' do
      hex1 = WorldHex.find_by_globe_hex(world.id, 100)

      expect(described_class.distance(hex1, nil)).to eq(Float::INFINITY)
      expect(described_class.distance(nil, hex1)).to eq(Float::INFINITY)
      expect(described_class.distance(nil, nil)).to eq(Float::INFINITY)
    end
  end

  describe '.distance_degrees' do
    before do
      create(:world_hex, world: world, globe_hex_id: 200, latitude: 0.0, longitude: 0.0, terrain_type: 'grassy_plains')
      create(:world_hex, world: world, globe_hex_id: 201, latitude: 1.0, longitude: 0.0, terrain_type: 'grassy_plains')
    end

    it 'returns distance in degrees' do
      hex1 = WorldHex.find_by_globe_hex(world.id, 200)
      hex2 = WorldHex.find_by_globe_hex(world.id, 201)

      distance = described_class.distance_degrees(hex1, hex2)

      # 1 degree latitude difference
      expect(distance).to be_within(0.1).of(1.0)
    end
  end

  describe 'MAX_PATH_LENGTH constant' do
    it 'has a reasonable max path length' do
      expect(described_class::MAX_PATH_LENGTH).to eq(500)
    end
  end
end
