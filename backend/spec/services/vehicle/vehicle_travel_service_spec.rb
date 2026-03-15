# frozen_string_literal: true

require 'spec_helper'

RSpec.describe VehicleTravelService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:zone, world: world) }
  let(:location) { create(:location, zone: zone) }
  let(:reality) { create(:reality) }

  # Streets are spatially adjacent: street1 -> street2 -> destination (north)
  # street1: y=0-100, street2: y=100-200, destination: y=200-300
  # Streets must be outdoors (indoors: false) for spatial passability
  let(:street1) { create(:room, room_type: 'street', name: 'Oak Street', location: location, min_y: 0.0, max_y: 100.0, indoors: false) }
  let(:street2) { create(:room, room_type: 'street', name: 'Maple Avenue', location: location, min_y: 100.0, max_y: 200.0, indoors: false) }
  let(:destination) { create(:room, room_type: 'street', name: 'Pine Boulevard', location: location, min_y: 200.0, max_y: 300.0, indoors: false) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: street1,
           reality: reality)
  end

  let(:vehicle) do
    Vehicle.create(
      char_id: character.id,
      room_id: street1.id,
      name: 'Test Car',
      parked: true,
      condition: 100,
      max_passengers: 4
    )
  end

  describe '.start_journey' do
    context 'with owned vehicle' do
      before do
        # Ensure all streets exist for pathfinding (eager creation)
        street1
        street2
        destination
        # Stub TimedAction to avoid background job issues
        allow(TimedAction).to receive(:start_delayed).and_return(double('TimedAction', id: 1))
      end

      it 'creates a CityJourney with the vehicle' do
        result = described_class.start_journey(
          character_instance,
          destination: destination,
          vehicle: vehicle
        )

        expect(result[:success]).to be true
        journey = CityJourney.first(driver_id: character_instance.id)
        expect(journey).not_to be_nil
        expect(journey.vehicle_id).to eq(vehicle.id)
        expect(journey.traveling?).to be true
      end

      it 'calculates the route' do
        described_class.start_journey(
          character_instance,
          destination: destination,
          vehicle: vehicle
        )

        journey = CityJourney.first(driver_id: character_instance.id)
        expect(journey.route).not_to be_empty
      end

      it 'returns journey data' do
        result = described_class.start_journey(
          character_instance,
          destination: destination,
          vehicle: vehicle
        )

        expect(result[:success]).to be true
        expect(result[:data][:journey_id]).not_to be_nil
        expect(result[:data][:destination]).to eq('Pine Boulevard')
      end
    end

    context 'with taxi' do
      before do
        # Ensure all streets exist for pathfinding (eager creation)
        street1
        street2
        destination
        allow(TimedAction).to receive(:start_delayed).and_return(double('TimedAction', id: 1))
      end

      it 'creates a CityJourney without vehicle' do
        result = described_class.start_journey(
          character_instance,
          destination: destination,
          vehicle: nil
        )

        expect(result[:success]).to be true
        journey = CityJourney.first(driver_id: character_instance.id)
        expect(journey.taxi?).to be true
      end
    end

    context 'when route cannot be found' do
      let(:isolated_location) { create(:location, zone: zone) }
      let(:isolated_room) { create(:room, room_type: 'standard', name: 'Isolated Room', location: isolated_location, min_y: 9000.0, max_y: 9100.0) }

      it 'returns an error' do
        result = described_class.start_journey(
          character_instance,
          destination: isolated_room,
          vehicle: vehicle
        )

        expect(result[:success]).to be false
        expect(result[:message]).to include("Can't find a street route")
      end
    end

    context 'when character has no current room' do
      it 'returns an error' do
        # Mock the character instance to have no current room
        allow(character_instance).to receive(:current_room).and_return(nil)

        result = described_class.start_journey(
          character_instance,
          destination: destination,
          vehicle: vehicle
        )

        expect(result[:success]).to be false
        expect(result[:message]).to include('need to be somewhere')
      end
    end
  end

  describe '.calculate_route_distance' do
    before do
      # Ensure all streets exist for pathfinding
      street1
      street2
      destination
    end

    it 'returns total distance in feet' do
      distance = described_class.calculate_route_distance(street1, destination)
      expect(distance).to be > 0
    end

    it 'returns 0 for unreachable destinations' do
      isolated_location = create(:location, zone: zone)
      isolated_room = create(:room, room_type: 'standard', name: 'Isolated Room', location: isolated_location, min_y: 9000.0, max_y: 9100.0)
      distance = described_class.calculate_route_distance(street1, isolated_room)
      expect(distance).to eq(0)
    end
  end

  describe '.estimate_travel_time' do
    it 'returns estimated travel time in seconds' do
      # 3600 feet at ~36 fps = 100 seconds
      time = described_class.estimate_travel_time(3600)
      expect(time).to eq(100)
    end
  end

  describe '.estimate_walking_time' do
    it 'returns longer time than driving' do
      distance = 1000
      driving_time = described_class.estimate_travel_time(distance)
      walking_time = described_class.estimate_walking_time(distance)

      expect(walking_time).to be > driving_time
    end
  end

  describe '.complete_journey' do
    let(:journey) do
      CityJourney.create(
        driver_id: character_instance.id,
        destination_room_id: destination.id,
        route: [street1.id, street2.id, destination.id],
        current_index: 2,
        status: 'traveling',
        started_at: Time.now
      )
    end

    it 'moves driver to destination' do
      described_class.complete_journey(journey)

      character_instance.refresh
      expect(character_instance.current_room_id).to eq(destination.id)
    end

    it 'marks journey as arrived' do
      described_class.complete_journey(journey)

      journey.refresh
      expect(journey.arrived?).to be true
    end

    context 'with vehicle' do
      let(:journey_with_vehicle) do
        CityJourney.create(
          driver_id: character_instance.id,
          vehicle_id: vehicle.id,
          destination_room_id: destination.id,
          route: [street1.id, street2.id, destination.id],
          current_index: 2,
          status: 'traveling',
          started_at: Time.now
        )
      end

      before do
        # Board the vehicle first
        character_instance.update(current_vehicle_id: vehicle.id)
        vehicle.update(parked: false)
      end

      it 'parks the vehicle at destination' do
        described_class.complete_journey(journey_with_vehicle)

        vehicle.refresh
        expect(vehicle.parked?).to be true
        expect(vehicle.room_id).to eq(destination.id)
      end
    end
  end
end
