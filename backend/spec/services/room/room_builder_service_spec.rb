# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomBuilderService do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location) }

  describe '.place_to_api_hash' do
    it 'includes the icon field' do
      place = create(:place, room: room, icon: '🪑')
      hash = described_class.place_to_api_hash(place)
      expect(hash[:icon]).to eq('🪑')
    end

    it 'returns nil for icon when not set' do
      place = create(:place, room: room)
      hash = described_class.place_to_api_hash(place)
      expect(hash).to have_key(:icon)
      expect(hash[:icon]).to be_nil
    end

    it 'includes standard place fields' do
      place = create(:place, room: room, name: 'Wooden Chair', capacity: 2)
      hash = described_class.place_to_api_hash(place)
      expect(hash[:id]).to eq(place.id)
      expect(hash[:name]).to eq('Wooden Chair')
      expect(hash[:capacity]).to eq(2)
    end
  end

  describe '.create_place' do
    it 'stores and returns the icon field' do
      result = described_class.create_place(room, { 'name' => 'Sofa', 'icon' => '🛋️' })
      expect(result[:success]).to be true
      expect(result[:place][:icon]).to eq('🛋️')
    end

    it 'creates a place without an icon when none provided' do
      result = described_class.create_place(room, { 'name' => 'Table' })
      expect(result[:success]).to be true
      expect(result[:place][:icon]).to be_nil
    end
  end

  describe '.update_place' do
    let(:place) { create(:place, room: room) }

    it 'updates the icon field' do
      result = described_class.update_place(place, { 'icon' => '🪑' })
      expect(result[:success]).to be true
      expect(result[:place][:icon]).to eq('🪑')
    end

    it 'clears the icon when set to nil' do
      place.update(icon: '🪑')
      result = described_class.update_place(place, { 'icon' => nil })
      expect(result[:success]).to be true
      expect(result[:place][:icon]).to be_nil
    end
  end

  describe '.update_room flags' do
    it 'updates safe_room flag' do
      result = described_class.update_room(room, { 'safe_room' => true })
      expect(result[:success]).to be true
      expect(room.reload.safe_room).to be true
    end

    it 'returns all flags in room_to_api_hash' do
      room.update(safe_room: true, no_attack: false)
      hash = described_class.room_to_api_hash(room)
      expect(hash).to have_key(:safe_room)
      expect(hash).to have_key(:no_attack)
      expect(hash).to have_key(:is_vault)
      expect(hash).to have_key(:tutorial_room)
      expect(hash[:safe_room]).to be true
    end
  end

  describe 'Decoration with position and icon' do
    describe '.create_decoration' do
      it 'stores x and y position' do
        result = described_class.create_decoration(room, { 'name' => 'Plant', 'x' => 50, 'y' => 75 })
        expect(result[:success]).to be true
        expect(result[:decoration][:x]).to eq(50.0)
        expect(result[:decoration][:y]).to eq(75.0)
      end

      it 'stores icon field' do
        result = described_class.create_decoration(room, { 'name' => 'Plant', 'icon' => '🌿' })
        expect(result[:success]).to be true
        expect(result[:decoration][:icon]).to eq('🌿')
      end
    end

    describe '.decoration_to_api_hash' do
      it 'includes x, y, and icon fields' do
        decoration = create(:decoration, room: room)
        hash = described_class.decoration_to_api_hash(decoration)
        expect(hash).to have_key(:x)
        expect(hash).to have_key(:y)
        expect(hash).to have_key(:icon)
      end
    end

    describe '.update_decoration' do
      it 'updates icon field' do
        decoration = create(:decoration, room: room)
        result = described_class.update_decoration(decoration, { 'icon' => '🪴' })
        expect(result[:success]).to be true
        expect(result[:decoration][:icon]).to eq('🪴')
      end
    end
  end

  describe '.room_to_api_hash' do
    let(:zone_no_polygon) { create(:zone, polygon_points: nil) }
    let(:location_without_zone_polygon) { create(:location, zone: zone_no_polygon) }
    let(:room_no_zone_polygon) { create(:room, location: location_without_zone_polygon) }

    it 'returns empty array for zone_polygon when location zone has no polygon' do
      hash = described_class.room_to_api_hash(room_no_zone_polygon)
      expect(hash[:zone_polygon]).to eq([])
    end

    it 'includes zone_polygon key in the hash' do
      hash = described_class.room_to_api_hash(room_no_zone_polygon)
      expect(hash).to have_key(:zone_polygon)
    end

    it 'returns room_polygon when set' do
      polygon = [{ 'x' => 0, 'y' => 0 }, { 'x' => 100, 'y' => 0 }, { 'x' => 50, 'y' => 100 }]
      room_with_polygon = create(:room, location: location_without_zone_polygon, room_polygon: Sequel.pg_jsonb_wrap(polygon))
      hash = described_class.room_to_api_hash(room_with_polygon)
      expect(hash[:room_polygon]).not_to be_nil
    end

    it 'includes room_polygon key in the hash' do
      hash = described_class.room_to_api_hash(room_no_zone_polygon)
      expect(hash).to have_key(:room_polygon)
    end
  end

  describe '.room_to_api_hash with inbound features' do
    let(:location) { create(:location) }
    let(:room_a) { create(:room, location: location, name: 'Kitchen') }
    let(:room_b) { create(:room, location: location, name: 'Common Room') }

    it 'includes inbound features from adjacent rooms' do
      door = create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
                    connected_room_id: room_b.id, name: 'Kitchen Door', open_state: 'closed')

      result = described_class.room_to_api_hash(room_b)
      feature_ids = result[:features].map { |f| f[:id] }
      expect(feature_ids).to include(door.id)
    end

    it 'flips orientation for inbound features in API response' do
      create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
             connected_room_id: room_b.id, orientation: 'north')

      result = described_class.room_to_api_hash(room_b)
      inbound_feature = result[:features].find { |f| f[:connected_room_id] == room_a.id }
      expect(inbound_feature[:orientation]).to eq('south')
    end

    it 'shows connected_room_name as the source room for inbound features' do
      create(:room_feature, room: room_a, feature_type: 'door', direction: 'north',
             connected_room_id: room_b.id)

      result = described_class.room_to_api_hash(room_b)
      inbound_feature = result[:features].find { |f| f[:connected_room_id] == room_a.id }
      expect(inbound_feature[:connected_room_name]).to eq('Kitchen')
    end
  end
end
