# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Vehicle Travel Integration', type: :integration do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }

  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: street1, reality: reality, online: true) }
  let!(:vehicle) { create(:vehicle, owner: character, current_room: street1, parked: true, name: 'Test Car') }

  # Streets are spatially adjacent: street1 -> street2 -> street3 (north)
  # street1: y=0-100, street2: y=100-200, street3: y=200-300
  # Streets must be outdoors (indoors: false) for spatial passability
  let(:street1) { create(:room, location: location, room_type: 'street', name: 'Start Street', min_y: 0.0, max_y: 100.0, indoors: false) }
  let(:street2) { create(:room, location: location, room_type: 'street', name: 'Middle Street', min_y: 100.0, max_y: 200.0, indoors: false) }
  let(:street3) { create(:room, location: location, room_type: 'street', name: 'End Street', min_y: 200.0, max_y: 300.0, indoors: false) }

  # Ensure all streets exist before any test runs
  before do
    street1
    street2
    street3
  end

  def execute_drive_command(args, ci = character_instance)
    command = Commands::Vehicles::Drive.new(ci)
    input = args.nil? ? 'drive' : "drive #{args}"
    command.execute(input)
  end

  describe 'drive command journey' do
    it 'moves character through streets to destination' do
      # Start the journey
      result = execute_drive_command('to End Street')
      expect(result[:success]).to be true

      # Verify journey created
      journey = CityJourney.first(driver_id: character_instance.id)
      expect(journey).not_to be_nil
      expect(journey.traveling?).to be true

      # Test route: street1 -> street2 -> street3 (3 rooms)
      # Need (route.length - 1) = 2 advances to reach destination
      # Each advance moves current_index forward and checks for completion
      advances_needed = journey.route.length - 1
      advances_needed.times do
        VehicleTravelService.advance_journey(journey.id)
        journey.refresh
      end

      # Verify arrival
      expect(journey.arrived?).to be true
      character_instance.refresh
      expect(character_instance.current_room_id).to eq(street3.id)

      # Verify vehicle parked at destination
      vehicle.refresh
      expect(vehicle.room_id).to eq(street3.id)
      expect(vehicle.parked?).to be true
    end

    it 'creates journey with correct route' do
      result = execute_drive_command('to End Street')
      expect(result[:success]).to be true

      journey = CityJourney.first(driver_id: character_instance.id)
      expect(journey.route).to include(street1.id)
      expect(journey.route).to include(street2.id)
      expect(journey.route).to include(street3.id)
      expect(journey.destination_room_id).to eq(street3.id)
    end

    it 'returns journey data in result' do
      result = execute_drive_command('to End Street')
      expect(result[:success]).to be true
      expect(result[:data]).to include(:journey_id)
      expect(result[:data][:destination]).to eq('End Street')
    end
  end

  describe 'walk to vehicle (movement target resolution)' do
    before do
      vehicle.update(room_id: street3.id)
      character_instance.update(current_room_id: street1.id)
    end

    it 'resolves "car" to vehicle location room' do
      result = TargetResolverService.resolve_movement_target('car', character_instance)

      expect(result.type).to eq(:room)
      expect(result.target.id).to eq(street3.id)
    end

    it 'resolves specific vehicle name to location room' do
      result = TargetResolverService.resolve_movement_target('Test Car', character_instance)

      expect(result.type).to eq(:room)
      expect(result.target.id).to eq(street3.id)
    end
  end

  describe 'vehicle state transitions' do
    it 'vehicle becomes moving when journey starts' do
      expect(vehicle.parked?).to be true

      execute_drive_command('to End Street')
      vehicle.refresh

      expect(vehicle.parked?).to be false
      expect(vehicle.moving?).to be true
    end

    it 'vehicle is parked after journey completes' do
      execute_drive_command('to End Street')
      journey = CityJourney.first(driver_id: character_instance.id)

      # Test route: street1 -> street2 -> street3 (3 rooms)
      # Need (route.length - 1) = 2 advances to complete journey
      advances_needed = journey.route.length - 1
      advances_needed.times do
        VehicleTravelService.advance_journey(journey.id)
        journey.refresh
      end

      vehicle.refresh
      expect(vehicle.parked?).to be true
      expect(vehicle.room_id).to eq(street3.id)
    end
  end

  describe 'error handling' do
    it 'fails gracefully when destination unreachable' do
      # Create isolated room far away (not adjacent to any existing streets)
      # street1-3 use y=0-300, so place this at y=1000-1100 to be isolated
      isolated_room = create(:room, location: location, room_type: 'street', name: 'Isolated Street',
                             min_y: 1000.0, max_y: 1100.0, indoors: false)

      result = execute_drive_command('to Isolated Street')

      # Should fail - no route to isolated room
      expect(result[:success]).to be false
    end

    it 'fails when vehicle not present' do
      vehicle.update(room_id: street3.id)

      result = execute_drive_command('to Middle Street')

      expect(result[:success]).to be false
      expect(result[:message]).to include('not here')
    end

    it 'fails when no vehicle owned' do
      vehicle.destroy

      result = execute_drive_command('to Middle Street')

      expect(result[:success]).to be false
      expect(result[:message]).to include('vehicle')
    end
  end
end
