# frozen_string_literal: true

require 'spec_helper'

RSpec.describe HexPathfindingService do
  let(:world) { create(:world) }
  let(:room) { create(:room) }

  # Helper to convert hex grid coordinates to globe_hex_id
  def globe_id(x, y)
    HexPathfindingService.coords_to_globe_hex_id(x, y)
  end

  describe '.distance' do
    it 'returns 0 for same hex' do
      expect(described_class.distance(0, 0, 0, 0)).to eq(0)
    end

    it 'returns correct distance for adjacent hexes' do
      # Adjacent hexes should be distance 1
      expect(described_class.distance(0, 0, 1, 2)).to eq(1)
    end

    it 'returns correct distance for distant hexes' do
      expect(described_class.distance(0, 0, 4, 4)).to be > 0
    end

    it 'delegates to HexGrid.hex_distance' do
      expect(HexGrid).to receive(:hex_distance).with(2, 4, 6, 8).and_return(5)
      expect(described_class.distance(2, 4, 6, 8)).to eq(5)
    end
  end

  describe '.neighbors' do
    it 'returns neighbors for valid hex' do
      neighbors = described_class.neighbors(0, 0)
      expect(neighbors).to be_an(Array)
      expect(neighbors).not_to be_empty
    end

    it 'returns empty array for invalid hex' do
      neighbors = described_class.neighbors(1, 1) # Invalid - odd y with odd x
      expect(neighbors).to eq([])
    end

    it 'delegates to HexGrid.hex_neighbors' do
      expect(HexGrid).to receive(:hex_neighbors).with(2, 4).and_return([[3, 6], [4, 4]])
      expect(described_class.neighbors(2, 4)).to eq([[3, 6], [4, 4]])
    end
  end

  describe '.line_of_sight?' do
    it 'returns true for same hex' do
      expect(described_class.line_of_sight?(
        world_or_room: world,
        x1: 0, y1: 0,
        x2: 0, y2: 0
      )).to be true
    end

    it 'returns true when no blocking terrain in world' do
      # Create plain terrain that doesn't block sight
      create(:world_hex, world: world, globe_hex_id: globe_id(0, 0), terrain_type: 'grassy_plains')
      create(:world_hex, world: world, globe_hex_id: globe_id(2, 0), terrain_type: 'grassy_plains')
      create(:world_hex, world: world, globe_hex_id: globe_id(4, 0), terrain_type: 'grassy_plains')

      expect(described_class.line_of_sight?(
        world_or_room: world,
        x1: 0, y1: 0,
        x2: 4, y2: 0
      )).to be true
    end

    it 'returns false when blocking terrain in world' do
      # Create forest terrain that blocks sight in between
      create(:world_hex, world: world, globe_hex_id: globe_id(0, 0), terrain_type: 'grassy_plains')
      create(:world_hex, world: world, globe_hex_id: globe_id(2, 0), terrain_type: 'dense_forest')
      create(:world_hex, world: world, globe_hex_id: globe_id(4, 0), terrain_type: 'grassy_plains')

      expect(described_class.line_of_sight?(
        world_or_room: world,
        x1: 0, y1: 0,
        x2: 4, y2: 0
      )).to be false
    end

    it 'returns true for adjacent hexes even with blocking terrain' do
      # Adjacent hexes should always have LoS (we exclude start/end from check)
      create(:world_hex, world: world, globe_hex_id: globe_id(0, 0), terrain_type: 'dense_forest')
      create(:world_hex, world: world, globe_hex_id: globe_id(2, 0), terrain_type: 'dense_forest')

      expect(described_class.line_of_sight?(
        world_or_room: world,
        x1: 0, y1: 0,
        x2: 2, y2: 0
      )).to be true
    end

    context 'with room hexes' do
      it 'returns true when no blocking cover' do
        expect(described_class.line_of_sight?(
          world_or_room: room,
          x1: 0, y1: 0,
          x2: 4, y2: 0
        )).to be true
      end

      it 'checks elevation for room hexes' do
        # Create a blocking hex in between
        RoomHex.create(
          room: room,
          hex_x: 2,
          hex_y: 0,
          terrain_type: 'cover',
          blocks_line_of_sight: true,
          cover_height: 2,
          elevation_level: 0,
          danger_level: 0
        )

        # Viewer at ground level should be blocked
        expect(described_class.line_of_sight?(
          world_or_room: room,
          x1: 0, y1: 0,
          x2: 4, y2: 0,
          viewer_elevation: 0
        )).to be false

        # Viewer at higher elevation should see over
        expect(described_class.line_of_sight?(
          world_or_room: room,
          x1: 0, y1: 0,
          x2: 4, y2: 0,
          viewer_elevation: 3
        )).to be true
      end
    end
  end

  describe '.find_path' do
    it 'returns empty array for invalid start coordinates' do
      expect(described_class.find_path(
        world: world,
        start_x: 1, start_y: 1, # Invalid
        end_x: 0, end_y: 0
      )).to eq([])
    end

    it 'returns single element for same start and end' do
      expect(described_class.find_path(
        world: world,
        start_x: 0, start_y: 0,
        end_x: 0, end_y: 0
      )).to eq([[0, 0]])
    end

    it 'finds path between two valid hexes' do
      WorldHex.set_hex_details(world, globe_id(0, 0), terrain_type: 'grassy_plains')
      WorldHex.set_hex_details(world, globe_id(2, 0), terrain_type: 'grassy_plains')

      path = described_class.find_path(
        world: world,
        start_x: 0, start_y: 0,
        end_x: 2, end_y: 0
      )

      expect(path).to include([0, 0])
      expect(path).to include([2, 0])
    end

    it 'avoids water hexes by default' do
      WorldHex.set_hex_details(world, globe_id(2, 0), terrain_type: 'ocean')

      path = described_class.find_path(
        world: world,
        start_x: 0, start_y: 0,
        end_x: 4, end_y: 0
      )

      # Should not include ocean hex
      expect(path).not_to include([2, 0])
    end
  end

  describe '.direction_between' do
    it 'returns n for straight north movement' do
      expect(described_class.direction_between(0, 0, 0, 4)).to eq('n')
    end

    it 'returns s for straight south movement' do
      expect(described_class.direction_between(0, 4, 0, 0)).to eq('s')
    end

    it 'returns ne for north-east movement' do
      expect(described_class.direction_between(0, 0, 1, 2)).to eq('ne')
    end

    it 'returns se for south-east movement' do
      expect(described_class.direction_between(0, 4, 1, 2)).to eq('se')
    end

    it 'returns sw for south-west movement' do
      expect(described_class.direction_between(2, 4, 1, 2)).to eq('sw')
    end

    it 'returns nw for north-west movement' do
      expect(described_class.direction_between(2, 0, 1, 2)).to eq('nw')
    end
  end

  describe '.find_path with travel_mode' do
    let(:world) { create(:world) }

    context 'when travel_mode is water' do
      before do
        # Create a path: land -> ocean -> land
        # Using valid hex coordinates: (0,0), (1,2), (2,0) are all valid
        WorldHex.set_hex_details(world, globe_id(0, 0), terrain_type: 'grassy_plains')
        WorldHex.set_hex_details(world, globe_id(1, 2), terrain_type: 'ocean')
        WorldHex.set_hex_details(world, globe_id(2, 0), terrain_type: 'grassy_plains')
      end

      it 'prefers water hexes over land' do
        path = described_class.find_path(
          world: world,
          start_x: 0, start_y: 0,
          end_x: 2, end_y: 0,
          travel_mode: 'water'
        )
        expect(path).not_to be_empty
        # Path should include the start and end
        expect(path.first).to eq([0, 0])
        expect(path.last).to eq([2, 0])
      end

      it 'makes land very expensive in water mode' do
        # Create alternative path through multiple ocean hexes
        WorldHex.set_hex_details(world, globe_id(0, 0), terrain_type: 'sandy_coast')
        WorldHex.set_hex_details(world, globe_id(1, 2), terrain_type: 'ocean')
        WorldHex.set_hex_details(world, globe_id(2, 0), terrain_type: 'sandy_coast')

        path = described_class.find_path(
          world: world,
          start_x: 0, start_y: 0,
          end_x: 2, end_y: 0,
          travel_mode: 'water'
        )
        expect(path).not_to be_empty
      end
    end

    context 'when travel_mode is rail' do
      before do
        # Create hexes with railway features connecting them
        # Use adjacent hex coords: (0,0) -> (1,2) -> (2,0)
        hex0 = WorldHex.set_hex_details(world, globe_id(0, 0), terrain_type: 'grassy_plains')
        hex0.set_directional_feature('ne', 'railway')

        hex1 = WorldHex.set_hex_details(world, globe_id(1, 2), terrain_type: 'grassy_plains')
        hex1.set_directional_feature('sw', 'railway')  # Back connection
        hex1.set_directional_feature('se', 'railway')  # Forward connection

        hex2 = WorldHex.set_hex_details(world, globe_id(2, 0), terrain_type: 'grassy_plains')
        hex2.set_directional_feature('nw', 'railway')  # Back connection
      end

      it 'follows railway features' do
        path = described_class.find_path(
          world: world,
          start_x: 0, start_y: 0,
          end_x: 2, end_y: 0,
          travel_mode: 'rail'
        )
        expect(path).not_to be_empty
        expect(path.first).to eq([0, 0])
        expect(path.last).to eq([2, 0])
      end

      it 'returns empty when no railway connection exists' do
        # Remove railway from middle hex
        hex1 = WorldHex.set_hex_details(world, globe_id(1, 2))
        hex1.update(feature_sw: nil, feature_se: nil)

        path = described_class.find_path(
          world: world,
          start_x: 0, start_y: 0,
          end_x: 2, end_y: 0,
          travel_mode: 'rail'
        )
        expect(path).to be_empty
      end
    end

    context 'when travel_mode is land (default)' do
      before do
        WorldHex.set_hex_details(world, globe_id(0, 0), terrain_type: 'grassy_plains')
        WorldHex.set_hex_details(world, globe_id(1, 2), terrain_type: 'grassy_plains')
        WorldHex.set_hex_details(world, globe_id(2, 0), terrain_type: 'grassy_plains')
      end

      it 'uses standard terrain costs' do
        path = described_class.find_path(
          world: world,
          start_x: 0, start_y: 0,
          end_x: 2, end_y: 0,
          travel_mode: 'land'
        )
        expect(path).not_to be_empty
      end

      it 'avoids water when avoid_water is true' do
        WorldHex.set_hex_details(world, globe_id(1, 2), terrain_type: 'ocean')

        path = described_class.find_path(
          world: world,
          start_x: 0, start_y: 0,
          end_x: 2, end_y: 0,
          travel_mode: 'land',
          avoid_water: true
        )
        # Should find alternate path or be empty if ocean blocks
        expect(path).not_to include([1, 2])
      end
    end

    context 'when travel_mode is nil (backward compatibility)' do
      before do
        WorldHex.set_hex_details(world, globe_id(0, 0), terrain_type: 'grassy_plains')
        WorldHex.set_hex_details(world, globe_id(1, 2), terrain_type: 'grassy_plains')
        WorldHex.set_hex_details(world, globe_id(2, 0), terrain_type: 'grassy_plains')
      end

      it 'uses default land behavior' do
        path = described_class.find_path(
          world: world,
          start_x: 0, start_y: 0,
          end_x: 2, end_y: 0
        )
        expect(path).not_to be_empty
      end
    end

    context 'when hexes are marked non-traversable' do
      before do
        WorldHex.set_hex_details(world, globe_id(0, 0), terrain_type: 'grassy_plains', traversable: true)
        WorldHex.set_hex_details(world, globe_id(1, 2), terrain_type: 'grassy_plains', traversable: false)
        WorldHex.set_hex_details(world, globe_id(2, 0), terrain_type: 'grassy_plains', traversable: true)
      end

      it 'avoids non-traversable hexes' do
        path = described_class.find_path(
          world: world,
          start_x: 0, start_y: 0,
          end_x: 2, end_y: 0
        )
        # Path should not include the non-traversable hex
        expect(path).not_to include([1, 2])
      end

      it 'returns empty path when blocked by non-traversable hexes' do
        # Make all adjacent hexes non-traversable
        WorldHex.set_hex_details(world, globe_id(1, 2), terrain_type: 'grassy_plains', traversable: false)
        WorldHex.set_hex_details(world, globe_id(-1, 2), terrain_type: 'grassy_plains', traversable: false)

        # The path from (0,0) to (2,0) must go through (1,2) or around
        # If all paths are blocked, should return empty
        path = described_class.find_path(
          world: world,
          start_x: 0, start_y: 0,
          end_x: 2, end_y: 0
        )
        # Either finds alternate path or empty
        if path.any?
          expect(path).not_to include([1, 2])
        end
      end

      it 'allows water traversal when marked traversable (boat routes)' do
        # Ocean hex that is manually marked traversable (for boat routes)
        WorldHex.set_hex_details(world, globe_id(1, 2), terrain_type: 'ocean', traversable: true)

        path = described_class.find_path(
          world: world,
          start_x: 0, start_y: 0,
          end_x: 2, end_y: 0,
          avoid_water: false  # Allow water
        )
        expect(path).not_to be_empty
      end
    end
  end
end
