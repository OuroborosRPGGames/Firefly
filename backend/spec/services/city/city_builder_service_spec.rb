# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/city/city_builder_service'
require_relative '../../../app/services/grid_calculation_service'
require_relative '../../../app/services/city/street_name_service'
require_relative '../../../app/services/city/block_builder_service'

RSpec.describe CityBuilderService do
  let(:universe) { create(:universe, name: 'Test Universe', theme: 'fantasy') }
  let(:world) { create(:world, universe: universe, name: 'Test World') }
  let(:area) { create(:area, world: world, name: 'Test Area') }
  let(:location) do
    create(:location,
           zone: area,
           name: 'Test City',
           horizontal_streets: 5,
           vertical_streets: 5)
  end

  describe '.build_city' do
    let(:params) do
      {
        city_name: 'Test City',
        horizontal_streets: 3,
        vertical_streets: 3,
        max_building_height: 100
      }
    end

    it 'returns success with created rooms' do
      result = described_class.build_city(
        location: location,
        params: params
      )

      expect(result[:success]).to be true
      expect(result[:streets]).to be_an(Array)
      expect(result[:avenues]).to be_an(Array)
      expect(result[:intersections]).to be_an(Array)
      expect(result[:sky_room]).to be_a(Room)
    end

    it 'creates one room per street' do
      result = described_class.build_city(
        location: location,
        params: params
      )

      # 3 streets = 3 street rooms (one per street, spanning full width)
      expect(result[:streets].length).to eq(3)
    end

    it 'creates one room per avenue' do
      result = described_class.build_city(
        location: location,
        params: params
      )

      # 3 avenues = 3 avenue rooms (one per avenue, spanning full height)
      expect(result[:avenues].length).to eq(3)
    end

    it 'creates intersections at each grid crossing' do
      result = described_class.build_city(
        location: location,
        params: params
      )

      # 3 streets x 3 avenues = 9 intersections
      expect(result[:intersections].length).to eq(9)
    end

    it 'updates location with city parameters' do
      described_class.build_city(
        location: location,
        params: params.merge(longitude: -74.0, latitude: 40.7)
      )

      location.reload
      expect(location.city_name).to eq('Test City')
      expect(location.horizontal_streets).to eq(3)
      expect(location.vertical_streets).to eq(3)
      expect(location.max_building_height).to eq(100)
    end

    it 'marks city as built' do
      described_class.build_city(
        location: location,
        params: params
      )

      location.reload
      expect(location.city_built_at).not_to be_nil
    end

    it 'returns street and avenue names' do
      result = described_class.build_city(
        location: location,
        params: params
      )

      expect(result[:street_names]).to be_an(Array)
      expect(result[:street_names].length).to eq(3)
      expect(result[:avenue_names]).to be_an(Array)
      expect(result[:avenue_names].length).to eq(3)
    end

    it 'does not duplicate grid rooms when rebuilding the same city' do
      described_class.build_city(
        location: location,
        params: params
      )

      described_class.build_city(
        location: location,
        params: params
      )

      expect(Room.where(location_id: location.id, city_role: 'street').count).to eq(3)
      expect(Room.where(location_id: location.id, city_role: 'avenue').count).to eq(3)
      expect(Room.where(location_id: location.id, city_role: 'intersection').count).to eq(9)
      expect(Room.where(location_id: location.id, city_role: 'sky').count).to eq(1)
    end

    context 'with an error' do
      before do
        allow(described_class).to receive(:build_streets).and_raise(StandardError, 'Test error')
      end

      it 'returns failure with error message' do
        result = described_class.build_city(
          location: location,
          params: params
        )

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Test error')
      end

      it 'rolls back location and grid changes when build fails' do
        legacy_street = create(:room, location: location, room_type: 'street', city_role: 'street', name: 'Legacy Street')
        location.update(
          city_name: 'Legacy City',
          horizontal_streets: 5,
          vertical_streets: 5,
          max_building_height: 180
        )

        described_class.build_city(
          location: location,
          params: params
        )

        expect(Room[legacy_street.id]).not_to be_nil
        location.reload
        expect(location.city_name).to eq('Legacy City')
        expect(location.horizontal_streets).to eq(5)
        expect(location.vertical_streets).to eq(5)
        expect(location.max_building_height).to eq(180)
      end
    end
  end

  describe '.generate_street_names' do
    it 'generates numbered names for test universe' do
      names = described_class.generate_street_names(location, 3)

      expect(names).to eq(['1st Street', '2nd Street', '3rd Street'])
    end

    it 'generates the requested number of names' do
      names = described_class.generate_street_names(location, 5)

      expect(names.length).to eq(5)
    end
  end

  describe '.generate_avenue_names' do
    it 'generates numbered names for test universe' do
      names = described_class.generate_avenue_names(location, 3)

      expect(names).to eq(['1st Avenue', '2nd Avenue', '3rd Avenue'])
    end
  end

  describe '.build_streets' do
    let(:street_names) { ['Main Street', 'Oak Street', 'Elm Street'] }

    it 'creates one room per street spanning full city width' do
      streets = described_class.build_streets(location, street_names, 5)

      # 3 streets = 3 rooms (one per street)
      expect(streets.length).to eq(3)
      expect(streets.first.name).to eq('Main Street')
      expect(streets.first.room_type).to eq('street')
      expect(streets.first.city_role).to eq('street')
    end

    it 'sets correct grid coordinates' do
      streets = described_class.build_streets(location, street_names, 5)

      streets.each_with_index do |street, index|
        expect(street.grid_y).to eq(index)
        expect(street.grid_x).to be_nil
      end
    end

    it 'spans the full city width' do
      streets = described_class.build_streets(location, street_names, 5)

      # With 5 avenues, city width = 5 * 175 = 875
      expect(streets.first.min_x).to eq(0)
      expect(streets.first.max_x).to eq(875)
    end
  end

  describe '.build_avenues' do
    let(:avenue_names) { ['1st Avenue', '2nd Avenue'] }

    it 'creates one room per avenue spanning full city height' do
      avenues = described_class.build_avenues(location, avenue_names, 5)

      # 2 avenues = 2 rooms (one per avenue)
      expect(avenues.length).to eq(2)
      expect(avenues.first.name).to eq('1st Avenue')
      expect(avenues.first.room_type).to eq('avenue')
      expect(avenues.first.city_role).to eq('avenue')
    end

    it 'sets correct grid coordinates' do
      avenues = described_class.build_avenues(location, avenue_names, 5)

      avenues.each_with_index do |avenue, index|
        expect(avenue.grid_x).to eq(index)
        expect(avenue.grid_y).to be_nil
      end
    end

    it 'spans the full city height' do
      avenues = described_class.build_avenues(location, avenue_names, 5)

      # With 5 streets, city height = 5 * 175 = 875
      expect(avenues.first.min_y).to eq(0)
      expect(avenues.first.max_y).to eq(875)
    end
  end

  describe '.build_intersections' do
    let(:streets) { [] }
    let(:avenues) { [] }
    let(:street_names) { ['Main St', 'Oak St'] }
    let(:avenue_names) { ['1st Ave', '2nd Ave'] }

    it 'creates intersection rooms at each crossing' do
      intersections = described_class.build_intersections(
        location, streets, avenues, street_names, avenue_names
      )

      expect(intersections.length).to eq(4) # 2 streets x 2 avenues
    end

    it 'names intersections with street and avenue' do
      intersections = described_class.build_intersections(
        location, streets, avenues, street_names, avenue_names
      )

      names = intersections.map(&:name)
      expect(names).to include('Main St & 1st Ave')
      expect(names).to include('Oak St & 2nd Ave')
    end

    it 'sets correct grid coordinates' do
      intersections = described_class.build_intersections(
        location, streets, avenues, street_names, avenue_names
      )

      # Find intersection at (1, 1)
      intersection = intersections.find { |i| i.grid_x == 1 && i.grid_y == 1 }
      expect(intersection).not_to be_nil
      expect(intersection.name).to eq('Oak St & 2nd Ave')
    end
  end

  describe '.build_sky_room' do
    it 'creates a sky room above the city' do
      sky = described_class.build_sky_room(location, 5, 5)

      expect(sky.name).to include('Sky')
      expect(sky.min_z).to be > 0
    end

    it 'positions sky above max building height' do
      location.max_building_height = 200
      sky = described_class.build_sky_room(location, 5, 5)

      expect(sky.min_z).to be >= 200
    end
  end

  describe '.find_or_create_building' do
    before do
      # Create a city with intersections
      described_class.build_city(
        location: location,
        params: { horizontal_streets: 3, vertical_streets: 3 }
      )
    end

    it 'creates a new building when none exist' do
      building = described_class.find_or_create_building(
        location: location,
        building_type: :apartment_tower
      )

      expect(building).not_to be_nil
      expect(building.room_type).to eq('apartment')
    end

    it 'finds existing building when available' do
      # Create first apartment
      first = described_class.find_or_create_building(
        location: location,
        building_type: :apartment_tower
      )

      # Find existing
      found = described_class.find_or_create_building(
        location: location,
        building_type: :apartment_tower
      )

      expect(found.id).to eq(first.id)
    end

    it 'skips apartments that already have an owner' do
      owned_apartment = create(
        :room,
        location: location,
        room_type: 'apartment',
        city_role: 'building',
        building_type: 'apartment_tower',
        floor_number: 1,
        owner_id: create(:character).id
      )

      unowned_apartment = create(
        :room,
        location: location,
        room_type: 'apartment',
        city_role: 'building',
        building_type: 'apartment_tower',
        floor_number: 2,
        owner_id: nil
      )

      found = described_class.find_or_create_building(
        location: location,
        building_type: :apartment_tower
      )

      expect(found).not_to be_nil
      expect(found.id).not_to eq(owned_apartment.id)
      expect(found.owner_id).to be_nil
    end
  end

  describe '.can_build?' do
    let(:character) { create(:character) }
    let(:user) { character.user }

    context 'without permissions' do
      it 'returns false for build_city' do
        expect(described_class.can_build?(character, :build_city)).to be false
      end

      it 'returns false for build_block' do
        expect(described_class.can_build?(character, :build_block)).to be false
      end
    end

    context 'with nil character' do
      it 'returns false' do
        expect(described_class.can_build?(nil, :build_city)).to be false
      end
    end
  end

  describe 'integration: full city build' do
    it 'creates a complete city grid' do
      result = described_class.build_city(
        location: location,
        params: {
          city_name: 'Testville',
          horizontal_streets: 4,
          vertical_streets: 4,
          max_building_height: 150
        }
      )

      expect(result[:success]).to be true

      # Verify room counts
      # Streets: 4 streets = 4 street rooms (one per street)
      street_count = Room.where(location_id: location.id, city_role: 'street').count
      # Avenues: 4 avenues = 4 avenue rooms (one per avenue)
      avenue_count = Room.where(location_id: location.id, city_role: 'avenue').count
      intersection_count = Room.where(location_id: location.id, city_role: 'intersection').count

      expect(street_count).to eq(4)
      expect(avenue_count).to eq(4)
      expect(intersection_count).to eq(16) # 4x4 grid
    end
  end
end
