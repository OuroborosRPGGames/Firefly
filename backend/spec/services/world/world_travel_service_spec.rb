# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldTravelService do
  let(:world) { create(:world) }
  let(:zone) { create(:zone, world: world) }

  # Create globe hexes with sequential IDs and lat/lon coordinates
  let!(:hex_1) { WorldHex.create(world: world, globe_hex_id: 1, terrain_type: 'grassy_plains', latitude: 0.0, longitude: 0.0) }
  let!(:hex_2) { WorldHex.create(world: world, globe_hex_id: 2, terrain_type: 'grassy_plains', latitude: 0.5, longitude: 0.0) }
  let!(:hex_3) { WorldHex.create(world: world, globe_hex_id: 3, terrain_type: 'grassy_plains', latitude: 1.0, longitude: 0.0) }
  let!(:hex_4) { WorldHex.create(world: world, globe_hex_id: 4, terrain_type: 'grassy_plains', latitude: 1.5, longitude: 0.0) }
  let!(:hex_5) { WorldHex.create(world: world, globe_hex_id: 5, terrain_type: 'grassy_plains', latitude: 2.0, longitude: 0.0) }

  let(:origin_location) { create(:location, zone: zone, world: world, globe_hex_id: 1) }
  let(:destination_location) { create(:location, zone: zone, world: world, globe_hex_id: 5) }
  let(:origin_room) { create(:room, location: origin_location) }
  let(:destination_room) { create(:room, location: destination_location) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room_id: origin_room.id) }

  describe 'class methods' do
    it 'responds to start_journey' do
      expect(described_class).to respond_to(:start_journey)
    end

    it 'responds to board_journey' do
      expect(described_class).to respond_to(:board_journey)
    end

    it 'responds to disembark' do
      expect(described_class).to respond_to(:disembark)
    end

    it 'responds to journey_eta' do
      expect(described_class).to respond_to(:journey_eta)
    end

    it 'responds to estimate_arrival_time' do
      expect(described_class).to respond_to(:estimate_arrival_time)
    end

    it 'responds to cancel_journey' do
      expect(described_class).to respond_to(:cancel_journey)
    end

    it 'responds to journey_status' do
      expect(described_class).to respond_to(:journey_status)
    end

    it 'responds to calculate_route' do
      expect(described_class).to respond_to(:calculate_route)
    end
  end

  describe '.start_journey' do
    context 'with valid locations' do
      before do
        # Mock the pathfinding to return a simple path of globe_hex_ids
        allow(GlobePathfindingService).to receive(:find_path).and_return([1, 2, 3, 4, 5])
      end

      it 'creates a journey with globe_hex_ids' do
        result = described_class.start_journey(character_instance, destination: destination_location)

        expect(result[:success]).to be true
        journey = result[:journey]
        expect(journey.current_globe_hex_id).to eq(1)
        expect(journey.path_remaining).to respond_to(:to_a)
        expect(journey.path_remaining.to_a).to eq([2, 3, 4, 5])
      end

      it 'stores the destination location' do
        result = described_class.start_journey(character_instance, destination: destination_location)

        expect(result[:success]).to be true
        journey = result[:journey]
        expect(journey.destination_location_id).to eq(destination_location.id)
      end
    end

    context 'when origin lacks globe_hex_id' do
      let(:origin_location) { create(:location, zone: zone, world: world, globe_hex_id: nil) }

      it 'returns an error' do
        result = described_class.start_journey(character_instance, destination: destination_location)

        expect(result[:success]).to be false
        expect(result[:error]).to include('world coordinates')
      end
    end

    context 'when destination lacks globe_hex_id' do
      let(:destination_location) { create(:location, zone: zone, world: world, globe_hex_id: nil) }

      it 'returns an error' do
        result = described_class.start_journey(character_instance, destination: destination_location)

        expect(result[:success]).to be false
        expect(result[:error]).to include('world coordinates')
      end
    end

    context 'when character is already traveling' do
      let!(:existing_journey) do
        create(:world_journey,
               world: world,
               origin_location: origin_location,
               destination_location: destination_location,
               status: 'traveling')
      end

      before do
        character_instance.update(current_world_journey_id: existing_journey.id)
      end

      it 'returns an error' do
        result = described_class.start_journey(character_instance, destination: destination_location)

        expect(result[:success]).to be false
        expect(result[:error]).to include('already on a journey')
      end
    end
  end

  describe '.cancel_journey' do
    context 'when character is not traveling' do
      it 'returns an error' do
        result = described_class.cancel_journey(character_instance)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('You are not currently on a journey.')
      end
    end

    context 'when character is traveling' do
      let!(:journey) do
        create(:world_journey,
               world: world,
               origin_location: origin_location,
               destination_location: destination_location,
               current_globe_hex_id: 2,
               status: 'traveling')
      end

      let!(:passenger) do
        create(:world_journey_passenger,
               world_journey: journey,
               character_instance: character_instance,
               is_driver: true)
      end

      before do
        character_instance.update(current_world_journey_id: journey.id)
      end

      it 'cancels the journey' do
        result = described_class.cancel_journey(character_instance)

        expect(result[:success]).to be true
        expect(result[:message]).to include('cancel')
      end

      it 'updates journey status to cancelled' do
        described_class.cancel_journey(character_instance)

        journey.reload
        expect(journey.status).to eq('cancelled')
      end
    end

    context 'when non-driver tries to cancel with multiple passengers' do
      let!(:journey) do
        create(:world_journey,
               world: world,
               origin_location: origin_location,
               destination_location: destination_location,
               current_globe_hex_id: 2,
               status: 'traveling')
      end

      let(:driver) { create(:character_instance) }
      let!(:driver_passenger) do
        create(:world_journey_passenger,
               world_journey: journey,
               character_instance: driver,
               is_driver: true)
      end

      let!(:passenger) do
        create(:world_journey_passenger,
               world_journey: journey,
               character_instance: character_instance,
               is_driver: false)
      end

      before do
        character_instance.update(current_world_journey_id: journey.id)
      end

      it 'returns an error' do
        result = described_class.cancel_journey(character_instance)

        expect(result[:success]).to be false
        expect(result[:error]).to include('can cancel this journey')
      end
    end
  end

  describe '.journey_status' do
    context 'when journey is nil' do
      it 'returns nil' do
        expect(described_class.journey_status(nil)).to be_nil
      end
    end

    context 'when journey exists' do
      let!(:journey) do
        create(:world_journey,
               world: world,
               origin_location: origin_location,
               destination_location: destination_location,
               current_globe_hex_id: 2,
               status: 'traveling',
               travel_mode: 'land',
               vehicle_type: 'car')
      end

      it 'returns comprehensive status information' do
        status = described_class.journey_status(journey)

        expect(status[:id]).to eq(journey.id)
        expect(status[:status]).to eq('traveling')
        expect(status[:traveling]).to be true
        expect(status[:arrived]).to be false
        expect(status[:current_globe_hex_id]).to eq(2)
        expect(status[:destination][:name]).to eq(destination_location.name)
        expect(status[:destination][:globe_hex_id]).to eq(5)
        expect(status[:origin][:name]).to eq(origin_location.name)
        expect(status[:vehicle]).to eq('car')
        expect(status[:travel_mode]).to eq('land')
      end
    end
  end

  describe '.calculate_route' do
    context 'when origin has no globe_hex_id' do
      let(:no_hex_location) { create(:location, zone: zone, world: world, globe_hex_id: nil) }

      it 'returns an error' do
        result = described_class.calculate_route(
          origin: no_hex_location,
          destination: destination_location
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('no world coordinates')
        expect(result[:routes]).to eq([])
      end
    end

    context 'when destination has no globe_hex_id' do
      let(:no_hex_location) { create(:location, zone: zone, world: world, globe_hex_id: nil) }

      it 'returns an error' do
        result = described_class.calculate_route(
          origin: origin_location,
          destination: no_hex_location
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('no world coordinates')
      end
    end

    context 'when locations are in different worlds' do
      let(:other_world) { create(:world) }
      let(:other_zone) { create(:zone, world: other_world) }
      let!(:other_hex) { WorldHex.create(world: other_world, globe_hex_id: 100, terrain_type: 'grassy_plains', latitude: 0.0, longitude: 0.0) }
      let(:other_location) { create(:location, zone: other_zone, world: other_world, globe_hex_id: 100) }

      it 'returns an error' do
        result = described_class.calculate_route(
          origin: origin_location,
          destination: other_location
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('different worlds')
      end
    end

    context 'when valid route exists' do
      before do
        allow(GlobePathfindingService).to receive(:find_path).and_return([1, 2, 3, 4, 5])
      end

      it 'returns route options' do
        result = described_class.calculate_route(
          origin: origin_location,
          destination: destination_location
        )

        expect(result[:success]).to be true
        expect(result[:routes]).to be_an(Array)
        expect(result[:routes]).not_to be_empty
      end

      it 'includes route details' do
        result = described_class.calculate_route(
          origin: origin_location,
          destination: destination_location
        )

        route = result[:routes].first
        expect(route[:travel_mode]).not_to be_nil
        expect(route[:vehicle]).not_to be_nil
        expect(route[:path_length]).to eq(4) # 5 hexes - 1 for starting position
        expect(route[:estimated_seconds]).to be_a(Integer)
        expect(route[:estimated_time]).to be_a(String)
      end

      it 'includes path preview with globe_hex_ids' do
        result = described_class.calculate_route(
          origin: origin_location,
          destination: destination_location
        )

        route = result[:routes].first
        expect(route[:path_preview]).to be_an(Array)
        expect(route[:path_preview].first[:globe_hex_id]).to eq(1)
      end
    end
  end

  describe '.plan_journey_segments' do
    # Create hexes in a line for testing
    let!(:hex_1) { WorldHex.create(world: world, globe_hex_id: 1, terrain_type: 'urban', latitude: 0.0, longitude: 0.0) }
    let!(:hex_2) { WorldHex.create(world: world, globe_hex_id: 2, terrain_type: 'grassy_plains', latitude: 0.5, longitude: 0.0) }
    let!(:hex_3) { WorldHex.create(world: world, globe_hex_id: 3, terrain_type: 'grassy_plains', latitude: 1.0, longitude: 0.0) }
    let!(:hex_4) { WorldHex.create(world: world, globe_hex_id: 4, terrain_type: 'grassy_plains', latitude: 1.5, longitude: 0.0) }
    let!(:hex_5) { WorldHex.create(world: world, globe_hex_id: 5, terrain_type: 'urban', latitude: 2.0, longitude: 0.0) }

    let(:origin_location) { create(:location, zone: zone, world: world, globe_hex_id: 1) }
    let(:destination_location) { create(:location, zone: zone, world: world, globe_hex_id: 5) }

    context 'when travel_mode is land' do
      before do
        allow(GlobePathfindingService).to receive(:find_path).and_return([1, 2, 3, 4, 5])
      end

      it 'creates single land segment' do
        segments = described_class.plan_journey_segments(
          origin: origin_location,
          destination: destination_location,
          travel_mode: 'land'
        )

        expect(segments.length).to eq(1)
        expect(segments[0][:mode]).to eq('land')
        expect(segments[0][:path]).to eq([1, 2, 3, 4, 5])
      end
    end

    context 'when no path exists' do
      before do
        allow(GlobePathfindingService).to receive(:find_path).and_return([])
      end

      it 'returns empty segments array' do
        segments = described_class.plan_journey_segments(
          origin: origin_location,
          destination: destination_location,
          travel_mode: 'land'
        )

        expect(segments).to eq([])
      end
    end
  end

  describe '.start_journey with segments' do
    let!(:hex_1) { WorldHex.create(world: world, globe_hex_id: 1, terrain_type: 'urban', latitude: 0.0, longitude: 0.0) }
    let!(:hex_2) { WorldHex.create(world: world, globe_hex_id: 2, terrain_type: 'grassy_plains', latitude: 0.5, longitude: 0.0) }
    let!(:hex_3) { WorldHex.create(world: world, globe_hex_id: 3, terrain_type: 'grassy_plains', latitude: 1.0, longitude: 0.0) }
    let!(:hex_4) { WorldHex.create(world: world, globe_hex_id: 4, terrain_type: 'grassy_plains', latitude: 1.5, longitude: 0.0) }
    let!(:hex_5) { WorldHex.create(world: world, globe_hex_id: 5, terrain_type: 'urban', latitude: 2.0, longitude: 0.0) }

    let(:origin_location) { create(:location, zone: zone, world: world, globe_hex_id: 1, has_train_station: true) }
    let(:destination_location) { create(:location, zone: zone, world: world, globe_hex_id: 5) }
    let(:origin_room) { create(:room, location: origin_location) }
    let(:character) { create(:character) }
    let(:character_instance) { create(:character_instance, character: character, current_room_id: origin_room.id) }

    before do
      # Mock pathfinding to return a path
      allow(GlobePathfindingService).to receive(:find_path).and_return([1, 2, 3, 4, 5])
    end

    it 'creates journey with segments field' do
      result = described_class.start_journey(
        character_instance,
        destination: destination_location,
        travel_mode: 'land'
      )

      expect(result[:success]).to be true
      journey = result[:journey]
      # segments is a JSONB array - check it responds to array methods
      expect(journey.segments).to respond_to(:length)
      expect(journey.segments).to respond_to(:first)
      expect(journey.segments.length).to be >= 1
    end

    it 'stores current_segment_index starting at 0' do
      result = described_class.start_journey(
        character_instance,
        destination: destination_location,
        travel_mode: 'land'
      )

      expect(result[:success]).to be true
      journey = result[:journey]
      expect(journey.current_segment_index).to eq(0)
    end

    it 'uses first segment mode as travel_mode' do
      result = described_class.start_journey(
        character_instance,
        destination: destination_location,
        travel_mode: 'land'
      )

      expect(result[:success]).to be true
      journey = result[:journey]
      expect(journey.travel_mode).to eq('land')
    end

    context 'when no viable route exists' do
      before do
        allow(GlobePathfindingService).to receive(:find_path).and_return([])
      end

      it 'returns error when segments are empty' do
        result = described_class.start_journey(
          character_instance,
          destination: destination_location,
          travel_mode: 'land'
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('No viable route')
      end
    end
  end

  describe '.board_journey' do
    let!(:journey) do
      create(:world_journey,
             world: world,
             origin_location: origin_location,
             destination_location: destination_location,
             current_globe_hex_id: 1,  # Journey is at hex 1
             status: 'traveling')
    end

    context 'when character is at the same hex as the journey' do
      it 'allows boarding' do
        result = described_class.board_journey(character_instance, journey)

        expect(result[:success]).to be true
        expect(result[:message]).to include('board')
      end
    end

    context 'when character is at a different hex' do
      let(:other_location) { create(:location, zone: zone, world: world, globe_hex_id: 99) }
      let(:other_room) { create(:room, location: other_location) }
      let(:other_character_instance) { create(:character_instance, current_room_id: other_room.id) }

      before do
        # Create a hex for the other location
        WorldHex.create(world: world, globe_hex_id: 99, terrain_type: 'urban', latitude: 50.0, longitude: 50.0)
      end

      it 'returns an error' do
        result = described_class.board_journey(other_character_instance, journey)

        expect(result[:success]).to be false
        expect(result[:error]).to include('not at the same location')
      end
    end

    context 'when character location has no globe_hex_id' do
      let(:no_hex_location) { create(:location, zone: zone, world: world, globe_hex_id: nil) }
      let(:no_hex_room) { create(:room, location: no_hex_location) }
      let(:no_hex_character) { create(:character_instance, current_room_id: no_hex_room.id) }

      it 'returns an error' do
        result = described_class.board_journey(no_hex_character, journey)

        expect(result[:success]).to be false
        expect(result[:error]).to include('cannot board from here')
      end
    end
  end

  describe '.disembark' do
    let!(:journey) do
      create(:world_journey,
             world: world,
             origin_location: origin_location,
             destination_location: destination_location,
             current_globe_hex_id: 3,  # Journey is at hex 3
             status: 'traveling')
    end

    let!(:passenger) do
      create(:world_journey_passenger,
             world_journey: journey,
             character_instance: character_instance,
             is_driver: true)
    end

    before do
      character_instance.update(current_world_journey_id: journey.id)
    end

    it 'creates waypoint room at current globe hex' do
      result = described_class.disembark(character_instance)

      expect(result[:success]).to be true
      expect(result[:room]).not_to be_nil

      # The waypoint room should be created at a location with globe_hex_id 3
      room = result[:room]
      expect(room.location.globe_hex_id).to eq(3)
    end

    it 'uses journey.cancel! when the last passenger disembarks' do
      expect_any_instance_of(WorldJourney).to receive(:cancel!)
        .with(reason: 'All passengers disembarked')
        .and_call_original

      described_class.disembark(character_instance)
    end
  end
end
