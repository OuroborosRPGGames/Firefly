# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomExitCacheService do
  let(:location) { create(:location) }
  let(:room) do
    create(:room, location: location, min_x: 0, max_x: 10, min_y: 0, max_y: 10)
  end
  let(:adjacent_room) do
    create(:room, location: location, min_x: 10, max_x: 20, min_y: 0, max_y: 10)
  end

  before do
    # Clear any cached keys from previous tests
    REDIS_POOL.with do |r|
      keys = r.keys('room_adj:*')
      r.del(*keys) if keys.any?
    end
  end

  describe '.navigable_exits' do
    it 'returns the same result as compute_navigable_exits' do
      cached_result = described_class.navigable_exits(room)
      uncached_result = RoomAdjacencyService.compute_navigable_exits(room)

      # Compare room IDs per direction since Room objects may differ by identity
      cached_ids = cached_result.transform_values { |rooms| rooms.map(&:id).sort }
      uncached_ids = uncached_result.transform_values { |rooms| rooms.map(&:id).sort }
      expect(cached_ids).to eq(uncached_ids)
    end

    it 'caches the result in Redis on first call' do
      described_class.navigable_exits(room)

      # A key should exist in Redis
      keys = REDIS_POOL.with { |r| r.keys("room_adj:navigable_exits:#{room.id}:*") }
      expect(keys).not_to be_empty
    end

    it 'returns cached result on second call without recomputing' do
      # First call - populates cache
      described_class.navigable_exits(room)

      # Spy on compute method for second call
      expect(RoomAdjacencyService).not_to receive(:compute_navigable_exits)
      described_class.navigable_exits(room)
    end
  end

  describe '.adjacent_rooms' do
    it 'returns the same result as compute_adjacent_rooms' do
      adjacent_room # ensure created
      cached = described_class.adjacent_rooms(room)
      uncached = RoomAdjacencyService.compute_adjacent_rooms(room)

      cached_ids = cached.transform_values { |rooms| rooms.map(&:id).sort }
      uncached_ids = uncached.transform_values { |rooms| rooms.map(&:id).sort }
      expect(cached_ids).to eq(uncached_ids)
    end

    it 'caches the result in Redis' do
      described_class.adjacent_rooms(room)
      keys = REDIS_POOL.with { |r| r.keys("room_adj:adjacent_rooms:#{room.id}:*") }
      expect(keys).not_to be_empty
    end
  end

  describe '.contained_rooms' do
    let(:inner_room) do
      create(:room, location: location, min_x: 2, max_x: 8, min_y: 2, max_y: 8)
    end

    it 'returns the same result as compute_contained_rooms' do
      inner_room # ensure created
      cached = described_class.contained_rooms(room)
      uncached = RoomAdjacencyService.compute_contained_rooms(room)

      expect(cached.map(&:id).sort).to eq(uncached.map(&:id).sort)
    end

    it 'caches the result in Redis' do
      described_class.contained_rooms(room)
      keys = REDIS_POOL.with { |r| r.keys("room_adj:contained_rooms:#{room.id}:*") }
      expect(keys).not_to be_empty
    end
  end

  describe '.containing_room' do
    let(:inner_room) do
      create(:room, location: location, min_x: 2, max_x: 8, min_y: 2, max_y: 8)
    end

    it 'returns the same result as compute_containing_room' do
      room # ensure outer room exists
      cached = described_class.containing_room(inner_room)
      uncached = RoomAdjacencyService.compute_containing_room(inner_room)

      expect(cached&.id).to eq(uncached&.id)
    end

    it 'caches nil results correctly' do
      # Room with no container
      cached = described_class.containing_room(room)
      expect(cached).to be_nil

      # Should be cached now
      expect(RoomAdjacencyService).not_to receive(:compute_containing_room)
      result = described_class.containing_room(room)
      expect(result).to be_nil
    end
  end

  describe '.invalidate_location!' do
    it 'stales all cached entries for the location' do
      # Populate cache
      described_class.navigable_exits(room)
      described_class.adjacent_rooms(room)

      # Invalidate
      described_class.invalidate_location!(location.id)

      # Next call should recompute (new version counter means old keys are stale)
      expect(RoomAdjacencyService).to receive(:compute_navigable_exits).and_call_original
      described_class.navigable_exits(room)
    end

    it 'increments the location version counter' do
      v1 = REDIS_POOL.with { |r| r.get("room_adj:loc_version:#{location.id}") || '0' }
      described_class.invalidate_location!(location.id)
      v2 = REDIS_POOL.with { |r| r.get("room_adj:loc_version:#{location.id}") }

      expect(v2.to_i).to eq(v1.to_i + 1)
    end
  end

  describe '.invalidate_door_state!' do
    it 'stales door-sensitive cache for the room' do
      # Populate cache
      described_class.navigable_exits(room)

      # Invalidate door state
      described_class.invalidate_door_state!(room.id)

      # Next call should recompute
      expect(RoomAdjacencyService).to receive(:compute_navigable_exits).and_call_original
      described_class.navigable_exits(room)
    end

    it 'does not stale non-door-sensitive cache' do
      # Populate adjacent_rooms cache (not door-sensitive)
      described_class.adjacent_rooms(room)

      # Invalidate door state
      described_class.invalidate_door_state!(room.id)

      # adjacent_rooms should still be cached (same location version)
      expect(RoomAdjacencyService).not_to receive(:compute_adjacent_rooms)
      described_class.adjacent_rooms(room)
    end
  end

  describe 'graceful degradation' do
    it 'falls through to uncached computation when Redis is unavailable' do
      allow(REDIS_POOL).to receive(:with).and_raise(Redis::CannotConnectError)

      # Should not raise, should fall through to compute
      result = described_class.navigable_exits(room)
      expect(result).to be_a(Hash)
    end

    it 'invalidate_location! does not raise when Redis is unavailable' do
      allow(REDIS_POOL).to receive(:with).and_raise(Redis::CannotConnectError)

      expect { described_class.invalidate_location!(location.id) }.not_to raise_error
    end

    it 'invalidate_door_state! does not raise when Redis is unavailable' do
      allow(REDIS_POOL).to receive(:with).and_raise(Redis::CannotConnectError)

      expect { described_class.invalidate_door_state!(room.id) }.not_to raise_error
    end
  end

  describe 'serialization' do
    it 'correctly serializes and deserializes exit hashes with multiple directions' do
      adjacent_room # ensure created

      # First call computes and caches
      first_result = described_class.adjacent_rooms(room)

      # Clear the in-process state so next call must use Redis
      # (it will hit the cache)
      second_result = described_class.adjacent_rooms(room)

      first_ids = first_result.transform_values { |rooms| rooms.map(&:id).sort }
      second_ids = second_result.transform_values { |rooms| rooms.map(&:id).sort }
      expect(second_ids).to eq(first_ids)
    end

    it 'handles empty exit hashes' do
      # Room with no neighbors
      isolated = create(:room, location: create(:location), min_x: 0, max_x: 10, min_y: 0, max_y: 10)
      result = described_class.navigable_exits(isolated)
      expect(result).to be_a(Hash)
    end
  end
end
