# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DelveRoomFeatureService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:area, world: world) }
  let(:location) { create(:location, zone: zone) }

  describe '.wire_features!' do
    it 'creates a wall with door for directions with adjacent rooms' do
      room = create(:room, location: location, min_x: 0, max_x: 30, min_y: 0, max_y: 30)
      described_class.wire_features!(room, open_directions: %w[north south], blocked_directions: {})

      north_wall = RoomFeature.first(room_id: room.id, feature_type: 'wall', direction: 'north')
      north_door = RoomFeature.first(room_id: room.id, feature_type: 'door', direction: 'north')
      expect(north_wall).not_to be_nil
      expect(north_door).not_to be_nil
      expect(north_door.open?).to be true
    end

    it 'creates only a wall for directions without adjacent rooms' do
      room = create(:room, location: location, min_x: 0, max_x: 30, min_y: 0, max_y: 30)
      described_class.wire_features!(room, open_directions: %w[north], blocked_directions: {})

      east_wall = RoomFeature.first(room_id: room.id, feature_type: 'wall', direction: 'east')
      east_door = RoomFeature.first(room_id: room.id, feature_type: 'door', direction: 'east')
      expect(east_wall).not_to be_nil
      expect(east_door).to be_nil
    end

    it 'creates a closed door for blocked directions' do
      room = create(:room, location: location, min_x: 0, max_x: 30, min_y: 0, max_y: 30)
      described_class.wire_features!(room, open_directions: %w[north], blocked_directions: { 'south' => :trap })

      south_door = RoomFeature.first(room_id: room.id, feature_type: 'door', direction: 'south')
      expect(south_door).not_to be_nil
      expect(south_door.open?).to be false
    end

    it 'clears existing features before wiring' do
      room = create(:room, location: location, min_x: 0, max_x: 30, min_y: 0, max_y: 30)
      RoomFeature.create(room_id: room.id, feature_type: 'wall', direction: 'north', name: 'old wall')

      described_class.wire_features!(room, open_directions: %w[south], blocked_directions: {})

      # Old north wall should be gone, replaced by new wiring
      features = RoomFeature.where(room_id: room.id).all
      expect(features.count { |f| f.direction == 'north' }).to eq(1) # just the new wall
    end

    it 'creates walls for all four cardinal directions' do
      room = create(:room, location: location, min_x: 0, max_x: 30, min_y: 0, max_y: 30)
      described_class.wire_features!(room, open_directions: %w[north south east west], blocked_directions: {})

      %w[north south east west].each do |dir|
        wall = RoomFeature.first(room_id: room.id, feature_type: 'wall', direction: dir)
        expect(wall).not_to be_nil, "Expected wall in direction #{dir}"
      end
    end

    it 'positions doors at the correct coordinates' do
      room = create(:room, location: location, min_x: 0, max_x: 30, min_y: 0, max_y: 30)
      described_class.wire_features!(room, open_directions: %w[north south east west], blocked_directions: {})

      north_door = RoomFeature.first(room_id: room.id, feature_type: 'door', direction: 'north')
      south_door = RoomFeature.first(room_id: room.id, feature_type: 'door', direction: 'south')
      east_door = RoomFeature.first(room_id: room.id, feature_type: 'door', direction: 'east')
      west_door = RoomFeature.first(room_id: room.id, feature_type: 'door', direction: 'west')

      expect(north_door.x).to eq(15.0)
      expect(north_door.y).to eq(30.0)
      expect(south_door.x).to eq(15.0)
      expect(south_door.y).to eq(0.0)
      expect(east_door.x).to eq(30.0)
      expect(east_door.y).to eq(15.0)
      expect(west_door.x).to eq(0.0)
      expect(west_door.y).to eq(15.0)
    end
  end

  describe '.open_door!' do
    it 'opens a closed door in a direction' do
      room = create(:room, location: location)
      described_class.wire_features!(room, open_directions: [], blocked_directions: { 'north' => :trap })

      described_class.open_door!(room, 'north')

      door = RoomFeature.first(room_id: room.id, feature_type: 'door', direction: 'north')
      expect(door.open?).to be true
    end

    it 'does nothing if no door exists in that direction' do
      room = create(:room, location: location)
      described_class.wire_features!(room, open_directions: [], blocked_directions: {})

      # Should not raise
      expect { described_class.open_door!(room, 'north') }.not_to raise_error
    end
  end
end
