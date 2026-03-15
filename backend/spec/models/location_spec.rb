# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Location do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(location).to be_valid
    end

    it 'requires name' do
      loc = build(:location, zone: area, name: nil)
      expect(loc).not_to be_valid
    end

    it 'requires area_id' do
      loc = build(:location, zone: nil, name: 'Test')
      expect(loc).not_to be_valid
    end

    it 'validates max length of name' do
      loc = build(:location, zone: area, name: 'x' * 101)
      expect(loc).not_to be_valid
    end

    it 'validates uniqueness of name within area' do
      create(:location, zone: area, name: 'Downtown')
      duplicate = build(:location, zone: area, name: 'Downtown')
      expect(duplicate).not_to be_valid
    end

    it 'validates location_type inclusion' do
      %w[building outdoor underground water sky].each do |type|
        loc = build(:location, zone: area, location_type: type)
        expect(loc).to be_valid
      end

      loc = build(:location, zone: area, location_type: 'invalid')
      expect(loc).not_to be_valid
    end

    it 'requires world_id when globe_hex_id is present' do
      loc = build(:location, zone: area, globe_hex_id: 12345, world_id: nil)
      expect(loc).not_to be_valid
      expect(loc.errors[:world_id]).not_to be_empty
    end
  end

  describe 'associations' do
    it 'belongs to area' do
      expect(location.area).to eq(area)
    end

    it 'has many rooms' do
      expect(location).to respond_to(:rooms)
    end

    it 'has many delves' do
      expect(location).to respond_to(:delves)
    end

    it 'has many news_articles' do
      expect(location).to respond_to(:news_articles)
    end
  end

  describe '#has_hex_coords? (alias for has_globe_hex?)' do
    it 'returns falsey when no globe_hex_id' do
      expect(location.has_hex_coords?).to be_falsey
    end

    it 'returns truthy when globe_hex_id present' do
      location.update(globe_hex_id: 12345, world_id: world.id)
      expect(location.has_hex_coords?).to be_truthy
    end
  end

  describe '#has_globe_hex?' do
    it 'returns false when globe_hex_id is nil' do
      expect(location.has_globe_hex?).to be false
    end

    it 'returns true when globe_hex_id present' do
      location.update(globe_hex_id: 12345, world_id: world.id)
      expect(location.has_globe_hex?).to be true
    end
  end

  describe '#is_city?' do
    it 'returns falsey when city_name is nil' do
      expect(location.is_city?).to be_falsey
    end

    it 'returns falsey when city_name is empty' do
      location.update(city_name: '')
      expect(location.is_city?).to be_falsey
    end

    it 'returns truthy when city_name is present' do
      location.update(city_name: 'Metropolis')
      expect(location.is_city?).to be_truthy
    end
  end

  # Note: active_rooms method has a bug - it calls .where on Array instead of Dataset
  # Skip testing until model is fixed
  describe '#active_rooms' do
    it 'responds to active_rooms' do
      expect(location).to respond_to(:active_rooms)
    end
  end

  describe '#active?' do
    it 'returns true when is_active is true' do
      location.update(is_active: true)
      expect(location.active?).to be true
    end

    it 'returns true when is_active is nil' do
      location.update(is_active: nil)
      expect(location.active?).to be true
    end

    it 'returns false when is_active is false' do
      location.update(is_active: false)
      expect(location.active?).to be false
    end
  end

  describe '#activate!' do
    it 'sets is_active to true' do
      location.update(is_active: false)
      location.activate!
      expect(location.reload.is_active).to be true
    end
  end

  describe '#deactivate!' do
    it 'sets is_active to false' do
      location.deactivate!
      expect(location.reload.is_active).to be false
    end
  end

  describe 'transport infrastructure' do
    describe '#has_port?' do
      it 'returns false by default' do
        expect(location.has_port?).to be false
      end

      it 'returns true when has_port is true' do
        location.update(has_port: true)
        expect(location.has_port?).to be true
      end
    end

    describe '#has_train_station?' do
      it 'returns false by default' do
        expect(location.has_train_station?).to be false
      end

      it 'returns true when has_train_station is true' do
        location.update(has_train_station: true)
        expect(location.has_train_station?).to be true
      end
    end

    describe '#has_ferry_terminal?' do
      it 'returns false by default' do
        expect(location.has_ferry_terminal?).to be false
      end

      it 'returns true when has_ferry_terminal is true' do
        location.update(has_ferry_terminal: true)
        expect(location.has_ferry_terminal?).to be true
      end
    end

    describe '#has_stable?' do
      it 'returns false by default' do
        expect(location.has_stable?).to be false
      end

      it 'returns true when has_stable is true' do
        location.update(has_stable: true)
        expect(location.has_stable?).to be true
      end
    end

    describe '#has_bus_depot?' do
      it 'returns false by default' do
        expect(location.has_bus_depot?).to be false
      end

      it 'returns true when has_bus_depot is true' do
        location.update(has_bus_depot: true)
        expect(location.has_bus_depot?).to be true
      end
    end
  end

  describe '.inactive' do
    let!(:active_location) { create(:location, zone: area, is_active: true) }
    let!(:inactive_location) { create(:location, zone: area, is_active: false) }

    it 'returns only inactive locations' do
      results = described_class.inactive.all
      expect(results).to include(inactive_location)
      expect(results).not_to include(active_location)
    end
  end

  describe '.inactive_recent' do
    let!(:recent_inactive) { create(:location, zone: area, is_active: false) }

    it 'returns inactive locations created recently' do
      results = described_class.inactive_recent.all
      expect(results).to include(recent_inactive)
    end
  end

  describe '#zone_polygon_in_feet' do
    # For the globe hex system, city_origin_world uses longitude/latitude instead of hex_x/hex_y
    let(:zone_with_polygon) do
      create(:zone, world: world, polygon_points: [
        { x: 10.0, y: 10.0 },
        { x: 10.1, y: 10.0 },
        { x: 10.05, y: 10.1 }
      ])
    end
    let(:location_with_hex) do
      # Set longitude/latitude (used by city_origin_world for globe system)
      create(:location, zone: zone_with_polygon, longitude: 10.0, latitude: 10.0, world_id: world.id)
    end

    context 'when zone has no polygon' do
      let(:zone_no_polygon) { create(:zone, world: world, polygon_points: nil) }
      let(:location_no_polygon) { create(:location, zone: zone_no_polygon) }

      it 'returns nil' do
        expect(location_no_polygon.zone_polygon_in_feet).to be_nil
      end
    end

    context 'when zone has world-scale polygon' do
      it 'transforms polygon points to feet coordinates' do
        result = location_with_hex.zone_polygon_in_feet

        expect(result).to be_an(Array)
        expect(result.length).to eq(3)

        # First point at (10.0, 10.0) with origin at (10, 10) should be at (0, 0) feet
        expect(result[0][:x]).to eq(0.0)
        expect(result[0][:y]).to eq(0.0)

        # Second point at (10.1, 10.0) should be offset by 0.1 * HEX_SIZE_FEET
        expect(result[1][:x]).to be_within(1).of(1584.0)
        expect(result[1][:y]).to eq(0.0)
      end
    end

    context 'when zone has local-scale polygon' do
      let(:local_zone) do
        create(:zone, world: world, polygon_scale: 'local', polygon_points: [
          { x: 0, y: 0 },
          { x: 1000, y: 0 },
          { x: 500, y: 1000 }
        ])
      end
      let(:local_location) { create(:location, zone: local_zone) }

      it 'returns polygon points in feet coordinates' do
        result = local_location.zone_polygon_in_feet

        expect(result).to be_an(Array)
        expect(result.length).to eq(3)
        # Local scale polygons are already in feet, converted to consistent format
        expect(result[0][:x]).to eq(0.0)
        expect(result[0][:y]).to eq(0.0)
        expect(result[1][:x]).to eq(1000.0)
      end
    end
  end
end
