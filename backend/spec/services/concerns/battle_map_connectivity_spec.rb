# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BattleMapConnectivity do
  let(:test_class) do
    Class.new do
      include BattleMapConnectivity
    end
  end

  let(:service) { test_class.new }

  # Helper to build a traversable hex hash
  def hex(x, y, traversable: true, hex_type: 'normal')
    { x: x, y: y, hex_type: hex_type, traversable: traversable }
  end

  describe '#ensure_traversable_connectivity' do
    context 'with empty hex_data' do
      it 'returns unchanged' do
        result = service.ensure_traversable_connectivity([])
        expect(result).to eq([])
      end
    end

    context 'with no traversable hexes' do
      it 'returns unchanged' do
        data = [
          hex(0, 0, traversable: false, hex_type: 'wall'),
          hex(2, 0, traversable: false, hex_type: 'wall')
        ]
        result = service.ensure_traversable_connectivity(data)
        expect(result).to eq(data)
      end
    end

    context 'with a single traversable hex' do
      it 'returns unchanged (< 2 traversable)' do
        data = [
          hex(0, 0),
          hex(2, 0, traversable: false, hex_type: 'wall')
        ]
        result = service.ensure_traversable_connectivity(data)
        expect(result).to eq(data)
      end
    end

    context 'with all traversable hexes connected' do
      it 'returns unchanged' do
        # A line of connected hexes: (0,0) -> (1,2) -> (0,4)
        data = [
          hex(0, 0),
          hex(1, 2),
          hex(0, 4)
        ]
        result = service.ensure_traversable_connectivity(data)
        expect(result.select { |h| h[:traversable] }.size).to eq(3)
        expect(result.none? { |h| h[:hex_type] == 'wall' }).to be true
      end
    end

    context 'with an isolated pocket' do
      it 'converts isolated traversable hexes to walls' do
        # Connected cluster near center: (0,0), (1,2), (0,4)
        # Isolated hex far away: (10,0)
        data = [
          hex(0, 0),
          hex(1, 2),
          hex(0, 4),
          hex(10, 0)  # isolated - no neighbor connections
        ]
        result = service.ensure_traversable_connectivity(data)

        # The 3 connected hexes should remain traversable
        connected = result.select { |h| h[:traversable] }
        expect(connected.size).to eq(3)

        # The isolated hex should be converted to wall
        isolated = result.find { |h| h[:x] == 10 && h[:y] == 0 }
        expect(isolated[:hex_type]).to eq('wall')
        expect(isolated[:traversable]).to be false
      end

      it 'preserves non-traversable hexes unchanged' do
        data = [
          hex(0, 0),
          hex(1, 2),
          hex(2, 0, traversable: false, hex_type: 'cover'),  # already non-traversable
          hex(10, 0)  # isolated traversable
        ]
        result = service.ensure_traversable_connectivity(data)

        cover_hex = result.find { |h| h[:x] == 2 && h[:y] == 0 }
        expect(cover_hex[:hex_type]).to eq('cover')
        expect(cover_hex[:traversable]).to be false
      end
    end

    context 'with multiple isolated pockets' do
      it 'converts all isolated pockets to walls' do
        # Main cluster near center: (4,0), (5,2), (4,4), (5,6)
        # Isolated pocket 1 at far left: (0,16)
        # Isolated pocket 2 at far right: (10,16)
        data = [
          hex(4, 0),
          hex(5, 2),
          hex(4, 4),
          hex(5, 6),
          hex(0, 16),
          hex(10, 16)
        ]
        result = service.ensure_traversable_connectivity(data)

        connected = result.select { |h| h[:traversable] }
        walls = result.select { |h| h[:hex_type] == 'wall' }

        expect(connected.size).to eq(4)
        expect(walls.size).to eq(2)
      end
    end

    context 'error handling' do
      it 'rescues errors and returns hex_data unchanged' do
        data = [hex(0, 0), hex(1, 2)]
        allow(HexGrid).to receive(:to_hex_coords).and_raise(StandardError, 'test error')

        result = service.ensure_traversable_connectivity(data)
        expect(result).to eq(data)
      end
    end
  end

  describe '#ensure_traversable_connectivity_in_db' do
    let(:location) { create(:location) }
    let(:room) do
      create(:room,
             location: location,
             min_x: 0, min_y: 0, max_x: 40, max_y: 40)
    end

    before do
      # Clear any auto-generated hexes
      room.room_hexes_dataset.delete
    end

    context 'with fewer than 2 traversable hexes' do
      it 'does nothing' do
        RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'normal', traversable: true, danger_level: 0)
        expect { service.ensure_traversable_connectivity_in_db(room) }.not_to(
          change { room.room_hexes_dataset.where(traversable: false).count }
        )
      end
    end

    context 'with all connected traversable hexes' do
      it 'does not modify any hexes' do
        RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'normal', traversable: true, danger_level: 0)
        RoomHex.create(room_id: room.id, hex_x: 1, hex_y: 2, hex_type: 'normal', traversable: true, danger_level: 0)
        RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 4, hex_type: 'normal', traversable: true, danger_level: 0)

        expect { service.ensure_traversable_connectivity_in_db(room) }.not_to(
          change { room.room_hexes_dataset.where(hex_type: 'wall').count }
        )
      end
    end

    context 'with isolated hexes' do
      it 'converts isolated traversable hexes to walls in the database' do
        # Connected cluster
        RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'normal', traversable: true, danger_level: 0)
        RoomHex.create(room_id: room.id, hex_x: 1, hex_y: 2, hex_type: 'normal', traversable: true, danger_level: 0)
        # Isolated hex
        RoomHex.create(room_id: room.id, hex_x: 10, hex_y: 0, hex_type: 'normal', traversable: true, danger_level: 0)

        service.ensure_traversable_connectivity_in_db(room)

        isolated = room.room_hexes_dataset.where(hex_x: 10, hex_y: 0).first
        expect(isolated.hex_type).to eq('wall')
        expect(isolated.traversable).to be false

        # Connected hexes should be unchanged
        connected = room.room_hexes_dataset.where(hex_x: 0, hex_y: 0).first
        expect(connected.hex_type).to eq('normal')
        expect(connected.traversable).to be true
      end
    end

    context 'error handling' do
      it 'rescues errors without raising' do
        allow(room).to receive(:room_hexes_dataset).and_raise(StandardError, 'db error')

        expect { service.ensure_traversable_connectivity_in_db(room) }.not_to raise_error
      end
    end
  end

  describe '#crop_non_traversable_border' do
    context 'with empty hex data' do
      it 'returns unchanged' do
        result = service.crop_non_traversable_border([])
        expect(result).to eq([])
      end
    end

    context 'with no traversable hexes' do
      it 'returns unchanged' do
        data = [
          hex(0, 0, traversable: false, hex_type: 'wall'),
          hex(2, 0, traversable: false, hex_type: 'wall')
        ]
        result = service.crop_non_traversable_border(data)
        expect(result).to eq(data)
      end
    end

    context 'with all traversable hexes (no border to crop)' do
      it 'returns unchanged' do
        data = [
          hex(0, 0),
          hex(1, 2),
          hex(0, 4)
        ]
        result = service.crop_non_traversable_border(data)
        expect(result.size).to eq(3)
      end
    end

    context 'with far-away non-traversable hexes' do
      it 'removes walls far from traversable area' do
        # Traversable cluster at (2,0), (3,2)
        # Nearby wall (neighbor of traversable) at (2,4) - should be kept
        # Far-away wall at (20,0) - should be removed
        data = [
          hex(2, 0),
          hex(3, 2),
          hex(2, 4, traversable: false, hex_type: 'wall'),
          hex(20, 0, traversable: false, hex_type: 'wall')
        ]
        result = service.crop_non_traversable_border(data)

        coords = result.map { |h| [h[:x], h[:y]] }
        # The far-away wall should be gone (after remapping)
        expect(result.size).to eq(3)
      end

      it 'keeps walls that are neighbors of traversable hexes' do
        # Traversable hex at (2,0)
        # Wall at (3,2) is a neighbor of (2,0) - should be kept
        data = [
          hex(2, 0),
          hex(1, 2),
          hex(3, 2, traversable: false, hex_type: 'wall')
        ]
        result = service.crop_non_traversable_border(data)
        expect(result.size).to eq(3)
      end
    end

    context 'coordinate remapping' do
      it 'remaps coordinates to start at (0,0)' do
        # Traversable hexes starting at (4,4), plus a far-away wall to trigger cropping
        data = [
          hex(4, 4),
          hex(5, 6),
          hex(4, 8),
          hex(20, 0, traversable: false, hex_type: 'wall')
        ]
        result = service.crop_non_traversable_border(data)

        min_x = result.map { |h| h[:x] }.min
        min_y = result.map { |h| h[:y] }.min
        expect(min_x).to eq(0)
        expect(min_y).to eq(0)
      end

      it 'preserves relative positions after remapping' do
        data = [
          hex(4, 4),
          hex(5, 6),
          hex(4, 8),
          hex(20, 0, traversable: false, hex_type: 'wall')
        ]
        result = service.crop_non_traversable_border(data)

        # The far-away wall gets removed, remaining hexes shift by (-min_x, -min_y)
        # Traversable hexes: (4,4), (5,6), (4,8) + their neighbors form the keep set
        # After shift, relative positions should be preserved
        traversable_result = result.select { |h| h[:traversable] }
        xs = traversable_result.map { |h| h[:x] }
        ys = traversable_result.map { |h| h[:y] }
        # Check relative distances are preserved
        expect(xs.max - xs.min).to eq(1)  # was 5-4=1
        expect(ys.max - ys.min).to eq(4)  # was 8-4=4
      end
    end

    context 'error handling' do
      it 'rescues errors and returns hex_data unchanged' do
        data = [hex(0, 0), hex(1, 2)]
        allow(HexGrid).to receive(:hex_neighbors).and_raise(StandardError, 'test error')

        result = service.crop_non_traversable_border(data)
        expect(result).to eq(data)
      end
    end
  end

  describe '#crop_non_traversable_border_in_db' do
    let(:location) { create(:location) }
    let(:room) do
      create(:room,
             location: location,
             min_x: 0, min_y: 0, max_x: 100, max_y: 100)
    end

    before do
      room.room_hexes_dataset.delete
    end

    context 'with fewer than 2 hexes' do
      it 'does nothing' do
        RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'normal', traversable: true, danger_level: 0)
        expect { service.crop_non_traversable_border_in_db(room) }.not_to(
          change { room.room_hexes_dataset.count }
        )
      end
    end

    context 'with isolated border hexes' do
      it 'deletes non-traversable hexes far from traversable area' do
        # Traversable cluster at (0,0) and (1,2)
        RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'normal', traversable: true, danger_level: 0)
        RoomHex.create(room_id: room.id, hex_x: 1, hex_y: 2, hex_type: 'normal', traversable: true, danger_level: 0)
        # Far-away wall at (14,0) - well beyond neighbor range
        RoomHex.create(room_id: room.id, hex_x: 14, hex_y: 0, hex_type: 'wall', traversable: false, danger_level: 0)

        service.crop_non_traversable_border_in_db(room)

        expect(room.room_hexes_dataset.count).to eq(2)
      end
    end

    context 'coordinate shifting' do
      it 'shifts remaining hex coordinates to start at (0,0)' do
        # Traversable hexes starting at (4,4) and (5,6)
        RoomHex.create(room_id: room.id, hex_x: 4, hex_y: 4, hex_type: 'normal', traversable: true, danger_level: 0)
        RoomHex.create(room_id: room.id, hex_x: 5, hex_y: 6, hex_type: 'normal', traversable: true, danger_level: 0)
        # Far-away wall to trigger cropping at (14,0)
        RoomHex.create(room_id: room.id, hex_x: 14, hex_y: 0, hex_type: 'wall', traversable: false, danger_level: 0)

        service.crop_non_traversable_border_in_db(room)

        remaining = room.room_hexes_dataset.order(:hex_x, :hex_y).all
        expect(remaining.size).to eq(2)

        min_x = remaining.map(&:hex_x).min
        min_y = remaining.map(&:hex_y).min
        expect(min_x).to eq(0)
        expect(min_y).to eq(0)
      end
    end

    context 'error handling' do
      it 'rescues errors without raising' do
        allow(room).to receive(:room_hexes_dataset).and_raise(StandardError, 'db error')

        expect { service.crop_non_traversable_border_in_db(room) }.not_to raise_error
      end
    end
  end

  describe '#arena_dimensions_from_hex_data' do
    it 'returns [1,1] for empty data' do
      expect(service.arena_dimensions_from_hex_data([])).to eq([1, 1])
    end

    it 'calculates correct dimensions from hex coordinates' do
      # max_x=5, max_y=6 => arena_width=6, arena_height=(6-2)/4+1=2
      data = [hex(0, 0), hex(5, 6)]
      w, h = service.arena_dimensions_from_hex_data(data)
      expect(w).to eq(6)
      expect(h).to eq(2)
    end

    it 'handles small grids' do
      data = [hex(0, 0)]
      w, h = service.arena_dimensions_from_hex_data(data)
      expect(w).to eq(1)
      expect(h).to eq(1)
    end
  end
end
