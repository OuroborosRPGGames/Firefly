# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/city/block_builder_service'
require_relative '../../../app/services/grid_calculation_service'
require_relative '../../../app/services/navigation/floor_plan_service'
require_relative '../../../app/services/city/block_lot_service'

RSpec.describe BlockBuilderService do
  let(:universe) { create(:universe, name: 'Modern World', theme: 'modern') }
  let(:world) { create(:world, universe: universe, name: 'Earth') }
  let(:area) { create(:area, world: world, name: 'North America') }
  let(:location) do
    create(:location,
           zone: area,
           name: 'New York City',
           horizontal_streets: 10,
           vertical_streets: 10,
           max_building_height: 200)
  end

  # Create a street room for reference
  let(:street_room) do
    create(:room,
           location: location,
           name: '1st Street',
           room_type: 'street',
           grid_x: 0,
           grid_y: 0,
           city_role: 'street',
           street_name: '1st Street')
  end

  # Create an intersection room at grid position (2, 3)
  let(:intersection_room) do
    create(:room,
           location: location,
           name: '1st Street & 1st Avenue',
           room_type: 'intersection',
           grid_x: 2,
           grid_y: 3,
           city_role: 'intersection',
           min_x: 350,
           max_x: 375,
           min_y: 525,
           max_y: 550)
  end

  describe '.build_block' do
    context 'with apartment_tower type' do
      it 'creates a building room and interior floors' do
        rooms = described_class.build_block(
          location: location,
          intersection_room: intersection_room,
          building_type: :apartment_tower
        )

        expect(rooms).not_to be_empty
        building = rooms.first
        expect(building.building_type).to eq('apartment_tower')
        expect(building.city_role).to eq('building')
        expect(building.grid_x).to eq(2)
        expect(building.grid_y).to eq(3)
      end

      it 'creates hallway rooms including a lobby' do
        rooms = described_class.build_block(
          location: location,
          intersection_room: intersection_room,
          building_type: :apartment_tower
        )

        floor_rooms = rooms.select { |r| r.room_type == 'hallway' }
        expect(floor_rooms.length).to be > 0

        lobby = floor_rooms.find { |r| r.name.include?('Lobby') }
        expect(lobby).not_to be_nil
      end

      it 'creates apartment units via FloorPlanService templates' do
        rooms = described_class.build_block(
          location: location,
          intersection_room: intersection_room,
          building_type: :apartment_tower
        )

        apartments = rooms.select { |r| r.room_type == 'apartment' }
        expect(apartments.length).to be > 0
      end
    end

    context 'with brownstone type' do
      it 'creates a brownstone with interior rooms' do
        rooms = described_class.build_block(
          location: location,
          intersection_room: intersection_room,
          building_type: :brownstone
        )

        building = rooms.first
        expect(building.building_type).to eq('brownstone')

        # FloorPlanService brownstone templates create residence rooms
        # (Parlor, Kitchen, Bedroom, Study) across 3 floors
        residence_rooms = rooms.select { |r| r.room_type == 'residence' }
        expect(residence_rooms.length).to be >= 4
      end

      it 'creates rooms with appropriate names from templates' do
        rooms = described_class.build_block(
          location: location,
          intersection_room: intersection_room,
          building_type: :brownstone
        )

        interior_names = rooms[1..].map(&:name)
        # brownstone_ground template has Parlor and Kitchen
        expect(interior_names.any? { |n| n.include?('Parlor') }).to be true
        expect(interior_names.any? { |n| n.include?('Kitchen') }).to be true
        # brownstone_upper template has Bedroom and Study
        expect(interior_names.any? { |n| n.include?('Bedroom') }).to be true
      end
    end

    context 'with house type' do
      it 'creates a house with rooms from FloorPlanService templates' do
        rooms = described_class.build_block(
          location: location,
          intersection_room: intersection_room,
          building_type: :house
        )

        building = rooms.first
        expect(building.building_type).to eq('house')

        # house_ground has Kitchen + Living Room, house_upper has Bedroom + Second Bedroom
        residence_rooms = rooms.select { |r| r.room_type == 'residence' }
        expect(residence_rooms.length).to be >= 4

        room_names = residence_rooms.map(&:name)
        expect(room_names.any? { |n| n.include?('Living Room') }).to be true
        expect(room_names.any? { |n| n.include?('Bedroom') }).to be true
      end
    end

    context 'with shop type' do
      it 'creates a shop with interior rooms from FloorPlanService' do
        rooms = described_class.build_block(
          location: location,
          intersection_room: intersection_room,
          building_type: :shop
        )

        expect(rooms.length).to be >= 1
        expect(rooms.first.building_type).to eq('shop')

        # shop_single template creates Shop Floor and Back Room
        interior = rooms[1..]
        if interior.any?
          commercial_rooms = interior.select { |r| r.room_type == 'commercial' }
          expect(commercial_rooms.length).to be >= 1
        end
      end
    end

    context 'with park type' do
      it 'creates a park without interior rooms' do
        rooms = described_class.build_block(
          location: location,
          intersection_room: intersection_room,
          building_type: :park
        )

        expect(rooms.length).to eq(1)
        expect(rooms.first.building_type).to eq('park')
        expect(rooms.first.description).to include('park')
      end
    end

    context 'with mall type' do
      it 'creates mall with multiple floors of commercial rooms' do
        rooms = described_class.build_block(
          location: location,
          intersection_room: intersection_room,
          building_type: :mall
        )

        building = rooms.first
        expect(building.building_type).to eq('mall')

        # mall_floor template creates Atrium (hallway) + 6 Shops (commercial) per floor
        commercial_rooms = rooms.select { |r| r.room_type == 'commercial' }
        expect(commercial_rooms.length).to be > 3
      end
    end

    context 'with custom options' do
      it 'uses custom name when provided' do
        rooms = described_class.build_block(
          location: location,
          intersection_room: intersection_room,
          building_type: :apartment_tower,
          options: { name: 'The Grand Tower' }
        )

        expect(rooms.first.name).to eq('The Grand Tower')
      end

      it 'respects max_height option' do
        rooms = described_class.build_block(
          location: location,
          intersection_room: intersection_room,
          building_type: :apartment_tower,
          options: { max_height: 100 }
        )

        building = rooms.first
        expect(building.max_z).to be <= 100
      end
    end
  end

  describe '.create_building' do
    let(:bounds) do
      {
        min_x: 100, max_x: 200,
        min_y: 100, max_y: 200,
        min_z: 0, max_z: 100
      }
    end

    it 'creates a room with correct attributes' do
      building = described_class.create_building(
        location: location,
        parent_room: street_room,
        building_type: :shop,
        bounds: bounds,
        address: '123 Main Street'
      )

      expect(building).to be_a(Room)
      expect(building.location_id).to eq(location.id)
      expect(building.building_type).to eq('shop')
      expect(building.city_role).to eq('building')
      expect(building.min_x).to eq(100)
      expect(building.max_x).to eq(200)
    end

    it 'uses custom name when provided' do
      building = described_class.create_building(
        location: location,
        parent_room: street_room,
        building_type: :shop,
        bounds: bounds,
        address: '123 Main Street',
        name: 'Corner Deli'
      )

      expect(building.name).to eq('Corner Deli')
    end

    it 'generates appropriate default names' do
      building = described_class.create_building(
        location: location,
        parent_room: street_room,
        building_type: :apartment_tower,
        bounds: bounds,
        address: '500 Park Avenue'
      )

      expect(building.name).to eq('500 Park Avenue Apartments')
    end
  end

  describe '.populate_building' do
    let(:building) do
      create(:room,
             location: location,
             name: 'Test Tower',
             building_type: 'apartment_tower',
             grid_x: 0,
             grid_y: 0,
             min_x: 0, max_x: 100,
             min_y: 0, max_y: 100,
             min_z: 0, max_z: 50)
    end

    let(:bounds) do
      {
        min_x: 0, max_x: 100,
        min_y: 0, max_y: 100,
        min_z: 0, max_z: 50
      }
    end

    it 'creates rooms using FloorPlanService templates' do
      config = { floors: 3 }
      rooms = described_class.populate_building(
        building: building,
        building_type: :apartment_tower,
        config: config,
        bounds: bounds,
        location: location
      )

      expect(rooms).not_to be_empty

      # Should have hallway rooms from templates
      hallways = rooms.select { |r| r.room_type == 'hallway' }
      expect(hallways.length).to be > 0

      # Floor 0 uses apartment_lobby template (has Lobby hallway)
      lobby = hallways.find { |r| r.name.include?('Lobby') }
      expect(lobby).not_to be_nil
      expect(lobby.floor_number).to eq(0)
    end

    it 'creates apartment units on upper floors' do
      config = { floors: 3 }
      rooms = described_class.populate_building(
        building: building,
        building_type: :apartment_tower,
        config: config,
        bounds: bounds,
        location: location
      )

      apartments = rooms.select { |r| r.room_type == 'apartment' }
      # apartment_floor template has 4 units per floor, applied to floors 1 and 2
      expect(apartments.length).to eq(8)
    end

    it 'sets inside_room_id for all interior rooms' do
      config = { floors: 2 }
      rooms = described_class.populate_building(
        building: building,
        building_type: :apartment_tower,
        config: config,
        bounds: bounds,
        location: location
      )

      rooms.each do |room|
        expect(room.inside_room_id).to eq(building.id)
      end
    end

    it 'returns empty array for parks' do
      config = {}
      rooms = described_class.populate_building(
        building: building,
        building_type: :park,
        config: config,
        bounds: bounds,
        location: location
      )

      expect(rooms).to eq([])
    end
  end

  describe '.find_available_apartment' do
    before do
      # Create an apartment tower with units
      described_class.build_block(
        location: location,
        intersection_room: intersection_room,
        building_type: :apartment_tower
      )
    end

    it 'finds an available apartment' do
      apartment = described_class.find_available_apartment(location: location)
      expect(apartment).not_to be_nil
      expect(apartment.room_type).to eq('apartment')
    end

    it 'excludes lobby floor' do
      apartment = described_class.find_available_apartment(location: location)
      expect(apartment.floor_number).not_to eq(0)
    end

    it 'excludes already-owned apartments' do
      owned = Room.where(location_id: location.id, room_type: 'apartment').first
      owned.update(owner_id: create(:character).id)

      apartment = described_class.find_available_apartment(location: location)
      expect(apartment).not_to be_nil
      expect(apartment.id).not_to eq(owned.id)
      expect(apartment.owner_id).to be_nil
    end
  end

  describe '.assign_to_character' do
    let(:character) { create(:character) }
    let(:apartment_room) { create(:room, room_type: 'apartment', owner_id: nil) }

    it 'assigns unowned rooms' do
      success = described_class.assign_to_character(room: apartment_room, character: character)
      expect(success).to be true
      expect(apartment_room.refresh.owner_id).to eq(character.id)
    end

    it 'does not overwrite another owner' do
      apartment_room.update(owner_id: create(:character).id)

      success = described_class.assign_to_character(room: apartment_room, character: character)
      expect(success).to be false
      expect(apartment_room.refresh.owner_id).not_to eq(character.id)
    end
  end

  describe 'building descriptions' do
    it 'generates appropriate descriptions for each type' do
      types = [:apartment_tower, :brownstone, :house, :shop, :park, :mall]

      types.each do |type|
        rooms = described_class.build_block(
          location: location,
          intersection_room: intersection_room,
          building_type: type
        )

        building = rooms.first
        expect(building.description).not_to be_nil
        expect(building.description.length).to be > 10
      end
    end
  end

  describe 'lot-aware building' do
    it 'uses provided lot_bounds instead of full block' do
      lot = { min_x: 25, max_x: 95, min_y: 25, max_y: 95, min_z: 0, max_z: 30 }
      rooms = described_class.build_block(
        location: location,
        intersection_room: intersection_room,
        building_type: :shop,
        options: { lot_bounds: lot }
      )
      building = rooms.first
      expect(building.min_x).to eq(25)
      expect(building.max_x).to eq(95)
      expect(building.min_y).to eq(25)
      expect(building.max_y).to eq(95)
    end

    it 'caps lot_bounds height by building config height' do
      lot = { min_x: 25, max_x: 95, min_y: 25, max_y: 95, min_z: 0, max_z: 500 }
      rooms = described_class.build_block(
        location: location,
        intersection_room: intersection_room,
        building_type: :shop,
        options: { lot_bounds: lot }
      )
      building = rooms.first
      config = GridCalculationService.building_config(:shop)
      expect(building.max_z).to be <= config[:height]
    end

    it 'creates alleys when auto-subdividing for small buildings' do
      rooms = described_class.build_block(
        location: location,
        intersection_room: intersection_room,
        building_type: :shop
      )
      alleys = Room.where(
        location_id: location.id,
        grid_x: intersection_room.grid_x,
        grid_y: intersection_room.grid_y,
        room_type: 'alley'
      ).all
      expect(alleys.length).to be > 0
    end

    it 'does not create duplicate alleys on subsequent builds' do
      # Build first shop - creates alleys
      described_class.build_block(
        location: location,
        intersection_room: intersection_room,
        building_type: :shop
      )
      first_alley_count = Room.where(
        location_id: location.id,
        grid_x: intersection_room.grid_x,
        grid_y: intersection_room.grid_y,
        room_type: 'alley'
      ).count

      # Build second shop - should NOT create more alleys
      described_class.build_block(
        location: location,
        intersection_room: intersection_room,
        building_type: :shop
      )
      second_alley_count = Room.where(
        location_id: location.id,
        grid_x: intersection_room.grid_x,
        grid_y: intersection_room.grid_y,
        room_type: 'alley'
      ).count

      expect(second_alley_count).to eq(first_alley_count)
    end

    it 'does not create alleys for full-block buildings' do
      rooms = described_class.build_block(
        location: location,
        intersection_room: intersection_room,
        building_type: :palace
      )
      alleys = Room.where(
        location_id: location.id,
        grid_x: intersection_room.grid_x,
        grid_y: intersection_room.grid_y,
        room_type: 'alley'
      ).all
      expect(alleys.length).to eq(0)
    end

    it 'places building within lot bounds not full block bounds' do
      rooms = described_class.build_block(
        location: location,
        intersection_room: intersection_room,
        building_type: :shop
      )
      building = rooms.first

      # Block bounds from GridCalculationService for grid_x: 2, grid_y: 3
      block_bounds = GridCalculationService.block_bounds(
        intersection_x: intersection_room.grid_x,
        intersection_y: intersection_room.grid_y
      )

      # The building should be smaller than the full block (it occupies a quarter lot)
      building_width = building.max_x - building.min_x
      block_width = block_bounds[:max_x] - block_bounds[:min_x]
      expect(building_width).to be < block_width
    end
  end


  describe 'vacant lots' do
    it 'creates an outdoor room for vacant lots' do
      rooms = described_class.build_block(
        location: location,
        intersection_room: intersection_room,
        building_type: :vacant_lot
      )
      expect(rooms.length).to eq(1)
      expect(rooms.first.room_type).to eq('outdoor')
      expect(rooms.first.city_role).to eq('vacant_lot')
      expect(rooms.first.name).to eq('Vacant Lot')
    end

    it 'also works with :vacant symbol' do
      rooms = described_class.build_block(
        location: location,
        intersection_room: intersection_room,
        building_type: :vacant
      )
      expect(rooms.length).to eq(1)
      expect(rooms.first.room_type).to eq('outdoor')
    end

    it 'does not create interior rooms for vacant lots' do
      rooms = described_class.build_block(
        location: location,
        intersection_room: intersection_room,
        building_type: :vacant_lot
      )
      expect(rooms.length).to eq(1)
      expect(rooms.first.description).to include('empty lot')
    end
  end

end
