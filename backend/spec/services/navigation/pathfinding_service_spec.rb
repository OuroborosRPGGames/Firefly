# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PathfindingService do
  let(:location) { create(:location) }
  let(:room_a) { create(:room, name: 'Room A', short_description: 'Start', location: location) }
  let(:room_b) { create(:room, name: 'Room B', short_description: 'Middle', location: location) }
  let(:room_c) { create(:room, name: 'Room C', short_description: 'End', location: location) }
  let(:room_d) { create(:room, name: 'Room D', short_description: 'Alternate', location: location) }

  # Helper to set up spatial adjacency by mocking RoomAdjacencyService.
  # Accepts pairs like [room_a, room_b, :north] meaning room_a has room_b to the north.
  def setup_adjacency(*connections)
    adjacency_map = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [] } }

    connections.each do |from, to, direction|
      adjacency_map[from.id][direction] << to
    end

    allow(RoomAdjacencyService).to receive(:navigable_exits) do |room|
      result = Hash.new { |h, k| h[k] = [] }
      if adjacency_map.key?(room.id)
        adjacency_map[room.id].each do |dir, rooms|
          result[dir] = rooms
        end
      end
      result
    end

    # Allow all passage by default
    allow(RoomPassabilityService).to receive(:can_pass?).and_return(true)
  end

  describe '.find_path' do
    context 'with directly connected rooms' do
      before do
        setup_adjacency(
          [room_a, room_b, :north]
        )
      end

      it 'returns single exit for adjacent rooms' do
        path = described_class.find_path(room_a, room_b)

        expect(path.length).to eq(1)
        expect(path.first.direction).to eq('north')
      end
    end

    context 'with multi-hop path' do
      before do
        setup_adjacency(
          [room_a, room_b, :north],
          [room_b, room_c, :east]
        )
      end

      it 'finds shortest path through multiple rooms' do
        path = described_class.find_path(room_a, room_c)

        expect(path.length).to eq(2)
        expect(path.map(&:direction)).to eq(%w[north east])
      end
    end

    context 'with multiple possible paths' do
      before do
        # Direct path: A -> B -> C (2 hops)
        # Longer path: A -> D -> C (2 hops)
        setup_adjacency(
          [room_a, room_b, :north],
          [room_b, room_c, :east],
          [room_a, room_d, :west],
          [room_d, room_c, :north]
        )
      end

      it 'returns the shortest path' do
        path = described_class.find_path(room_a, room_c)

        expect(path.length).to eq(2)
      end
    end

    context 'with impassable connections' do
      before do
        setup_adjacency(
          [room_a, room_b, :north]
        )
        # Block passage
        allow(RoomPassabilityService).to receive(:can_pass?)
          .with(room_a, room_b, :north)
          .and_return(false)
      end

      it 'does not traverse impassable connections' do
        path = described_class.find_path(room_a, room_b)

        expect(path).to be_empty
      end
    end

    context 'with no path' do
      before do
        # No adjacency set up - rooms are disconnected
        setup_adjacency
      end

      it 'returns empty array for disconnected rooms' do
        path = described_class.find_path(room_a, room_b)

        expect(path).to be_empty
      end
    end

    context 'with same start and end' do
      it 'returns empty array' do
        path = described_class.find_path(room_a, room_a)

        expect(path).to be_empty
      end
    end

    context 'with nil rooms' do
      it 'returns empty array for nil from_room' do
        path = described_class.find_path(nil, room_b)

        expect(path).to be_empty
      end

      it 'returns empty array for nil to_room' do
        path = described_class.find_path(room_a, nil)

        expect(path).to be_empty
      end
    end
  end

  describe '.next_exit_toward' do
    before do
      setup_adjacency(
        [room_a, room_b, :north],
        [room_b, room_c, :east]
      )
    end

    it 'returns the first exit in the path' do
      exit_obj = described_class.next_exit_toward(room_a, room_c)

      expect(exit_obj.direction).to eq('north')
    end

    it 'returns nil for unreachable rooms' do
      exit_obj = described_class.next_exit_toward(room_a, room_d)

      expect(exit_obj).to be_nil
    end
  end

  describe '.distance_between' do
    before do
      setup_adjacency(
        [room_a, room_b, :north],
        [room_b, room_c, :east]
      )
    end

    it 'returns the number of rooms in the path' do
      distance = described_class.distance_between(room_a, room_c)

      expect(distance).to eq(2)
    end

    it 'returns nil for unreachable rooms' do
      distance = described_class.distance_between(room_a, room_d)

      expect(distance).to be_nil
    end
  end

  describe '.reachable?' do
    before do
      setup_adjacency(
        [room_a, room_b, :north]
      )
    end

    it 'returns true for reachable rooms' do
      expect(described_class.reachable?(room_a, room_b)).to be true
    end

    it 'returns false for unreachable rooms' do
      expect(described_class.reachable?(room_a, room_c)).to be false
    end
  end
end
