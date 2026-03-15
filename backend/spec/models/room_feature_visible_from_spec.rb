# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomFeature, '.visible_from' do
  let(:location) { create(:location) }
  let(:room_a) { create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100) }
  let(:room_b) { create(:room, location: location, min_x: 0, max_x: 100, min_y: 100, max_y: 200) }

  it 'returns features owned by the room' do
    door = create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
                  connected_room_id: room_b.id, open_state: 'closed')

    result = RoomFeature.visible_from(room_a)
    expect(result.map(&:id)).to include(door.id)
  end

  it 'returns inbound features from adjacent rooms' do
    door = create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
                  connected_room_id: room_b.id, open_state: 'closed')

    result = RoomFeature.visible_from(room_b)
    expect(result.map(&:id)).to include(door.id)
  end

  it 'flips direction for inbound features' do
    create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
           connected_room_id: room_b.id)

    result = RoomFeature.visible_from(room_b)
    inbound = result.find { |f| f.respond_to?(:inbound?) && f.inbound? }
    expect(inbound).not_to be_nil
    expect(inbound.direction).to eq('south')
  end

  it 'flips orientation for inbound features' do
    create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
           orientation: 'north', connected_room_id: room_b.id)

    result = RoomFeature.visible_from(room_b)
    inbound = result.find { |f| f.respond_to?(:inbound?) && f.inbound? }
    expect(inbound.orientation).to eq('south')
  end

  it 'flips connected_room_id for inbound features to point back to source' do
    create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
           connected_room_id: room_b.id)

    result = RoomFeature.visible_from(room_b)
    inbound = result.find { |f| f.respond_to?(:inbound?) && f.inbound? }
    expect(inbound.connected_room_id).to eq(room_a.id)
  end

  it 'does not return walls as inbound features' do
    create(:room_feature, room: room_a, feature_type: 'wall', direction: 'north',
           connected_room_id: room_b.id)

    result = RoomFeature.visible_from(room_b)
    inbound = result.select { |f| f.respond_to?(:inbound?) && f.inbound? }
    expect(inbound).to be_empty
  end

  it 'does not duplicate features that are owned by the room' do
    door = create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
                  connected_room_id: room_b.id)

    result = RoomFeature.visible_from(room_a)
    expect(result.count { |f| f.id == door.id }).to eq(1)
  end

  it 'preserves all other attributes for inbound features' do
    door = create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
                  connected_room_id: room_b.id, open_state: 'closed', name: 'Oak Door',
                  x: 50.0, y: 100.0)

    result = RoomFeature.visible_from(room_b)
    inbound = result.find { |f| f.respond_to?(:inbound?) && f.inbound? }
    expect(inbound.name).to eq('Oak Door')
    expect(inbound.feature_type).to eq('door')
    expect(inbound.open_state).to eq('closed')
    expect(inbound.open?).to be false
    expect(inbound.x).to eq(50.0)
    expect(inbound.y).to eq(100.0)
  end

  it 'returns empty array for room with no features and no inbound' do
    room_c = create(:room, location: location)
    expect(RoomFeature.visible_from(room_c)).to eq([])
  end

  it 'includes windows as inbound features' do
    create(:room_feature, room: room_a, feature_type: 'window', direction: 'north',
           connected_room_id: room_b.id)

    result = RoomFeature.visible_from(room_b)
    inbound = result.select { |f| f.respond_to?(:inbound?) && f.inbound? }
    expect(inbound.size).to eq(1)
    expect(inbound.first.feature_type).to eq('window')
  end

  context 'boundary-based detection (no connected_room_id)' do
    let(:building) { create(:room, location: location, min_x: 0, max_x: 200, min_y: 0, max_y: 200) }
    let(:room_south) { create(:room, location: location, inside_room_id: building.id, min_x: 0, max_x: 100, min_y: 0, max_y: 100, min_z: 0, max_z: 10) }
    let(:room_north) { create(:room, location: location, inside_room_id: building.id, min_x: 0, max_x: 100, min_y: 100, max_y: 200, min_z: 0, max_z: 10) }

    it 'finds features from adjacent sibling on shared boundary' do
      door = create(:room_feature, room: room_north, feature_type: 'door',
                    direction: 'south', x: 50.0, y: 100.0, open_state: 'closed')

      result = RoomFeature.visible_from(room_south)
      expect(result.map(&:id)).to include(door.id)
    end

    it 'infers direction based on which wall the boundary is on' do
      create(:room_feature, room: room_north, feature_type: 'door',
             direction: 'south', x: 50.0, y: 100.0)

      # room_north (y=100-200) is north of room_south (y=0-100) — higher Y = north
      result = RoomFeature.visible_from(room_south)
      boundary_feature = result.find { |f| f.respond_to?(:inbound?) && f.inbound? }
      expect(boundary_feature.direction).to eq('north')
    end

    it 'does not include features not on the shared boundary' do
      # Feature at y=150, but shared boundary is y=100
      interior_door = create(:room_feature, room: room_north, feature_type: 'door',
                             direction: 'north', x: 50.0, y: 150.0)

      result = RoomFeature.visible_from(room_south)
      expect(result.map(&:id)).not_to include(interior_door.id)
    end

    it 'does not include walls from adjacent rooms' do
      create(:room_feature, room: room_north, feature_type: 'wall',
             direction: 'south', x: 50.0, y: 100.0)

      result = RoomFeature.visible_from(room_south)
      inbound = result.select { |f| f.respond_to?(:inbound?) && f.inbound? }
      expect(inbound).to be_empty
    end

    it 'does not duplicate features already found via connected_room_id' do
      door = create(:room_feature, room: room_north, feature_type: 'door',
                    direction: 'south', x: 50.0, y: 100.0,
                    connected_room_id: room_south.id)

      result = RoomFeature.visible_from(room_south)
      expect(result.count { |f| f.id == door.id }).to eq(1)
    end

    it 'works for east-west boundaries' do
      room_west = create(:room, location: location, inside_room_id: building.id,
                         min_x: 0, max_x: 100, min_y: 0, max_y: 100, min_z: 0, max_z: 10)
      room_east = create(:room, location: location, inside_room_id: building.id,
                         min_x: 100, max_x: 200, min_y: 0, max_y: 100, min_z: 0, max_z: 10)
      door = create(:room_feature, room: room_east, feature_type: 'door',
                    direction: 'west', x: 100.0, y: 50.0)

      result = RoomFeature.visible_from(room_west)
      expect(result.map(&:id)).to include(door.id)
      boundary_feature = result.find { |f| f.respond_to?(:inbound?) && f.inbound? && f.id == door.id }
      expect(boundary_feature.direction).to eq('east')
    end

    it 'ignores rooms on different floors' do
      # Update the building to be tall enough for both floors
      building.update(min_z: 0, max_z: 20)

      room_above = create(:room, location: location, inside_room_id: building.id,
                          min_x: 0, max_x: 100, min_y: 0, max_y: 100, min_z: 10, max_z: 20)
      door = create(:room_feature, room: room_above, feature_type: 'door',
                    direction: 'south', x: 50.0, y: 0.0)

      result = RoomFeature.visible_from(room_south)
      expect(result.map(&:id)).not_to include(door.id)
    end
  end
end
