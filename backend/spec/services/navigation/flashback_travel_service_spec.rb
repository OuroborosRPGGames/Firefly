# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FlashbackTravelService do
  let(:world) { create(:world) }
  let(:origin_location) { create(:location, world: world, globe_hex_id: 1, latitude: 0.0, longitude: 0.0, name: 'Origin City') }
  let(:destination_location) { create(:location, world: world, globe_hex_id: 2, latitude: 10.0, longitude: 0.0, name: 'Destination City') }
  let(:origin_room) { create(:room, location: origin_location, room_type: 'street') }
  let(:dest_room) { create(:room, location: destination_location, room_type: 'street') }

  let(:character) { create(:character) }
  let(:char_instance) { create(:character_instance, character: character, current_room: origin_room) }

  describe '.estimate_journey_time' do
    it 'returns nil when current location has no globe hex' do
      no_hex_location = create(:location, world: world, globe_hex_id: nil)
      no_hex_room = create(:room, location: no_hex_location)
      allow(char_instance).to receive(:current_room).and_return(no_hex_room)

      result = described_class.estimate_journey_time(char_instance, destination_location)
      expect(result).to be_nil
    end

    it 'returns nil when destination has no globe hex' do
      no_hex_dest = create(:location, world: world, globe_hex_id: nil)

      result = described_class.estimate_journey_time(char_instance, no_hex_dest)
      expect(result).to be_nil
    end

    it 'returns 0 for same location' do
      result = described_class.estimate_journey_time(char_instance, origin_location)
      expect(result).to eq(0)
    end

    it 'calculates journey time based on hex distance' do
      result = described_class.estimate_journey_time(char_instance, destination_location)
      expect(result).to be_a(Integer)
      expect(result).to be > 0
    end

    it 'returns nil when character has no current room' do
      allow(char_instance).to receive(:current_room).and_return(nil)

      result = described_class.estimate_journey_time(char_instance, destination_location)
      expect(result).to be_nil
    end

    it 'returns nil when destination is in a different world' do
      other_world = create(:world)
      other_destination = create(
        :location,
        world: other_world,
        globe_hex_id: 99,
        latitude: 15.0,
        longitude: 15.0
      )

      result = described_class.estimate_journey_time(char_instance, other_destination)
      expect(result).to be_nil
    end
  end

  describe '.travel_options' do
    before do
      allow(FlashbackTimeService).to receive(:available_time).and_return(7200)
      allow(FlashbackTimeService).to receive(:format_journey_time).and_return('1 hour')
      allow(FlashbackTimeService).to receive(:format_time).and_return('2 hours')
      allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
        success: true, can_instant: true
      )
    end

    it 'returns error when journey time cannot be calculated' do
      allow(described_class).to receive(:estimate_journey_time).and_return(nil)

      result = described_class.travel_options(char_instance, destination_location)
      expect(result[:error]).to eq('Cannot calculate journey time')
    end

    it 'returns journey time information' do
      result = described_class.travel_options(char_instance, destination_location)
      expect(result[:journey_time]).to be_a(Integer)
      expect(result[:journey_time_display]).to eq('1 hour')
    end

    it 'returns flashback availability' do
      result = described_class.travel_options(char_instance, destination_location)
      expect(result[:flashback_available]).to eq(7200)
      expect(result[:flashback_display]).to eq('2 hours')
    end

    it 'returns coverage for all three modes' do
      result = described_class.travel_options(char_instance, destination_location)
      expect(result[:basic]).to have_key(:success)
      expect(result[:return]).to have_key(:success)
      expect(result[:backloaded]).to have_key(:success)
    end
  end

  describe '.start_flashback_journey' do
    before do
      dest_room
      allow(char_instance).to receive(:traveling?).and_return(false)
      allow(char_instance).to receive(:flashback_instanced?).and_return(false)
    end

    context 'validation errors' do
      it 'returns error when already traveling' do
        allow(char_instance).to receive(:traveling?).and_return(true)

        result = described_class.start_flashback_journey(char_instance, destination: destination_location)
        expect(result[:success]).to be false
        expect(result[:error]).to include('already on a journey')
      end

      it 'returns error when already in flashback instance' do
        allow(char_instance).to receive(:flashback_instanced?).and_return(true)

        result = described_class.start_flashback_journey(char_instance, destination: destination_location)
        expect(result[:success]).to be false
        expect(result[:error]).to include('already in a flashback instance')
      end

      it 'returns error when journey time cannot be calculated' do
        allow(described_class).to receive(:estimate_journey_time).and_return(nil)

        result = described_class.start_flashback_journey(char_instance, destination: destination_location)
        expect(result[:success]).to be false
        expect(result[:error]).to include('Cannot calculate journey time')
      end

      it 'returns error for same location' do
        allow(described_class).to receive(:estimate_journey_time).and_return(0)

        result = described_class.start_flashback_journey(char_instance, destination: destination_location)
        expect(result[:success]).to be false
        expect(result[:error]).to include('already at that location')
      end

      it 'returns error when destination is in a different world' do
        other_world = create(:world)
        other_destination = create(
          :location,
          world: other_world,
          globe_hex_id: 100,
          latitude: 20.0,
          longitude: 20.0
        )

        result = described_class.start_flashback_journey(char_instance, destination: other_destination)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Cannot travel to a location in a different world.')
      end

      it 'returns error for unknown mode' do
        allow(described_class).to receive(:estimate_journey_time).and_return(3600)
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(success: true)

        result = described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :unknown)
        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown flashback mode')
      end

      it 'returns flashback coverage error' do
        allow(described_class).to receive(:estimate_journey_time).and_return(3600)
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
          success: false, error: 'Not enough flashback time'
        )

        result = described_class.start_flashback_journey(char_instance, destination: destination_location)
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Not enough flashback time')
      end
    end

    context 'with basic mode' do
      before do
        allow(described_class).to receive(:estimate_journey_time).and_return(3600)
      end

      context 'instant arrival' do
        before do
          allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
            success: true, can_instant: true
          )
          allow(char_instance).to receive(:teleport_to_room!)
          allow(char_instance).to receive(:touch_rp_activity!)
        end

        it 'teleports character instantly' do
          expect(char_instance).to receive(:teleport_to_room!)

          described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :basic)
        end

        it 'touches RP activity' do
          expect(char_instance).to receive(:touch_rp_activity!)

          described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :basic)
        end

        it 'returns success with instant arrival message' do
          result = described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :basic)
          expect(result[:success]).to be true
          expect(result[:message]).to include('arrive instantly')
          expect(result[:instanced]).to be false
        end
      end

      context 'reduced journey' do
        before do
          allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
            success: true, can_instant: false, time_remaining: 1800
          )
          allow(FlashbackTimeService).to receive(:format_time).and_return('30 minutes')
          allow(WorldTravelService).to receive(:start_journey).and_return(
            success: true, journey: double(speed_modifier: 1.0, update: true)
          )
        end

        it 'starts world travel journey' do
          expect(WorldTravelService).to receive(:start_journey)
            .with(char_instance, destination: destination_location)
            .and_return(success: true, journey: double(speed_modifier: 1.0, update: true))

          described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :basic)
        end

        it 'returns success with reduced time' do
          result = described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :basic)
          expect(result[:success]).to be true
          expect(result[:message]).to include('save')
          expect(result[:instanced]).to be false
        end

        it 'handles WorldTravelService failure' do
          allow(WorldTravelService).to receive(:start_journey).and_return(
            success: false, error: 'Travel failed'
          )

          result = described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :basic)
          expect(result[:success]).to be false
        end
      end
    end

    context 'with return mode' do
      before do
        allow(described_class).to receive(:estimate_journey_time).and_return(3600)
        allow(FlashbackTimeService).to receive(:format_time).and_return('1 hour')
        allow(FlashbackTimeService).to receive(:available_time).and_return(7200)
      end

      context 'when can instant travel' do
        before do
          allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
            success: true, can_instant: true, reserved_for_return: 3600
          )
          allow(char_instance).to receive(:enter_flashback_instance!)
          allow(char_instance).to receive(:teleport_to_room!)
        end

        it 'enters flashback instance' do
          expect(char_instance).to receive(:enter_flashback_instance!).with(
            hash_including(mode: 'return', reserved_time: 3600)
          )

          described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :return)
        end

        it 'teleports to destination' do
          expect(char_instance).to receive(:teleport_to_room!)

          described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :return)
        end

        it 'returns success with instanced state' do
          result = described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :return)
          expect(result[:success]).to be true
          expect(result[:instanced]).to be true
          expect(result[:message]).to include('flashback return travel')
        end

        it 'returns error when no arrival room is available' do
          allow(described_class).to receive(:find_arrival_room).with(destination_location).and_return(nil)

          result = described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :return)
          expect(result[:success]).to be false
          expect(result[:error]).to include('No valid arrival room found')
        end
      end

      context 'when cannot instant travel' do
        before do
          allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
            success: true, can_instant: false
          )
        end

        it 'returns error about insufficient time' do
          result = described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :return)
          expect(result[:success]).to be false
          expect(result[:error]).to include('Not enough flashback time for return travel')
        end
      end

      context 'with co-travelers' do
        let(:other_char) { create(:character) }
        let(:other_instance) { create(:character_instance, character: other_char, current_room: origin_room) }

        before do
          allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
            success: true, can_instant: true, reserved_for_return: 3600
          )
          allow(char_instance).to receive(:enter_flashback_instance!)
          allow(char_instance).to receive(:teleport_to_room!)
          allow(other_instance).to receive(:enter_flashback_instance!)
          allow(other_instance).to receive(:teleport_to_room!)
        end

        it 'enters all travelers into flashback instance' do
          expect(char_instance).to receive(:enter_flashback_instance!)
          expect(other_instance).to receive(:enter_flashback_instance!)

          described_class.start_flashback_journey(
            char_instance,
            destination: destination_location,
            mode: :return,
            co_travelers: [other_instance]
          )
        end

        it 'teleports all travelers' do
          expect(char_instance).to receive(:teleport_to_room!)
          expect(other_instance).to receive(:teleport_to_room!)

          described_class.start_flashback_journey(
            char_instance,
            destination: destination_location,
            mode: :return,
            co_travelers: [other_instance]
          )
        end
      end
    end

    context 'with backloaded mode' do
      before do
        allow(described_class).to receive(:estimate_journey_time).and_return(3600)
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
          success: true, return_debt: 7200
        )
        allow(FlashbackTimeService).to receive(:format_time).and_return('2 hours')
        allow(char_instance).to receive(:enter_flashback_instance!)
        allow(char_instance).to receive(:teleport_to_room!)
      end

      it 'enters flashback instance with return debt' do
        expect(char_instance).to receive(:enter_flashback_instance!).with(
          hash_including(mode: 'backloaded', return_debt: 7200)
        )

        described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :backloaded)
      end

      it 'teleports to destination' do
        expect(char_instance).to receive(:teleport_to_room!)

        described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :backloaded)
      end

      it 'returns success with debt information' do
        result = described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :backloaded)
        expect(result[:success]).to be true
        expect(result[:instanced]).to be true
        expect(result[:return_debt]).to eq(7200)
        expect(result[:message]).to include('backloaded travel')
      end

      it 'returns error when no arrival room is available' do
        allow(described_class).to receive(:find_arrival_room).with(destination_location).and_return(nil)

        result = described_class.start_flashback_journey(char_instance, destination: destination_location, mode: :backloaded)
        expect(result[:success]).to be false
        expect(result[:error]).to include('No valid arrival room found')
      end
    end
  end

  describe '.end_flashback_instance' do
    context 'when not in flashback instance' do
      before do
        allow(char_instance).to receive(:flashback_instanced?).and_return(false)
      end

      it 'returns error' do
        result = described_class.end_flashback_instance(char_instance)
        expect(result[:success]).to be false
        expect(result[:error]).to include('not in a flashback instance')
      end
    end

    context 'when in flashback instance' do
      before do
        allow(char_instance).to receive(:flashback_instanced?).and_return(true)
        allow(char_instance).to receive(:clear_flashback_state!)
      end

      context 'without origin room' do
        before do
          allow(char_instance).to receive(:flashback_travel_mode).and_return('return')
          allow(char_instance).to receive(:flashback_origin_room).and_return(nil)
        end

        it 'clears flashback state' do
          expect(char_instance).to receive(:clear_flashback_state!)

          described_class.end_flashback_instance(char_instance)
        end

        it 'returns success' do
          result = described_class.end_flashback_instance(char_instance)
          expect(result[:success]).to be true
          expect(result[:message]).to include('ended')
        end
      end

      context 'with return mode' do
        before do
          allow(char_instance).to receive(:flashback_travel_mode).and_return('return')
          allow(char_instance).to receive(:flashback_origin_room).and_return(origin_room)
          allow(char_instance).to receive(:flashback_time_reserved).and_return(7200)
          allow(char_instance).to receive(:teleport_to_room!)
          allow(char_instance).to receive(:touch_rp_activity!)
        end

        context 'with enough reserved time for instant return' do
          before do
            allow(described_class).to receive(:send)
              .with(:estimate_return_journey_time, char_instance, origin_location)
              .and_return(3600)
          end

          it 'teleports back to origin' do
            expect(char_instance).to receive(:teleport_to_room!).with(origin_room)

            described_class.end_flashback_instance(char_instance)
          end

          it 'returns instant return result' do
            result = described_class.end_flashback_instance(char_instance)
            expect(result[:success]).to be true
            expect(result[:instant]).to be true
          end
        end

        context 'with insufficient reserved time' do
          # Set up character at destination (10 hexes away from origin)
          let(:dest_char_instance) do
            create(:character_instance, character: character, current_room: dest_room)
          end

          before do
            allow(dest_char_instance).to receive(:flashback_instanced?).and_return(true)
            allow(dest_char_instance).to receive(:flashback_travel_mode).and_return('return')
            allow(dest_char_instance).to receive(:flashback_origin_room).and_return(origin_room)
            allow(dest_char_instance).to receive(:flashback_time_reserved).and_return(100) # Very small amount
            allow(dest_char_instance).to receive(:clear_flashback_state!)
            allow(FlashbackTimeService).to receive(:format_time).and_return('30 minutes')
            allow(WorldTravelService).to receive(:start_journey).and_return(
              success: true, journey: double(speed_modifier: 1.0, update: true)
            )
          end

          it 'starts return journey when reserved time is less than travel time' do
            expect(WorldTravelService).to receive(:start_journey)

            described_class.end_flashback_instance(dest_char_instance)
          end

          it 'returns non-instant journey result' do
            result = described_class.end_flashback_instance(dest_char_instance)
            expect(result[:success]).to be true
            expect(result[:instant]).to be false
          end
        end
      end

      context 'with backloaded mode' do
        before do
          allow(char_instance).to receive(:flashback_travel_mode).and_return('backloaded')
          allow(char_instance).to receive(:flashback_origin_room).and_return(origin_room)
          allow(char_instance).to receive(:flashback_return_debt).and_return(7200)
          allow(FlashbackTimeService).to receive(:format_time).and_return('2 hours')
        end

        context 'with no return debt' do
          before do
            allow(char_instance).to receive(:flashback_return_debt).and_return(0)
            allow(char_instance).to receive(:teleport_to_room!)
            allow(char_instance).to receive(:touch_rp_activity!)
          end

          it 'teleports instantly' do
            expect(char_instance).to receive(:teleport_to_room!).with(origin_room)

            described_class.end_flashback_instance(char_instance)
          end

          it 'returns instant result' do
            result = described_class.end_flashback_instance(char_instance)
            expect(result[:success]).to be true
            expect(result[:instant]).to be true
          end
        end

        context 'with return debt' do
          before do
            allow(WorldTravelService).to receive(:start_journey).and_return(
              success: true, journey: double(speed_modifier: 1.0, update: true)
            )
          end

          it 'starts return journey with debt time' do
            expect(WorldTravelService).to receive(:start_journey)

            described_class.end_flashback_instance(char_instance)
          end

          it 'returns journey result' do
            result = described_class.end_flashback_instance(char_instance)
            expect(result[:success]).to be true
            expect(result[:instant]).to be false
          end
        end

        context 'when WorldTravelService fails' do
          before do
            allow(WorldTravelService).to receive(:start_journey).and_return(
              success: false, error: 'Travel error'
            )
            allow(char_instance).to receive(:teleport_to_room!)
          end

          it 'falls back to teleport' do
            expect(char_instance).to receive(:teleport_to_room!).with(origin_room)

            described_class.end_flashback_instance(char_instance)
          end

          it 'returns success as fallback' do
            result = described_class.end_flashback_instance(char_instance)
            expect(result[:success]).to be true
          end
        end
      end

      context 'with unknown mode' do
        before do
          allow(char_instance).to receive(:flashback_travel_mode).and_return('unknown')
          allow(char_instance).to receive(:flashback_origin_room).and_return(origin_room)
        end

        it 'clears flashback state' do
          expect(char_instance).to receive(:clear_flashback_state!)

          described_class.end_flashback_instance(char_instance)
        end

        it 'returns success' do
          result = described_class.end_flashback_instance(char_instance)
          expect(result[:success]).to be true
        end
      end
    end
  end

  describe 'private methods' do
    describe '#find_arrival_room' do
      it 'prefers street rooms' do
        street_room = create(:room, location: destination_location, room_type: 'street')
        other_room = create(:room, location: destination_location, room_type: 'apartment')

        result = described_class.send(:find_arrival_room, destination_location)
        expect(result).to eq(street_room)
      end

      it 'falls back to safe rooms' do
        safe_room = create(:room, location: destination_location, safe_room: true, room_type: 'lobby')
        other_room = create(:room, location: destination_location, room_type: 'apartment')

        result = described_class.send(:find_arrival_room, destination_location)
        expect(result).to eq(safe_room)
      end

      it 'falls back to any room' do
        any_room = create(:room, location: destination_location, room_type: 'apartment')

        result = described_class.send(:find_arrival_room, destination_location)
        expect(result).to eq(any_room)
      end
    end

    describe '#estimate_return_journey_time' do
      let(:return_location) { create(:location, world: world, globe_hex_id: 3, latitude: 5.0, longitude: 0.0) }
      let(:return_room) { create(:room, location: return_location) }

      before do
        allow(char_instance).to receive(:current_room).and_return(return_room)
      end

      it 'calculates time based on hex distance' do
        result = described_class.send(:estimate_return_journey_time, char_instance, origin_location)
        expect(result).to be_a(Integer)
        expect(result).to be > 0
      end

      it 'returns 0 for same location' do
        result = described_class.send(:estimate_return_journey_time, char_instance, return_location)
        expect(result).to eq(0)
      end

      it 'returns 0 when current location has no coords' do
        no_hex_location = create(:location, world: world, globe_hex_id: nil)
        no_hex_room = create(:room, location: no_hex_location)
        allow(char_instance).to receive(:current_room).and_return(no_hex_room)

        result = described_class.send(:estimate_return_journey_time, char_instance, origin_location)
        expect(result).to eq(0)
      end

      it 'returns 0 when origin has no coords' do
        no_hex_origin = create(:location, world: world, globe_hex_id: nil)

        result = described_class.send(:estimate_return_journey_time, char_instance, no_hex_origin)
        expect(result).to eq(0)
      end
    end

    # Note: Methods calculate_journey_time_seconds and hex_distance don't exist
    # in FlashbackTravelService. Journey time calculations are done via
    # FlashbackTimeService.calculate_flashback_coverage instead.
  end

  # ============================================
  # Travel Options Additional Tests
  # ============================================

  describe '.travel_options additional tests' do
    before do
      allow(FlashbackTimeService).to receive(:available_time).and_return(7200)
      allow(FlashbackTimeService).to receive(:format_journey_time).and_return('1 hour')
      allow(FlashbackTimeService).to receive(:format_time).and_return('2 hours')
    end

    context 'when basic mode cannot cover full journey' do
      before do
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
          success: true, can_instant: false, time_remaining: 1800
        )
      end

      it 'returns partial coverage for basic mode' do
        result = described_class.travel_options(char_instance, destination_location)
        expect(result[:basic][:can_instant]).to be false
        expect(result[:basic][:time_remaining]).to eq(1800)
      end
    end

    context 'when return mode has insufficient time' do
      before do
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
          success: false, error: 'Not enough time for return trip'
        )
      end

      it 'returns error for return mode' do
        result = described_class.travel_options(char_instance, destination_location)
        expect(result[:return][:success]).to be false
      end
    end

    context 'when backloaded mode calculates debt' do
      before do
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
          success: true, return_debt: 3600
        )
      end

      it 'includes return debt in result' do
        result = described_class.travel_options(char_instance, destination_location)
        expect(result[:backloaded][:return_debt]).to eq(3600)
      end
    end
  end

  # ============================================
  # Start Flashback Journey Additional Tests
  # ============================================

  describe '.start_flashback_journey additional tests' do
    before do
      dest_room
      allow(char_instance).to receive(:traveling?).and_return(false)
      allow(char_instance).to receive(:flashback_instanced?).and_return(false)
    end

    context 'with multiple co-travelers' do
      let(:co_traveler_1) { create(:character_instance, current_room: origin_room) }
      let(:co_traveler_2) { create(:character_instance, current_room: origin_room) }

      before do
        allow(described_class).to receive(:estimate_journey_time).and_return(3600)
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
          success: true, can_instant: true, reserved_for_return: 3600
        )
        allow(char_instance).to receive(:enter_flashback_instance!)
        allow(char_instance).to receive(:teleport_to_room!)
        allow(co_traveler_1).to receive(:enter_flashback_instance!)
        allow(co_traveler_1).to receive(:teleport_to_room!)
        allow(co_traveler_2).to receive(:enter_flashback_instance!)
        allow(co_traveler_2).to receive(:teleport_to_room!)
      end

      it 'processes all co-travelers' do
        expect(co_traveler_1).to receive(:enter_flashback_instance!)
        expect(co_traveler_2).to receive(:enter_flashback_instance!)

        described_class.start_flashback_journey(
          char_instance,
          destination: destination_location,
          mode: :return,
          co_travelers: [co_traveler_1, co_traveler_2]
        )
      end
    end

    context 'when arrival room handling' do
      before do
        # Ensure destination room exists (lazy evaluation fix)
        dest_room
        allow(described_class).to receive(:estimate_journey_time).and_return(3600)
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
          success: true, can_instant: true
        )
      end

      it 'finds arrival room from destination location' do
        # Verify find_arrival_room is called and returns the destination room
        expect(described_class).to receive(:find_arrival_room).with(destination_location).and_call_original

        result = described_class.start_flashback_journey(char_instance, destination: destination_location)
        expect(result).to be_a(Hash)
        expect(result[:success]).to be true
      end
    end

    context 'when return setup fails mid-transition' do
      let(:co_traveler) { create(:character_instance, current_room: origin_room) }

      before do
        allow(described_class).to receive(:estimate_journey_time).and_return(3600)
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
          success: true, can_instant: true, reserved_for_return: 3600
        )
        allow(co_traveler).to receive(:teleport_to_room!).and_raise(StandardError.new('Teleport failure'))
      end

      it 'rolls back flashback state for all travelers' do
        result = described_class.start_flashback_journey(
          char_instance,
          destination: destination_location,
          mode: :return,
          co_travelers: [co_traveler]
        )

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Failed to start return flashback journey.')
        expect(char_instance.reload.flashback_instanced).to be false
        expect(co_traveler.reload.flashback_instanced).to be false
        expect(char_instance.current_room_id).to eq(origin_room.id)
        expect(co_traveler.current_room_id).to eq(origin_room.id)
      end
    end
  end

  # ============================================
  # End Flashback Instance Additional Tests
  # ============================================

  describe '.end_flashback_instance additional tests' do
    before do
      allow(char_instance).to receive(:flashback_instanced?).and_return(true)
      allow(char_instance).to receive(:clear_flashback_state!)
    end

    context 'return mode with exact time match' do
      before do
        allow(char_instance).to receive(:flashback_travel_mode).and_return('return')
        allow(char_instance).to receive(:flashback_origin_room).and_return(origin_room)
        allow(char_instance).to receive(:flashback_time_reserved).and_return(3600) # Exactly enough
        allow(char_instance).to receive(:teleport_to_room!)
        allow(char_instance).to receive(:touch_rp_activity!)
      end

      it 'teleports when reserved time equals journey time' do
        expect(char_instance).to receive(:teleport_to_room!).with(origin_room)

        described_class.end_flashback_instance(char_instance)
      end
    end

    context 'backloaded mode with partial debt' do
      before do
        allow(char_instance).to receive(:flashback_travel_mode).and_return('backloaded')
        allow(char_instance).to receive(:flashback_origin_room).and_return(origin_room)
        allow(char_instance).to receive(:flashback_return_debt).and_return(1800) # Partial debt
        allow(FlashbackTimeService).to receive(:format_time).and_return('30 minutes')
        allow(WorldTravelService).to receive(:start_journey).and_return(
          success: true, journey: double(speed_modifier: 1.0, update: true)
        )
      end

      it 'calculates journey with partial debt' do
        result = described_class.end_flashback_instance(char_instance)
        expect(result[:success]).to be true
      end
    end

    context 'when touching RP activity' do
      before do
        allow(char_instance).to receive(:flashback_travel_mode).and_return('return')
        allow(char_instance).to receive(:flashback_origin_room).and_return(origin_room)
        allow(char_instance).to receive(:flashback_time_reserved).and_return(7200)
        allow(char_instance).to receive(:teleport_to_room!)
        allow(char_instance).to receive(:touch_rp_activity!)
      end

      it 'touches RP activity on instant return' do
        expect(char_instance).to receive(:touch_rp_activity!)

        described_class.end_flashback_instance(char_instance)
      end
    end
  end

  # ============================================
  # Integration Tests
  # ============================================

  describe 'integration scenarios' do
    context 'full round trip with return mode' do
      before do
        dest_room
        allow(char_instance).to receive(:traveling?).and_return(false)
        allow(char_instance).to receive(:flashback_instanced?).and_return(false)
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
          success: true, can_instant: true, reserved_for_return: 7200
        )
        allow(FlashbackTimeService).to receive(:format_time).and_return('2 hours')
        allow(char_instance).to receive(:enter_flashback_instance!)
        allow(char_instance).to receive(:teleport_to_room!)
      end

      it 'allows starting journey and returning' do
        # Start journey
        start_result = described_class.start_flashback_journey(
          char_instance,
          destination: destination_location,
          mode: :return
        )
        expect(start_result[:success]).to be true
        expect(start_result[:instanced]).to be true

        # End journey
        allow(char_instance).to receive(:flashback_instanced?).and_return(true)
        allow(char_instance).to receive(:flashback_travel_mode).and_return('return')
        allow(char_instance).to receive(:flashback_origin_room).and_return(origin_room)
        allow(char_instance).to receive(:flashback_time_reserved).and_return(7200)
        allow(char_instance).to receive(:clear_flashback_state!)
        allow(char_instance).to receive(:touch_rp_activity!)

        end_result = described_class.end_flashback_instance(char_instance)
        expect(end_result[:success]).to be true
      end
    end

    context 'basic mode with varying flashback availability' do
      before do
        dest_room
        allow(char_instance).to receive(:traveling?).and_return(false)
        allow(char_instance).to receive(:flashback_instanced?).and_return(false)
      end

      it 'handles case with no flashback time available' do
        allow(FlashbackTimeService).to receive(:available_time).and_return(0)
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
          success: false, error: 'No flashback time available'
        )

        result = described_class.start_flashback_journey(
          char_instance,
          destination: destination_location,
          mode: :basic
        )
        expect(result[:success]).to be false
      end

      it 'handles case with abundant flashback time' do
        allow(FlashbackTimeService).to receive(:available_time).and_return(86400) # 24 hours
        allow(FlashbackTimeService).to receive(:calculate_flashback_coverage).and_return(
          success: true, can_instant: true
        )
        allow(char_instance).to receive(:teleport_to_room!)
        allow(char_instance).to receive(:touch_rp_activity!)

        result = described_class.start_flashback_journey(
          char_instance,
          destination: destination_location,
          mode: :basic
        )
        expect(result[:success]).to be true
        expect(result[:instanced]).to be false
      end
    end
  end
end
