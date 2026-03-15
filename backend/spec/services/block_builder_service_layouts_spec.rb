# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BlockBuilderService do
  include TestHelpers

  let(:universe) { create(:universe, name: 'Test Universe') }
  let(:world) { create(:world, universe: universe, name: 'Test World') }
  let(:area) { create(:area, world: world, name: 'Test Area') }
  let(:location) do
    create(:location,
           zone: area,
           name: 'Test City',
           city_built_at: Time.now,
           horizontal_streets: 3,
           vertical_streets: 3,
           max_building_height: 200)
  end
  let(:intersection) do
    create(:room,
           location: location,
           name: '1st Street & 1st Avenue',
           room_type: 'intersection',
           city_role: 'intersection',
           grid_x: 0,
           grid_y: 0)
  end
  let(:street) do
    create(:room,
           location: location,
           name: '1st Street',
           room_type: 'street',
           city_role: 'street',
           grid_x: 0,
           grid_y: 0,
           street_name: '1st Street')
  end

  before do
    street # Ensure street exists for address generation
  end

  describe '.build_block_layout' do
    context 'with full layout' do
      it 'creates a single building filling the block' do
        rooms = described_class.build_block_layout(
          location: location,
          intersection_room: intersection,
          layout: :full,
          building_assignments: { full: :brownstone }
        )

        expect(rooms).not_to be_empty
        buildings = rooms.select { |r| r.city_role == 'building' && r.building_type == 'brownstone' }
        expect(buildings.length).to be >= 1
      end
    end

    context 'with split_ns layout' do
      it 'creates two buildings in north and south halves' do
        rooms = described_class.build_block_layout(
          location: location,
          intersection_room: intersection,
          layout: :split_ns,
          building_assignments: { north: :house, south: :shop }
        )

        expect(rooms).not_to be_empty
        house_count = rooms.count { |r| r.building_type == 'house' }
        shop_count = rooms.count { |r| r.building_type == 'shop' }

        expect(house_count).to be >= 1
        expect(shop_count).to be >= 1
      end
    end

    context 'with quadrants layout' do
      it 'creates four buildings in corners' do
        rooms = described_class.build_block_layout(
          location: location,
          intersection_room: intersection,
          layout: :quadrants,
          building_assignments: { ne: :house, nw: :house, se: :house, sw: :house }
        )

        expect(rooms).not_to be_empty
        buildings = rooms.select { |r| r.city_role == 'building' }
        expect(buildings.length).to be >= 4
      end
    end

    context 'with terrace_north layout' do
      it 'creates a row of terraces along north edge' do
        rooms = described_class.build_block_layout(
          location: location,
          intersection_room: intersection,
          layout: :terrace_north,
          building_assignments: {}  # Uses default terrace
        )

        expect(rooms).not_to be_empty
        terraces = rooms.select { |r| r.building_type == 'terrace' }
        expect(terraces.length).to be >= 1
      end
    end

    context 'with mixed_tower_shops layout' do
      it 'creates a central tower with corner shops' do
        rooms = described_class.build_block_layout(
          location: location,
          intersection_room: intersection,
          layout: :mixed_tower_shops,
          building_assignments: { center_large: :apartment_tower }
        )

        expect(rooms).not_to be_empty
        towers = rooms.select { |r| r.building_type == 'apartment_tower' }
        shops = rooms.select { |r| r.building_type == 'shop' }

        expect(towers.length).to be >= 1
        expect(shops.length).to be >= 1
      end
    end
  end

  describe '.build_terrace_row' do
    it 'creates a row of terrace houses' do
      rooms = described_class.build_terrace_row(
        location: location,
        intersection_room: intersection,
        edge: :north,
        count: 6
      )

      expect(rooms).not_to be_empty
      terraces = rooms.select { |r| r.building_type == 'terrace' }
      expect(terraces.length).to be >= 1
    end
  end

  describe 'building type interiors via FloorPlanService' do
    describe 'terrace interior' do
      let(:terrace) do
        create(:room,
               location: location,
               name: 'Test Terrace',
               room_type: 'building',
               city_role: 'building',
               building_type: 'terrace',
               grid_x: 0,
               grid_y: 0,
               min_z: 0,
               max_z: 25)
      end
      let(:bounds) { { min_x: 0, max_x: 25, min_y: 0, max_y: 40, min_z: 0, max_z: 25 } }
      let(:config) { GridCalculationService.building_config(:terrace) }

      it 'creates interior rooms for terrace using FloorPlanService templates' do
        rooms = described_class.populate_building(
          building: terrace,
          building_type: :terrace,
          config: config,
          bounds: bounds,
          location: location
        )

        # terrace_ground: Entry (hallway) + Living Room (residence)
        # terrace_upper: Landing (hallway) + Bedroom (residence) + Bathroom (bathroom)
        expect(rooms.length).to be >= 4
        expect(rooms.any? { |r| r.name.include?('Living Room') }).to be true
        expect(rooms.any? { |r| r.name.include?('Bedroom') }).to be true
      end
    end

    describe 'hotel interior' do
      let(:hotel) do
        create(:room,
               location: location,
               name: 'Test Hotel',
               room_type: 'building',
               city_role: 'building',
               building_type: 'hotel',
               grid_x: 0,
               grid_y: 0,
               min_z: 0,
               max_z: 120)
      end
      let(:bounds) { { min_x: 0, max_x: 60, min_y: 0, max_y: 60, min_z: 0, max_z: 120 } }

      it 'creates lobby and hotel rooms via FloorPlanService templates' do
        config = { floors: 3 }
        rooms = described_class.populate_building(
          building: hotel,
          building_type: :hotel,
          config: config,
          bounds: bounds,
          location: location
        )

        # hotel_lobby: Lobby (hallway) + Concierge (commercial) + Lounge (commercial)
        # hotel_floor x2: Corridor (hallway) + 6 Room (residence) each
        expect(rooms.length).to be > 5

        lobby = rooms.find { |r| r.name.include?('Lobby') }
        expect(lobby).not_to be_nil

        # Hotel rooms from template are 'residence' type
        hotel_rooms = rooms.select { |r| r.room_type == 'residence' }
        expect(hotel_rooms.length).to be > 0
      end
    end

    describe 'gym interior' do
      let(:gym) do
        create(:room,
               location: location,
               name: 'Test Gym',
               room_type: 'building',
               city_role: 'building',
               building_type: 'gym',
               grid_x: 0,
               grid_y: 0,
               min_z: 0,
               max_z: 30)
      end
      let(:bounds) { { min_x: 0, max_x: 60, min_y: 0, max_y: 60, min_z: 0, max_z: 30 } }

      it 'creates gym rooms via FloorPlanService templates' do
        config = { floors: 1 }
        rooms = described_class.populate_building(
          building: gym,
          building_type: :gym,
          config: config,
          bounds: bounds,
          location: location
        )

        # gym_ground: Reception (hallway) + Main Floor (commercial) + Studios (commercial)
        expect(rooms.length).to be >= 2
        expect(rooms.any? { |r| r.name.include?('Main Floor') }).to be true
      end
    end

    describe 'cinema interior' do
      let(:cinema) do
        create(:room,
               location: location,
               name: 'Test Cinema',
               room_type: 'building',
               city_role: 'building',
               building_type: 'cinema',
               grid_x: 0,
               grid_y: 0,
               min_z: 0,
               max_z: 40)
      end
      let(:bounds) { { min_x: 0, max_x: 80, min_y: 0, max_y: 100, min_z: 0, max_z: 40 } }

      it 'creates lobby and theater via FloorPlanService templates' do
        config = { floors: 1 }
        rooms = described_class.populate_building(
          building: cinema,
          building_type: :cinema,
          config: config,
          bounds: bounds,
          location: location
        )

        # cinema_ground: Lobby (hallway) + Main Theater (commercial)
        expect(rooms.length).to eq(2)
        expect(rooms.any? { |r| r.name.include?('Lobby') }).to be true
        expect(rooms.any? { |r| r.name.include?('Main Theater') }).to be true
      end
    end

    describe 'parking garage interior' do
      let(:garage) do
        create(:room,
               location: location,
               name: 'Test Parking',
               room_type: 'building',
               city_role: 'building',
               building_type: 'parking_garage',
               grid_x: 0,
               grid_y: 0,
               min_z: 0,
               max_z: 60)
      end
      let(:bounds) { { min_x: 0, max_x: 80, min_y: 0, max_y: 80, min_z: 0, max_z: 60 } }
      let(:config) { GridCalculationService.building_config(:parking_garage) }

      it 'creates multiple parking levels via FloorPlanService templates' do
        rooms = described_class.populate_building(
          building: garage,
          building_type: :parking_garage,
          config: config,
          bounds: bounds,
          location: location
        )

        # parking_floor template creates 1 Parking Level room per floor
        expect(rooms.length).to be >= 1
        expect(rooms.first.name).to include('Parking Level')
      end
    end
  end
end
