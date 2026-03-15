# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JourneyService do
  let(:world) { create(:world) }
  let(:origin_location) { create(:location, world: world, globe_hex_id: 1, latitude: 0.0, longitude: 0.0, name: 'Origin City') }
  let(:destination_location) { create(:location, world: world, globe_hex_id: 2, latitude: 10.0, longitude: 0.0, name: 'Dest City') }
  let(:origin_room) { create(:room, location: origin_location) }
  let(:dest_room) { create(:room, location: destination_location) }

  let(:character) { create(:character) }
  let(:char_instance) { create(:character_instance, character: character, current_room: origin_room) }

  before do
    # Mock era for world since it doesn't have that attribute
    allow_any_instance_of(World).to receive(:era).and_return('modern')
  end

  describe '.travel_options' do
    # Note: JourneyService.travel_options calls WorldTravelService.default_vehicle_for_mode
    # which is a private method. We test at a higher level.

    context 'with missing globe hex coords' do
      let(:no_hex_location) { create(:location, world: world, globe_hex_id: nil) }

      it 'returns error for destination without coords' do
        result = described_class.travel_options(char_instance, no_hex_location)
        expect(result[:success]).to be false
        expect(result[:error]).to include('coordinates')
      end
    end

    context 'at same location' do
      it 'returns error' do
        result = described_class.travel_options(char_instance, origin_location)
        expect(result[:success]).to be false
        expect(result[:error]).to include('already at this location')
      end
    end

    context 'with flashback error' do
      before do
        allow(FlashbackTravelService).to receive(:travel_options).and_return(
          error: 'Not enough flashback time'
        )
      end

      it 'returns the error' do
        result = described_class.travel_options(char_instance, destination_location)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Not enough flashback time')
      end
    end
  end

  describe '.start_journey' do
    context 'with flashback mode' do
      before do
        allow(FlashbackTravelService).to receive(:start_flashback_journey).and_return(
          success: true, message: 'Flashback travel started'
        )
      end

      it 'uses FlashbackTravelService for basic mode' do
        expect(FlashbackTravelService).to receive(:start_flashback_journey)
          .with(char_instance, destination: destination_location, mode: :basic)

        described_class.start_journey(char_instance, destination: destination_location, flashback_mode: :basic)
      end

      it 'uses FlashbackTravelService for return mode' do
        expect(FlashbackTravelService).to receive(:start_flashback_journey)
          .with(char_instance, destination: destination_location, mode: :return)

        described_class.start_journey(char_instance, destination: destination_location, flashback_mode: 'return')
      end

      it 'uses FlashbackTravelService for backloaded mode' do
        expect(FlashbackTravelService).to receive(:start_flashback_journey)
          .with(char_instance, destination: destination_location, mode: :backloaded)

        described_class.start_journey(char_instance, destination: destination_location, flashback_mode: :backloaded)
      end
    end

    context 'without flashback mode' do
      before do
        allow(WorldTravelService).to receive(:start_journey).and_return(
          success: true, message: 'Journey started'
        )
      end

      it 'uses WorldTravelService' do
        expect(WorldTravelService).to receive(:start_journey)
          .with(char_instance, destination: destination_location, travel_mode: 'land')

        described_class.start_journey(char_instance, destination: destination_location, travel_mode: 'land')
      end

      it 'handles nil flashback_mode' do
        expect(WorldTravelService).to receive(:start_journey)

        described_class.start_journey(char_instance, destination: destination_location, flashback_mode: nil)
      end
    end
  end

  describe '.start_party_journey' do
    let(:other_char) { create(:character) }
    let(:other_instance) { create(:character_instance, character: other_char, current_room: origin_room) }
    let(:travelers) { [char_instance, other_instance] }

    it 'returns error for empty travelers' do
      result = described_class.start_party_journey(
        travelers: [],
        destination: destination_location
      )
      expect(result[:success]).to be false
      expect(result[:error]).to eq('No travelers specified')
    end

    context 'with flashback mode return' do
      before do
        allow(char_instance).to receive(:flashback_time_available).and_return(7200)
        allow(other_instance).to receive(:flashback_time_available).and_return(7200)
        allow(FlashbackTravelService).to receive(:estimate_journey_time).and_return(3600)
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage_with_available).and_return(
          success: true,
          reserved_for_return: 1800,
          return_debt: 0
        )
        allow(FlashbackTravelService).to receive(:send).with(:find_arrival_room, destination_location).and_return(dest_room)

        allow(char_instance).to receive(:enter_flashback_instance!)
        allow(other_instance).to receive(:enter_flashback_instance!)
        allow(char_instance).to receive(:teleport_to_room!)
        allow(other_instance).to receive(:teleport_to_room!)
      end

      it 'starts instanced party journey' do
        result = described_class.start_party_journey(
          travelers: travelers,
          destination: destination_location,
          flashback_mode: :return
        )
        expect(result[:success]).to be true
        expect(result[:instanced]).to be true
        expect(result[:traveler_count]).to eq(2)
      end
    end

    context 'with flashback mode return and no arrival room' do
      before do
        allow(char_instance).to receive(:flashback_time_available).and_return(7200)
        allow(other_instance).to receive(:flashback_time_available).and_return(7200)
        allow(FlashbackTravelService).to receive(:estimate_journey_time).and_return(3600)
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage_with_available).and_return(
          success: true,
          reserved_for_return: 1800
        )
        allow(FlashbackTravelService).to receive(:send).with(:find_arrival_room, destination_location).and_return(nil)
      end

      it 'returns an error before changing traveler state' do
        result = described_class.start_party_journey(
          travelers: travelers,
          destination: destination_location,
          flashback_mode: :return
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('No valid arrival room found')
        expect(char_instance.reload.flashback_instanced).to be false
        expect(other_instance.reload.flashback_instanced).to be false
      end
    end

    context 'with flashback mode return and mid-transition failure' do
      before do
        allow(char_instance).to receive(:flashback_time_available).and_return(7200)
        allow(other_instance).to receive(:flashback_time_available).and_return(7200)
        allow(FlashbackTravelService).to receive(:estimate_journey_time).and_return(3600)
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage_with_available).and_return(
          success: true,
          reserved_for_return: 1800
        )
        allow(FlashbackTravelService).to receive(:send).with(:find_arrival_room, destination_location).and_return(dest_room)
        allow(other_instance).to receive(:teleport_to_room!).and_raise(StandardError.new('Teleport failure'))
      end

      it 'rolls back all traveler updates' do
        result = described_class.start_party_journey(
          travelers: travelers,
          destination: destination_location,
          flashback_mode: :return
        )

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Failed to start instanced party journey.')
        expect(char_instance.reload.flashback_instanced).to be false
        expect(other_instance.reload.flashback_instanced).to be false
        expect(char_instance.current_room_id).to eq(origin_room.id)
        expect(other_instance.current_room_id).to eq(origin_room.id)
      end
    end

    context 'with flashback mode basic and instant travel' do
      before do
        allow(char_instance).to receive(:flashback_time_available).and_return(7200)
        allow(other_instance).to receive(:flashback_time_available).and_return(7200)
        allow(FlashbackTravelService).to receive(:estimate_journey_time).and_return(3600)
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage_with_available).and_return(
          success: true,
          can_instant: true
        )
        allow(FlashbackTravelService).to receive(:send).with(:find_arrival_room, destination_location).and_return(dest_room)

        allow(char_instance).to receive(:teleport_to_room!)
        allow(other_instance).to receive(:teleport_to_room!)
        allow(char_instance).to receive(:touch_rp_activity!)
        allow(other_instance).to receive(:touch_rp_activity!)
      end

      it 'teleports party instantly' do
        expect(char_instance).to receive(:teleport_to_room!).with(dest_room)
        expect(other_instance).to receive(:teleport_to_room!).with(dest_room)

        result = described_class.start_party_journey(
          travelers: travelers,
          destination: destination_location,
          flashback_mode: :basic
        )
        expect(result[:success]).to be true
        expect(result[:instanced]).to be false
      end
    end

    context 'with flashback mode basic and partial reduction' do
      let(:mock_journey) do
        double(
          'WorldJourney',
          time_remaining_display: '30 minutes',
          speed_modifier: 1.0,
          update: true,
          cancel!: true
        )
      end

      before do
        allow(char_instance).to receive(:flashback_time_available).and_return(1200)
        allow(other_instance).to receive(:flashback_time_available).and_return(1200)
        allow(FlashbackTravelService).to receive(:estimate_journey_time).and_return(3600)
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage_with_available).and_return(
          success: true,
          can_instant: false,
          time_remaining: 1800
        )
        allow(FlashbackTimeService).to receive(:format_time).and_return('30 minutes')
        allow(WorldTravelService).to receive(:start_journey).and_return(
          success: true,
          journey: mock_journey
        )
        allow(WorldTravelService).to receive(:board_journey).and_return(success: true)
      end

      it 'starts a reduced-time journey for the party' do
        result = described_class.start_party_journey(
          travelers: travelers,
          destination: destination_location,
          flashback_mode: :basic
        )

        expect(result[:success]).to be true
        expect(result[:message]).to include('saves')
        expect(result[:message]).to include('will take')
      end

      it 'updates journey timing and speed modifier' do
        described_class.start_party_journey(
          travelers: travelers,
          destination: destination_location,
          flashback_mode: :basic
        )

        expect(mock_journey).to have_received(:update).with(hash_including(speed_modifier: 2.0))
        expect(mock_journey).to have_received(:update).with(hash_including(:estimated_arrival_at))
      end
    end

    context 'with standard travel' do
      let(:mock_journey) do
        instance_double('WorldJourney', time_remaining_display: '2 hours', cancel!: true)
      end

      before do
        allow(WorldTravelService).to receive(:start_journey).and_return(
          success: true,
          journey: mock_journey
        )
        allow(WorldTravelService).to receive(:board_journey).and_return(
          success: true
        )
      end

      it 'starts standard journey with all travelers' do
        result = described_class.start_party_journey(
          travelers: travelers,
          destination: destination_location
        )
        expect(result[:success]).to be true
        expect(result[:traveler_count]).to eq(2)
      end

      it 'boards additional travelers' do
        expect(WorldTravelService).to receive(:board_journey).with(other_instance, mock_journey)

        described_class.start_party_journey(
          travelers: travelers,
          destination: destination_location
        )
      end

      it 'fails and cancels the journey if a traveler cannot board' do
        allow(WorldTravelService).to receive(:board_journey).with(other_instance, mock_journey).and_return(
          success: false,
          error: 'You are not at the same location as this transport.'
        )

        result = described_class.start_party_journey(
          travelers: travelers,
          destination: destination_location
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('Could not board')
        expect(mock_journey).to have_received(:cancel!).with(reason: 'Party boarding failed')
      end
    end
  end

  describe '.world_map_data' do
    before do
      # Ensure locations exist with proper associations
      origin_location
      destination_location
    end

    context 'with valid location' do
      before do
        allow(char_instance).to receive(:flashback_time_available).and_return(3600)
        allow(FlashbackTimeService).to receive(:format_time).and_return('1 hour')
      end

      it 'returns success' do
        result = described_class.world_map_data(char_instance)
        expect(result[:success]).to be true
      end

      it 'returns world info' do
        result = described_class.world_map_data(char_instance)
        expect(result[:world][:id]).to eq(world.id)
        expect(result[:world][:name]).to eq(world.name)
      end

      it 'returns current location' do
        result = described_class.world_map_data(char_instance)
        expect(result[:current_location][:id]).to eq(origin_location.id)
      end

      it 'returns bounds' do
        result = described_class.world_map_data(char_instance)
        expect(result[:bounds]).to have_key(:min_lat)
        expect(result[:bounds]).to have_key(:max_lat)
        expect(result[:bounds]).to have_key(:min_lon)
        expect(result[:bounds]).to have_key(:max_lon)
      end

      it 'returns locations array' do
        result = described_class.world_map_data(char_instance)
        expect(result[:locations]).to be_an(Array)
        expect(result[:locations].length).to be >= 1
      end

      it 'returns flashback availability' do
        result = described_class.world_map_data(char_instance)
        expect(result[:flashback_available]).to eq(3600)
        expect(result[:flashback_display]).to eq('1 hour')
      end
    end

    context 'without current room' do
      before do
        allow(char_instance).to receive(:current_room).and_return(nil)
      end

      it 'returns error' do
        result = described_class.world_map_data(char_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('No current location')
      end
    end

    context 'without world' do
      let(:no_world_location) { create(:location, world: nil) }
      let(:no_world_room) { create(:room, location: no_world_location) }

      before do
        allow(char_instance).to receive(:current_room).and_return(no_world_room)
      end

      it 'returns error' do
        result = described_class.world_map_data(char_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('No world found')
      end
    end
  end

  describe '.available_destinations' do
    before do
      origin_location
      destination_location
      allow(FlashbackTravelService).to receive(:estimate_journey_time).and_return(3600)
      allow(FlashbackTimeService).to receive(:format_journey_time).and_return('1 hour')
    end

    it 'returns array of destinations' do
      result = described_class.available_destinations(char_instance)
      expect(result).to be_an(Array)
    end

    it 'excludes current location' do
      result = described_class.available_destinations(char_instance)
      ids = result.map { |d| d[:id] }
      expect(ids).not_to include(origin_location.id)
    end

    it 'includes other locations in world' do
      result = described_class.available_destinations(char_instance)
      ids = result.map { |d| d[:id] }
      expect(ids).to include(destination_location.id)
    end

    it 'calculates hex distance' do
      result = described_class.available_destinations(char_instance)
      dest = result.find { |d| d[:id] == destination_location.id }
      expect(dest[:hex_distance]).to be_a(Numeric)
    end

    it 'includes journey time' do
      result = described_class.available_destinations(char_instance)
      dest = result.find { |d| d[:id] == destination_location.id }
      expect(dest[:journey_time]).to eq(3600)
      expect(dest[:journey_time_display]).to eq('1 hour')
    end

    it 'sorts by distance' do
      # Create a closer destination
      closer_location = create(:location, world: world, globe_hex_id: 3, latitude: 2.0, longitude: 0.0, name: 'Closer')

      result = described_class.available_destinations(char_instance)
      distances = result.map { |d| d[:hex_distance] }
      expect(distances).to eq(distances.sort)
    end

    context 'without current location' do
      before do
        allow(char_instance).to receive(:current_room).and_return(nil)
      end

      it 'returns empty array' do
        result = described_class.available_destinations(char_instance)
        expect(result).to eq([])
      end
    end
  end

  describe 'private methods' do
    describe '#determine_available_modes' do
      it 'always includes land' do
        modes = described_class.send(:determine_available_modes, origin_location, destination_location)
        expect(modes).to include('land')
      end

      context 'with port locations' do
        before do
          allow(origin_location).to receive(:has_port?).and_return(true)
          allow(destination_location).to receive(:has_port?).and_return(true)
        end

        it 'includes water mode' do
          modes = described_class.send(:determine_available_modes, origin_location, destination_location)
          expect(modes).to include('water')
        end
      end

      context 'without port at destination' do
        before do
          allow(origin_location).to receive(:has_port?).and_return(true)
          allow(destination_location).to receive(:has_port?).and_return(false)
        end

        it 'excludes water mode' do
          modes = described_class.send(:determine_available_modes, origin_location, destination_location)
          expect(modes).not_to include('water')
        end
      end

      context 'with train stations' do
        before do
          allow(origin_location).to receive(:has_train_station?).and_return(true)
          allow(destination_location).to receive(:has_train_station?).and_return(true)
        end

        it 'includes rail mode' do
          modes = described_class.send(:determine_available_modes, origin_location, destination_location)
          expect(modes).to include('rail')
        end
      end

      context 'in modern era' do
        it 'includes air mode' do
          modes = described_class.send(:determine_available_modes, origin_location, destination_location)
          expect(modes).to include('air')
        end
      end

      context 'in medieval era' do
        let(:medieval_world) { create(:world) }
        let(:medieval_origin) { create(:location, world: medieval_world, globe_hex_id: 100, latitude: 0.0, longitude: 0.0) }
        let(:medieval_dest) { create(:location, world: medieval_world, globe_hex_id: 101, latitude: 5.0, longitude: 0.0) }

        before do
          allow(medieval_world).to receive(:era).and_return('medieval')
        end

        it 'excludes air mode' do
          modes = described_class.send(:determine_available_modes, medieval_origin, medieval_dest)
          expect(modes).not_to include('air')
        end
      end
    end
  end
end
