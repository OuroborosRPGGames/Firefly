# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TemporaryRoomPoolService do
  let(:location) { create(:location) }

  # Ensure a pool location exists for room creation
  let!(:pool_location) do
    Location.find_or_create(name: 'Room Pool') do |l|
      l.zone_id = location.zone_id
      l.location_type = 'building'
    end
  end

  describe '.acquire_for_delve' do
    let(:delve) { create(:delve) }

    before do
      # Ensure a delve room template exists
      RoomTemplate.find_or_create(template_type: 'delve_room') do |t|
        t.name = 'Delve Room'
        t.category = 'delve'
        t.room_type = 'dungeon'
        t.short_description = 'A dark dungeon chamber.'
        t.width = 30
        t.length = 30
        t.height = 10
        t.active = true
      end
    end

    it 'returns a temporary room marked in_use' do
      result = described_class.acquire_for_delve(delve)

      expect(result.success?).to be true
      room = result[:room]
      expect(room).to be_a(Room)
      expect(room.is_temporary).to be true
      expect(room.pool_status).to eq('in_use')
      expect(room.temp_delve_id).to eq(delve.id)
    end

    it 'creates a 30x30 foot room' do
      result = described_class.acquire_for_delve(delve)
      room = result[:room]

      expect(room.max_x - room.min_x).to eq(30)
      expect(room.max_y - room.min_y).to eq(30)
    end

    it 'returns error when no delve room template exists' do
      RoomTemplate.where(template_type: 'delve_room').delete

      result = described_class.acquire_for_delve(delve)

      expect(result.failure?).to be true
      expect(result.message).to include('No delve room template found')
    end
  end

  describe '.release_delve_rooms' do
    let(:delve) { create(:delve) }

    before do
      RoomTemplate.find_or_create(template_type: 'delve_room') do |t|
        t.name = 'Delve Room'
        t.category = 'delve'
        t.room_type = 'dungeon'
        t.short_description = 'A dark dungeon chamber.'
        t.width = 30
        t.length = 30
        t.height = 10
        t.active = true
      end
    end

    it 'releases all rooms for a delve back to the pool' do
      rooms = 3.times.map do
        result = described_class.acquire_for_delve(delve)
        result[:room]
      end

      described_class.release_delve_rooms(delve)

      rooms.each do |room|
        room.reload
        expect(room.pool_status).to eq('available')
        expect(room.temp_delve_id).to be_nil
      end
    end

    it 'clears room features when releasing' do
      result = described_class.acquire_for_delve(delve)
      room = result[:room]
      RoomFeature.create(room_id: room.id, feature_type: 'wall', direction: 'north')

      described_class.release_delve_rooms(delve)

      expect(RoomFeature.where(room_id: room.id).count).to eq(0)
    end

    it 'clears room hexes when releasing' do
      result = described_class.acquire_for_delve(delve)
      room = result[:room]
      RoomHex.create(room_id: room.id, hex_x: 0, hex_y: 0, hex_type: 'normal', danger_level: 0)

      described_class.release_delve_rooms(delve)

      expect(RoomHex.where(room_id: room.id).count).to eq(0)
    end

    it 'returns success with count of released rooms' do
      3.times { described_class.acquire_for_delve(delve) }

      result = described_class.release_delve_rooms(delve)

      expect(result.success?).to be true
      expect(result[:count]).to eq(3)
    end

    it 'returns success with zero count when no rooms to release' do
      result = described_class.release_delve_rooms(delve)

      expect(result.success?).to be true
      expect(result[:count]).to eq(0)
    end

    it 'clears spatial_group_id when releasing' do
      result = described_class.acquire_for_delve(delve)
      room = result[:room]
      expect(room.spatial_group_id).to eq("delve:#{delve.id}")

      described_class.release_delve_rooms(delve)
      room.reload

      expect(room.spatial_group_id).to be_nil
    end
  end

  describe 'spatial_group_id lifecycle' do
    let(:delve) { create(:delve) }

    before do
      RoomTemplate.find_or_create(template_type: 'delve_room') do |t|
        t.name = 'Delve Room'
        t.category = 'delve'
        t.room_type = 'dungeon'
        t.short_description = 'A dark dungeon chamber.'
        t.width = 30
        t.length = 30
        t.height = 10
        t.active = true
      end
    end

    it 'sets spatial_group_id on acquire' do
      result = described_class.acquire_for_delve(delve)

      expect(result.success?).to be true
      room = result[:room]
      expect(room.spatial_group_id).to eq("delve:#{delve.id}")
    end

    it 'uses different spatial_group_ids for different delves' do
      delve2 = create(:delve)

      result1 = described_class.acquire_for_delve(delve)
      result2 = described_class.acquire_for_delve(delve2)

      expect(result1[:room].spatial_group_id).to eq("delve:#{delve.id}")
      expect(result2[:room].spatial_group_id).to eq("delve:#{delve2.id}")
      expect(result1[:room].spatial_group_id).not_to eq(result2[:room].spatial_group_id)
    end
  end
end
