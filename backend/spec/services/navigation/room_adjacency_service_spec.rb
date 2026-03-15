# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomAdjacencyService do
  describe '.edges_from_polygon' do
    it 'extracts edges from a rectangular polygon' do
      polygon = [
        { x: 0, y: 0 },
        { x: 10, y: 0 },
        { x: 10, y: 10 },
        { x: 0, y: 10 }
      ]

      edges = described_class.edges_from_polygon(polygon)

      expect(edges.length).to eq(4)
      expect(edges[0]).to eq([{ x: 0.0, y: 0.0 }, { x: 10.0, y: 0.0 }])
    end

    it 'handles string keys in polygon points' do
      polygon = [
        { 'x' => 0, 'y' => 0 },
        { 'x' => 20, 'y' => 0 },
        { 'x' => 20, 'y' => 15 },
        { 'x' => 0, 'y' => 15 }
      ]

      edges = described_class.edges_from_polygon(polygon)

      expect(edges.length).to eq(4)
      expect(edges[0]).to eq([{ x: 0.0, y: 0.0 }, { x: 20.0, y: 0.0 }])
      expect(edges[1]).to eq([{ x: 20.0, y: 0.0 }, { x: 20.0, y: 15.0 }])
    end

    it 'returns empty array for nil polygon' do
      expect(described_class.edges_from_polygon(nil)).to eq([])
    end

    it 'returns empty array for polygon with fewer than 3 points' do
      expect(described_class.edges_from_polygon([{ x: 0, y: 0 }])).to eq([])
      expect(described_class.edges_from_polygon([{ x: 0, y: 0 }, { x: 10, y: 0 }])).to eq([])
    end

    it 'handles triangular polygon' do
      polygon = [
        { x: 0, y: 0 },
        { x: 10, y: 0 },
        { x: 5, y: 10 }
      ]

      edges = described_class.edges_from_polygon(polygon)

      expect(edges.length).to eq(3)
      expect(edges[0]).to eq([{ x: 0.0, y: 0.0 }, { x: 10.0, y: 0.0 }])
      expect(edges[1]).to eq([{ x: 10.0, y: 0.0 }, { x: 5.0, y: 10.0 }])
      expect(edges[2]).to eq([{ x: 5.0, y: 10.0 }, { x: 0.0, y: 0.0 }])
    end

    it 'closes the polygon (last edge connects back to first point)' do
      polygon = [
        { x: 0, y: 0 },
        { x: 10, y: 0 },
        { x: 10, y: 10 },
        { x: 0, y: 10 }
      ]

      edges = described_class.edges_from_polygon(polygon)

      # Last edge should connect back to first point
      expect(edges[3]).to eq([{ x: 0.0, y: 10.0 }, { x: 0.0, y: 0.0 }])
    end
  end

  describe '.edges_overlap?' do
    it 'returns true for collinear overlapping horizontal edges' do
      edge_a = [{ x: 0, y: 10 }, { x: 20, y: 10 }]
      edge_b = [{ x: 10, y: 10 }, { x: 30, y: 10 }]

      expect(described_class.edges_overlap?(edge_a, edge_b, tolerance: 2)).to be true
    end

    it 'returns true for edges within tolerance' do
      edge_a = [{ x: 0, y: 10 }, { x: 20, y: 10 }]
      edge_b = [{ x: 10, y: 11 }, { x: 30, y: 11 }]  # 1 foot apart

      expect(described_class.edges_overlap?(edge_a, edge_b, tolerance: 2)).to be true
    end

    it 'returns false for non-overlapping edges' do
      edge_a = [{ x: 0, y: 10 }, { x: 5, y: 10 }]
      edge_b = [{ x: 10, y: 10 }, { x: 20, y: 10 }]

      expect(described_class.edges_overlap?(edge_a, edge_b, tolerance: 2)).to be false
    end

    it 'returns false for perpendicular edges' do
      edge_a = [{ x: 0, y: 0 }, { x: 10, y: 0 }]   # horizontal
      edge_b = [{ x: 5, y: 0 }, { x: 5, y: 10 }]   # vertical

      expect(described_class.edges_overlap?(edge_a, edge_b, tolerance: 2)).to be false
    end

    it 'returns true for collinear overlapping vertical edges' do
      edge_a = [{ x: 10, y: 0 }, { x: 10, y: 20 }]
      edge_b = [{ x: 10, y: 15 }, { x: 10, y: 35 }]

      expect(described_class.edges_overlap?(edge_a, edge_b, tolerance: 2)).to be true
    end

    it 'returns false for parallel but too far apart edges' do
      edge_a = [{ x: 0, y: 10 }, { x: 20, y: 10 }]
      edge_b = [{ x: 0, y: 15 }, { x: 20, y: 15 }]  # 5 feet apart

      expect(described_class.edges_overlap?(edge_a, edge_b, tolerance: 2)).to be false
    end

    it 'returns false for edges that only touch at a single point (no significant overlap)' do
      # Two edges that are end-to-end (touching at one point) should not be considered overlapping
      # for navigation purposes - you can't walk through a corner
      edge_a = [{ x: 0, y: 10 }, { x: 10, y: 10 }]
      edge_b = [{ x: 10, y: 10 }, { x: 20, y: 10 }]

      expect(described_class.edges_overlap?(edge_a, edge_b, tolerance: 2)).to be false
    end

    it 'handles edges with reversed point order' do
      edge_a = [{ x: 20, y: 10 }, { x: 0, y: 10 }]   # reversed
      edge_b = [{ x: 10, y: 10 }, { x: 30, y: 10 }]

      expect(described_class.edges_overlap?(edge_a, edge_b, tolerance: 2)).to be true
    end

    it 'returns true for diagonal overlapping edges' do
      edge_a = [{ x: 0, y: 0 }, { x: 10, y: 10 }]
      edge_b = [{ x: 5, y: 5 }, { x: 15, y: 15 }]

      expect(described_class.edges_overlap?(edge_a, edge_b, tolerance: 2)).to be true
    end

    it 'returns false for diagonal non-collinear edges' do
      edge_a = [{ x: 0, y: 0 }, { x: 10, y: 10 }]
      edge_b = [{ x: 0, y: 10 }, { x: 10, y: 0 }]   # crossing diagonal

      expect(described_class.edges_overlap?(edge_a, edge_b, tolerance: 2)).to be false
    end

    it 'uses default tolerance when not specified' do
      edge_a = [{ x: 0, y: 10 }, { x: 20, y: 10 }]
      edge_b = [{ x: 10, y: 11.5 }, { x: 30, y: 11.5 }]  # 1.5 feet apart (within default 2.0)

      expect(described_class.edges_overlap?(edge_a, edge_b)).to be true
    end
  end

  describe '.direction_of_edge' do
    let(:room) do
      create(:room, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
    end

    it 'returns north for edge on north side' do
      edge = [{ x: 0, y: 100 }, { x: 100, y: 100 }]
      expect(described_class.direction_of_edge(room, edge)).to eq(:north)
    end

    it 'returns south for edge on south side' do
      edge = [{ x: 0, y: 0 }, { x: 100, y: 0 }]
      expect(described_class.direction_of_edge(room, edge)).to eq(:south)
    end

    it 'returns east for edge on east side' do
      edge = [{ x: 100, y: 0 }, { x: 100, y: 100 }]
      expect(described_class.direction_of_edge(room, edge)).to eq(:east)
    end

    it 'returns west for edge on west side' do
      edge = [{ x: 0, y: 0 }, { x: 0, y: 100 }]
      expect(described_class.direction_of_edge(room, edge)).to eq(:west)
    end

    it 'returns northeast for edge in northeast corner' do
      edge = [{ x: 80, y: 80 }, { x: 100, y: 100 }]
      expect(described_class.direction_of_edge(room, edge)).to eq(:northeast)
    end

    it 'returns southeast for edge in southeast corner' do
      edge = [{ x: 80, y: 0 }, { x: 100, y: 20 }]
      expect(described_class.direction_of_edge(room, edge)).to eq(:southeast)
    end

    it 'returns northwest for edge in northwest corner' do
      edge = [{ x: 0, y: 80 }, { x: 20, y: 100 }]
      expect(described_class.direction_of_edge(room, edge)).to eq(:northwest)
    end

    it 'returns southwest for edge in southwest corner' do
      edge = [{ x: 0, y: 0 }, { x: 20, y: 20 }]
      expect(described_class.direction_of_edge(room, edge)).to eq(:southwest)
    end

    context 'with asymmetric room' do
      let(:wide_room) do
        create(:room, min_x: 0, max_x: 200, min_y: 0, max_y: 50)
      end

      it 'correctly identifies north edge on wide room' do
        edge = [{ x: 50, y: 50 }, { x: 150, y: 50 }]
        expect(described_class.direction_of_edge(wide_room, edge)).to eq(:north)
      end

      it 'correctly identifies east edge on wide room' do
        edge = [{ x: 200, y: 10 }, { x: 200, y: 40 }]
        expect(described_class.direction_of_edge(wide_room, edge)).to eq(:east)
      end
    end

    context 'with offset room (not at origin)' do
      let(:offset_room) do
        create(:room, min_x: 100, max_x: 200, min_y: 100, max_y: 200)
      end

      it 'correctly identifies directions relative to room center' do
        # North edge at y=200
        north_edge = [{ x: 100, y: 200 }, { x: 200, y: 200 }]
        expect(described_class.direction_of_edge(offset_room, north_edge)).to eq(:north)

        # South edge at y=100
        south_edge = [{ x: 100, y: 100 }, { x: 200, y: 100 }]
        expect(described_class.direction_of_edge(offset_room, south_edge)).to eq(:south)
      end
    end
  end

  describe 'ADJACENCY_TOLERANCE constant' do
    it 'is defined as 2.0 feet' do
      expect(described_class::ADJACENCY_TOLERANCE).to eq(2.0)
    end
  end

  describe 'DIRECTION_TOLERANCE constant' do
    it 'is defined as 5.0 feet' do
      expect(described_class::DIRECTION_TOLERANCE).to eq(5.0)
    end
  end

  describe '.adjacent_rooms' do
    let(:location) { create(:location) }

    it 'finds adjacent rooms by shared edges' do
      room_a = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      room_b = create(:room, location: location, min_x: 0, max_x: 100, min_y: 100, max_y: 200) # north of A

      result = described_class.adjacent_rooms(room_a)

      expect(result[:north]).to include(room_b)
    end

    it 'finds rooms in multiple directions' do
      room_a = create(:room, location: location, min_x: 100, max_x: 200, min_y: 100, max_y: 200)
      room_north = create(:room, location: location, min_x: 100, max_x: 200, min_y: 200, max_y: 300)
      room_east = create(:room, location: location, min_x: 200, max_x: 300, min_y: 100, max_y: 200)

      result = described_class.adjacent_rooms(room_a)

      expect(result[:north]).to include(room_north)
      expect(result[:east]).to include(room_east)
    end

    it 'excludes rooms in different locations' do
      other_location = create(:location)
      room_a = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      _room_other = create(:room, location: other_location, min_x: 0, max_x: 100, min_y: 100, max_y: 200)

      result = described_class.adjacent_rooms(room_a)

      expect(result[:north]).to be_empty
    end

    it 'excludes contained rooms' do
      outer = create(:room, location: location, min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      inner = create(:room, location: location, min_x: 50, max_x: 150, min_y: 50, max_y: 150)

      result = described_class.adjacent_rooms(outer)

      expect(result.values.flatten).not_to include(inner)
    end

    it 'handles fuzzy adjacency within tolerance' do
      room_a = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      room_b = create(:room, location: location, min_x: 0, max_x: 100, min_y: 101, max_y: 200) # 1ft gap

      result = described_class.adjacent_rooms(room_a)

      expect(result[:north]).to include(room_b)
    end

    it 'excludes non-adjacent rooms' do
      room_a = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      room_far = create(:room, location: location, min_x: 0, max_x: 100, min_y: 200, max_y: 300) # 100ft gap

      result = described_class.adjacent_rooms(room_a)

      expect(result.values.flatten).not_to include(room_far)
    end

    it 'returns empty hash when no adjacent rooms exist' do
      room_a = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)

      result = described_class.adjacent_rooms(room_a)

      expect(result.values.flatten).to be_empty
    end

    it 'handles rooms adjacent on all four sides' do
      room_center = create(:room, location: location, min_x: 100, max_x: 200, min_y: 100, max_y: 200)
      room_north = create(:room, location: location, min_x: 100, max_x: 200, min_y: 200, max_y: 300)
      room_south = create(:room, location: location, min_x: 100, max_x: 200, min_y: 0, max_y: 100)
      room_east = create(:room, location: location, min_x: 200, max_x: 300, min_y: 100, max_y: 200)
      room_west = create(:room, location: location, min_x: 0, max_x: 100, min_y: 100, max_y: 200)

      result = described_class.adjacent_rooms(room_center)

      expect(result[:north]).to include(room_north)
      expect(result[:south]).to include(room_south)
      expect(result[:east]).to include(room_east)
      expect(result[:west]).to include(room_west)
    end
  end

  describe '.room_contains?' do
    let(:location) { create(:location) }

    it 'returns true when outer fully contains inner' do
      outer = create(:room, location: location, min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      inner = create(:room, location: location, min_x: 50, max_x: 150, min_y: 50, max_y: 150)

      expect(described_class.room_contains?(outer, inner)).to be true
    end

    it 'returns false when rooms only partially overlap' do
      room_a = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      room_b = create(:room, location: location, min_x: 50, max_x: 150, min_y: 50, max_y: 150)

      expect(described_class.room_contains?(room_a, room_b)).to be false
    end

    it 'returns false when rooms are adjacent but not overlapping' do
      room_a = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      room_b = create(:room, location: location, min_x: 0, max_x: 100, min_y: 100, max_y: 200)

      expect(described_class.room_contains?(room_a, room_b)).to be false
    end

    it 'returns false when inner is larger than outer' do
      outer = create(:room, location: location, min_x: 50, max_x: 150, min_y: 50, max_y: 150)
      inner = create(:room, location: location, min_x: 0, max_x: 200, min_y: 0, max_y: 200)

      expect(described_class.room_contains?(outer, inner)).to be false
    end

    it 'returns true when inner touches outer boundary from inside' do
      outer = create(:room, location: location, min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      inner = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100) # corner-aligned

      expect(described_class.room_contains?(outer, inner)).to be true
    end
  end

  describe '.contained_rooms' do
    let(:location) { create(:location) }

    it 'finds rooms inside the given room' do
      outer = create(:room, location: location, min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      inner = create(:room, location: location, min_x: 50, max_x: 150, min_y: 50, max_y: 150)

      result = described_class.contained_rooms(outer)

      expect(result).to include(inner)
    end

    it 'excludes rooms not fully inside' do
      room_a = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      room_b = create(:room, location: location, min_x: 50, max_x: 150, min_y: 50, max_y: 150) # overlaps but not contained

      result = described_class.contained_rooms(room_a)

      expect(result).not_to include(room_b)
    end

    it 'excludes the room itself' do
      room = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)

      result = described_class.contained_rooms(room)

      expect(result).not_to include(room)
    end

    it 'excludes rooms from other locations' do
      other_location = create(:location)
      outer = create(:room, location: location, min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      _inner_other = create(:room, location: other_location, min_x: 50, max_x: 150, min_y: 50, max_y: 150)

      result = described_class.contained_rooms(outer)

      expect(result).to be_empty
    end

    it 'returns empty array when no rooms are contained' do
      room = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)

      result = described_class.contained_rooms(room)

      expect(result).to eq([])
    end

    it 'finds multiple contained rooms' do
      outer = create(:room, location: location, min_x: 0, max_x: 300, min_y: 0, max_y: 300)
      inner1 = create(:room, location: location, min_x: 10, max_x: 90, min_y: 10, max_y: 90)
      inner2 = create(:room, location: location, min_x: 110, max_x: 190, min_y: 110, max_y: 190)

      result = described_class.contained_rooms(outer)

      expect(result).to include(inner1)
      expect(result).to include(inner2)
    end
  end

  describe '.containing_room' do
    let(:location) { create(:location) }

    it 'finds the smallest room containing the given room' do
      outer = create(:room, location: location, min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      inner = create(:room, location: location, min_x: 50, max_x: 150, min_y: 50, max_y: 150)

      result = described_class.containing_room(inner)

      expect(result).to eq(outer)
    end

    it 'returns nil when no containing room exists' do
      room = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)

      result = described_class.containing_room(room)

      expect(result).to be_nil
    end

    it 'returns the smallest container when multiple exist' do
      largest = create(:room, location: location, min_x: 0, max_x: 300, min_y: 0, max_y: 300)
      medium = create(:room, location: location, min_x: 25, max_x: 275, min_y: 25, max_y: 275)
      smallest = create(:room, location: location, min_x: 50, max_x: 250, min_y: 50, max_y: 250)
      inner = create(:room, location: location, min_x: 100, max_x: 200, min_y: 100, max_y: 200)

      result = described_class.containing_room(inner)

      expect(result).to eq(smallest)
    end

    it 'excludes the room itself' do
      room = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)

      result = described_class.containing_room(room)

      expect(result).to be_nil
    end

    it 'excludes rooms from other locations' do
      other_location = create(:location)
      outer = create(:room, location: other_location, min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      inner = create(:room, location: location, min_x: 50, max_x: 150, min_y: 50, max_y: 150)

      result = described_class.containing_room(inner)

      expect(result).to be_nil
      expect(result).not_to eq(outer)
    end
  end

  describe '.resolve_direction_movement' do
    let(:location) { create(:location) }

    it 'returns adjacent room when passable' do
      room_a = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      room_b = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 100, max_y: 200)

      result = described_class.resolve_direction_movement(room_a, :north)

      expect(result).to eq(room_b)
    end

    it 'returns nil when adjacent room is not passable' do
      room_a = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      room_b = create(:room, location: location, indoors: true, min_x: 0, max_x: 100, min_y: 100, max_y: 200)
      create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')

      result = described_class.resolve_direction_movement(room_a, :north)

      expect(result).to be_nil
    end

    it 'exits to containing room when opening exists but no adjacent room' do
      outer = create(:room, location: location, indoors: false, min_x: 0, max_x: 300, min_y: 0, max_y: 300)
      inner = create(:room, location: location, indoors: true, min_x: 100, max_x: 200, min_y: 100, max_y: 200)
      create(:room_feature, room: inner, feature_type: 'wall', direction: 'north')
      create(:room_feature, room: inner, feature_type: 'door', direction: 'north', is_open: true)

      result = described_class.resolve_direction_movement(inner, :north)

      expect(result).to eq(outer)
    end

    it 'accepts string direction' do
      room_a = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      room_b = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 100, max_y: 200)

      result = described_class.resolve_direction_movement(room_a, 'north')

      expect(result).to eq(room_b)
    end

    it 'returns nil when no adjacent room and no containing room' do
      room = create(:room, location: location, indoors: false, min_x: 0, max_x: 100, min_y: 0, max_y: 100)

      result = described_class.resolve_direction_movement(room, :north)

      expect(result).to be_nil
    end

    it 'returns nil when door to container is closed' do
      outer = create(:room, location: location, indoors: false, min_x: 0, max_x: 300, min_y: 0, max_y: 300)
      inner = create(:room, location: location, indoors: true, min_x: 100, max_x: 200, min_y: 100, max_y: 200)
      create(:room_feature, room: inner, feature_type: 'wall', direction: 'north')
      create(:room_feature, room: inner, feature_type: 'door', direction: 'north', is_open: false)

      result = described_class.resolve_direction_movement(inner, :north)

      expect(result).to be_nil
    end

    it 'only allows outdoor entry through building edges with passable openings' do
      street_west = create(:room, location: location, room_type: 'street', indoors: false,
                                  min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      street_north = create(:room, location: location, room_type: 'street', indoors: false,
                                   min_x: 100, max_x: 200, min_y: 100, max_y: 200)
      building = create(:room, location: location, name: 'Corner Shop', city_role: 'building', indoors: true,
                               min_x: 100, max_x: 200, min_y: 0, max_y: 100)

      %w[north south east west].each do |dir|
        create(:room_feature, room: building, feature_type: 'wall', direction: dir)
      end
      create(:room_feature, room: building, feature_type: 'door', direction: 'west', is_open: true)

      # Entry should work only from the side that has the open door.
      expect(described_class.resolve_direction_movement(street_west, :east)).to eq(building)
      expect(described_class.resolve_direction_movement(street_north, :south)).to be_nil

      # Once inside, leaving should remain consistent with that same door edge.
      expect(described_class.resolve_direction_movement(building, :west)).to eq(street_west)
      expect(described_class.resolve_direction_movement(building, :north)).to be_nil
    end
  end

  describe '.resolve_named_movement' do
    let(:location) { create(:location) }

    it 'finds contained room by name' do
      outer = create(:room, location: location, name: 'Lobby', min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      inner = create(:room, location: location, name: 'Coffee Shop', min_x: 50, max_x: 150, min_y: 50, max_y: 150)

      result = described_class.resolve_named_movement(outer, 'coffee')

      expect(result).to eq(inner)
    end

    it 'finds adjacent room by name' do
      room_a = create(:room, location: location, name: 'Hallway', min_x: 0, max_x: 100, min_y: 0, max_y: 100, indoors: false)
      room_b = create(:room, location: location, name: 'Kitchen', min_x: 0, max_x: 100, min_y: 100, max_y: 200, indoors: false)

      result = described_class.resolve_named_movement(room_a, 'kitchen')

      expect(result).to eq(room_b)
    end

    it 'returns nil when no matching room' do
      room = create(:room, location: location, name: 'Lobby', min_x: 0, max_x: 100, min_y: 0, max_y: 100)

      result = described_class.resolve_named_movement(room, 'nonexistent')

      expect(result).to be_nil
    end

    it 'is case insensitive' do
      outer = create(:room, location: location, name: 'Lobby', min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      inner = create(:room, location: location, name: 'Coffee Shop', min_x: 50, max_x: 150, min_y: 50, max_y: 150)

      result = described_class.resolve_named_movement(outer, 'COFFEE')

      expect(result).to eq(inner)
    end

    it 'prefers contained rooms over adjacent rooms with same name' do
      outer = create(:room, location: location, name: 'Lobby', min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      inner = create(:room, location: location, name: 'Cafe Inside', min_x: 50, max_x: 150, min_y: 50, max_y: 150)
      adjacent = create(:room, location: location, name: 'Cafe Adjacent', min_x: 200, max_x: 300, min_y: 0, max_y: 200, indoors: false)

      result = described_class.resolve_named_movement(outer, 'cafe')

      expect(result).to eq(inner)
    end

    it 'does not return impassable adjacent rooms' do
      room_a = create(:room, location: location, name: 'Hallway', min_x: 0, max_x: 100, min_y: 0, max_y: 100, indoors: true)
      room_b = create(:room, location: location, name: 'Kitchen', min_x: 0, max_x: 100, min_y: 100, max_y: 200, indoors: true)
      create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north')

      result = described_class.resolve_named_movement(room_a, 'kitchen')

      expect(result).to be_nil
    end
  end

  describe '.direction_to_room' do
    let(:location) { create(:location) }

    it 'returns direction to adjacent room' do
      room_a = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      room_b = create(:room, location: location, min_x: 0, max_x: 100, min_y: 100, max_y: 200)

      result = described_class.direction_to_room(room_a, room_b)

      expect(result).to eq(:north)
    end

    it 'returns nil for non-adjacent room' do
      room_a = create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      room_b = create(:room, location: location, min_x: 0, max_x: 100, min_y: 200, max_y: 300) # not adjacent

      result = described_class.direction_to_room(room_a, room_b)

      expect(result).to be_nil
    end

    it 'returns nil for contained room' do
      outer = create(:room, location: location, min_x: 0, max_x: 200, min_y: 0, max_y: 200)
      inner = create(:room, location: location, min_x: 50, max_x: 150, min_y: 50, max_y: 150)

      result = described_class.direction_to_room(outer, inner)

      expect(result).to be_nil
    end

    it 'returns correct direction for each cardinal direction' do
      center = create(:room, location: location, min_x: 100, max_x: 200, min_y: 100, max_y: 200)
      north = create(:room, location: location, min_x: 100, max_x: 200, min_y: 200, max_y: 300)
      south = create(:room, location: location, min_x: 100, max_x: 200, min_y: 0, max_y: 100)
      east = create(:room, location: location, min_x: 200, max_x: 300, min_y: 100, max_y: 200)
      west = create(:room, location: location, min_x: 0, max_x: 100, min_y: 100, max_y: 200)

      expect(described_class.direction_to_room(center, north)).to eq(:north)
      expect(described_class.direction_to_room(center, south)).to eq(:south)
      expect(described_class.direction_to_room(center, east)).to eq(:east)
      expect(described_class.direction_to_room(center, west)).to eq(:west)
    end
  end

  describe 'street and intersection navigation' do
    let(:location) { create(:location) }

    # Simulate a unified city grid:
    # - Street spans full width (0..525, 0..25)
    # - Intersections are 25x25 overlaid on the street
    # - Avenue spans full height (0..25, 0..525)
    let(:street) do
      create(:room, location: location, name: 'Main Street',
             room_type: 'street', city_role: 'street',
             min_x: 0, max_x: 525, min_y: 0, max_y: 25, indoors: false)
    end

    let(:intersection) do
      create(:room, location: location, name: 'Main Street & 1st Avenue',
             room_type: 'intersection', city_role: 'intersection',
             min_x: 0, max_x: 25, min_y: 0, max_y: 25, indoors: false)
    end

    let(:avenue) do
      create(:room, location: location, name: '1st Avenue',
             room_type: 'avenue', city_role: 'avenue',
             min_x: 0, max_x: 25, min_y: 0, max_y: 525, indoors: false)
    end

    it 'treats intersection as contained within the street' do
      street
      intersection
      expect(described_class.room_contains?(street, intersection)).to be true
    end

    it 'finds intersection as adjacent to street despite containment' do
      street
      intersection
      adjacent = described_class.compute_adjacent_rooms(street)
      all_adjacent = adjacent.values.flatten.uniq
      expect(all_adjacent).to include(intersection)
    end

    it 'finds street as adjacent to intersection despite containment' do
      street
      intersection
      adjacent = described_class.compute_adjacent_rooms(intersection)
      all_adjacent = adjacent.values.flatten.uniq
      expect(all_adjacent).to include(street)
    end

    it 'allows movement from intersection to street' do
      street
      intersection
      # Intersection is at the west end of the street, so moving east should reach the street
      result = described_class.resolve_direction_movement(intersection, :east)
      expect(result).to eq(street)
    end

    it 'allows movement from intersection to avenue' do
      avenue
      intersection
      # Intersection is at the south end of the avenue, so moving north should reach the avenue
      result = described_class.resolve_direction_movement(intersection, :north)
      expect(result).to eq(avenue)
    end

    it 'allows movement from street to intersection' do
      street
      intersection
      # Street center is east of intersection, so moving west should reach the intersection
      result = described_class.resolve_direction_movement(street, :west)
      expect(result).to eq(intersection)
    end

    it 'does not exclude outdoor contained rooms from passable exits' do
      street
      intersection
      exits = street.passable_spatial_exits
      exit_rooms = exits.map { |e| e[:room] }
      expect(exit_rooms).to include(intersection)
    end
  end

  describe 'spatial group isolation' do
    let(:location) { create(:location) }

    # Two rooms sharing a wall at x=30
    let(:room_a) do
      create(:room, location: location, name: 'Room A',
             min_x: 0, max_x: 30, min_y: 0, max_y: 30)
    end
    let(:room_b) do
      create(:room, location: location, name: 'Room B',
             min_x: 30, max_x: 60, min_y: 0, max_y: 30)
    end

    it 'treats NULL group rooms as adjacent (normal world rooms)' do
      room_a
      room_b
      adjacent = described_class.compute_adjacent_rooms(room_a)
      all_adjacent = adjacent.values.flatten
      expect(all_adjacent).to include(room_b)
    end

    it 'treats rooms with the same spatial_group_id as adjacent' do
      room_a.update(spatial_group_id: 'delve:1')
      room_b.update(spatial_group_id: 'delve:1')
      adjacent = described_class.compute_adjacent_rooms(room_a)
      all_adjacent = adjacent.values.flatten
      expect(all_adjacent).to include(room_b)
    end

    it 'does NOT treat rooms with different spatial_group_ids as adjacent' do
      room_a.update(spatial_group_id: 'delve:1')
      room_b.update(spatial_group_id: 'delve:2')
      adjacent = described_class.compute_adjacent_rooms(room_a)
      all_adjacent = adjacent.values.flatten
      expect(all_adjacent).not_to include(room_b)
    end

    it 'does NOT treat NULL group and non-null group rooms as adjacent' do
      room_b.update(spatial_group_id: 'delve:1')
      adjacent = described_class.compute_adjacent_rooms(room_a)
      all_adjacent = adjacent.values.flatten
      expect(all_adjacent).not_to include(room_b)
    end

    it 'excludes available pool rooms from adjacency' do
      room_b.update(pool_status: 'available')
      adjacent = described_class.compute_adjacent_rooms(room_a)
      all_adjacent = adjacent.values.flatten
      expect(all_adjacent).not_to include(room_b)
    end

    it 'isolates containment queries by spatial group' do
      # Room B inside Room A's bounds
      inner = create(:room, location: location, name: 'Inner',
                     min_x: 5, max_x: 25, min_y: 5, max_y: 25,
                     spatial_group_id: 'delve:1')
      room_a # spatial_group_id is nil

      contained = described_class.compute_contained_rooms(room_a)
      expect(contained).not_to include(inner)
    end

    it 'isolates containing room queries by spatial group' do
      outer = create(:room, location: location, name: 'Outer',
                     min_x: -10, max_x: 110, min_y: -10, max_y: 110,
                     spatial_group_id: 'delve:1')
      room_a # spatial_group_id is nil

      containing = described_class.compute_containing_room(room_a)
      expect(containing).not_to eq(outer)
    end
  end
end
