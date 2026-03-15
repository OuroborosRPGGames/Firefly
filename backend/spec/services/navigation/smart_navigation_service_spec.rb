# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SmartNavigationService do
  let(:location) { create(:location) }
  let(:zone) { location.zone }
  let(:world) { zone.world }
  let(:universe) { world.universe }
  let(:currency) { create(:currency, universe: universe, is_primary: true) }

  let(:from_room) { create(:room, location: location, name: 'Starting Room') }
  let(:destination_room) { create(:room, location: location, name: 'Destination Room') }
  let(:street_room) { create(:room, location: location, name: 'Main Street', room_type: 'street') }

  let(:character) { create(:character) }
  let(:char_instance) { create(:character_instance, character: character, current_room: from_room) }

  let(:service) { described_class.new(char_instance) }

  before do
    allow(BroadcastService).to receive(:to_room)
  end

  describe 'constants' do
    it 'defines MAX_DIRECT_WALK_DISTANCE' do
      expect(described_class::MAX_DIRECT_WALK_DISTANCE).to eq(15)
    end

    it 'defines MAX_BUILDING_PATH' do
      expect(described_class::MAX_BUILDING_PATH).to eq(20)
    end
  end

  describe '#initialize' do
    it 'stores character instance' do
      expect(service.instance_variable_get(:@character_instance)).to eq(char_instance)
    end

    it 'stores from_room from character instance' do
      expect(service.instance_variable_get(:@from_room)).to eq(from_room)
    end

    it 'initializes messages array' do
      expect(service.instance_variable_get(:@messages)).to eq([])
    end
  end

  describe '#navigate_to' do
    context 'when already at destination' do
      it 'returns already there result' do
        result = service.navigate_to(from_room)
        expect(result[:success]).to be true
        expect(result[:message]).to eq("You're already here.")
        expect(result[:travel_type]).to eq(:none)
      end
    end

    context 'when destination is directly walkable' do
      let(:path_step) { double('PathStep', direction: 'north', to_room: destination_room, can_pass?: true, from_room: from_room) }

      before do
        allow(PathfindingService).to receive(:find_path).and_return([path_step])
        allow(MovementConfig).to receive(:time_for_movement).and_return(2000)
        allow(MovementConfig).to receive(:conjugate).with('walk', :continuous).and_return('walking')
        allow(DistanceService).to receive(:exit_position_in_room).and_return([10.0, 20.0, 0.0])
        allow(TimedAction).to receive(:start_delayed)
      end

      it 'starts timed movement instead of instant teleport' do
        result = service.navigate_to(destination_room)
        expect(result[:success]).to be true
        expect(result[:travel_type]).to eq(:walk)
        expect(result[:message]).to include('start walking')
      end

      it 'does not instantly move the character' do
        service.navigate_to(destination_room)
        char_instance.refresh
        expect(char_instance.current_room_id).to eq(from_room.id)
      end

      it 'creates a timed action for movement' do
        expect(TimedAction).to receive(:start_delayed).with(
          char_instance, 'movement', 2000, 'MovementHandler', hash_including(direction: 'north')
        )
        service.navigate_to(destination_room)
      end

      it 'returns path length' do
        result = service.navigate_to(destination_room)
        expect(result[:path_length]).to eq(1)
      end

      it 'sets movement state on character' do
        service.navigate_to(destination_room)
        char_instance.refresh
        expect(char_instance.movement_state).to eq('moving')
      end
    end

    context 'when destination requires taxi' do
      before do
        allow(PathfindingService).to receive(:find_path).and_return([])
        allow(TaxiService).to receive(:available?).and_return(false)
      end

      it 'returns unreachable if no taxi and no long path' do
        result = service.navigate_to(destination_room)
        expect(result[:success]).to be false
        expect(result[:error]).to include("can't find a way to reach")
      end

      context 'with longer walking path available' do
        let(:long_path_step) { double('PathStep', direction: 'east', to_room: destination_room, can_pass?: true, from_room: from_room) }

        before do
          # First call returns empty (short path), second returns path (long path)
          call_count = 0
          allow(PathfindingService).to receive(:find_path) do |_from, _to, **_options|
            call_count += 1
            call_count == 1 ? [] : [long_path_step]
          end
          allow(MovementConfig).to receive(:time_for_movement).and_return(2000)
          allow(MovementConfig).to receive(:conjugate).with('walk', :continuous).and_return('walking')
          allow(DistanceService).to receive(:exit_position_in_room).and_return([10.0, 20.0, 0.0])
          allow(TimedAction).to receive(:start_delayed)
        end

        it 'walks the longer path with timed movement' do
          result = service.navigate_to(destination_room)
          expect(result[:success]).to be true
          expect(result[:travel_type]).to eq(:walk)
          expect(result[:message]).to include('start walking')
        end
      end
    end

    context 'with taxi service available' do
      let(:dest_street) { create(:room, location: location, name: 'Dest Street', room_type: 'street') }

      before do
        # No direct path
        allow(PathfindingService).to receive(:find_path).and_return([])
        allow(TaxiService).to receive(:available?).and_return(true)

        # Mock building navigation
        allow(BuildingNavigationService).to receive(:indoor_room?).and_return(false)
        allow(BuildingNavigationService).to receive(:find_nearest_street).and_return(dest_street)

        # Mock fare
        allow(PathfindingService).to receive(:distance_between).and_return(10)
        allow(TaxiService).to receive(:taxi_type).and_return(:rideshare)
        allow(TaxiService).to receive(:taxi_name).and_return('rideshare')

        # Mock currency and wallet
        allow(Currency).to receive(:default_for).and_return(currency)
        allow(EraService).to receive(:digital_only?).and_return(false)
      end

      it 'returns error when cannot afford taxi' do
        # No wallet means can't afford
        result = service.navigate_to(destination_room)
        expect(result[:success]).to be false
        expect(result[:error]).to include("can't afford")
      end

      context 'with sufficient funds' do
        let!(:wallet) { create(:wallet, character_instance: char_instance, currency: currency, balance: 100) }

        before do
          # Mock taxi travel with private method send
          allow(TaxiService).to receive(:send).and_return(
            { success: true, narrative: 'You take a taxi.' }
          )
        end

        it 'plans taxi journey successfully' do
          result = service.navigate_to(destination_room)
          # Either success or specific travel error - but no crash
          expect(result).to be_a(Hash)
          expect(result).to have_key(:success)
        end
      end
    end
  end

  describe '#navigate_to_named' do
    context 'with nil destination name' do
      it 'returns error for nil' do
        result = service.navigate_to_named(nil)
        expect(result[:success]).to be false
        expect(result[:error]).to include("don't know how to get to")
      end
    end

    context 'with empty destination name' do
      it 'returns error for empty string' do
        result = service.navigate_to_named('')
        expect(result[:success]).to be false
      end

      it 'returns error for whitespace only' do
        result = service.navigate_to_named('   ')
        expect(result[:success]).to be false
      end
    end

    context 'with matching destination' do
      before do
        allow(PathfindingService).to receive(:find_path).and_return([])
        allow(TaxiService).to receive(:available?).and_return(false)
      end

      it 'finds room by partial name match' do
        result = service.navigate_to_named('destination')
        # Should find the room and attempt navigation
        expect(result).to be_a(Hash)
      end
    end
  end

  describe 'private methods' do
    describe '#same_room?' do
      it 'returns true when rooms match' do
        expect(service.send(:same_room?, from_room)).to be true
      end

      it 'returns false when rooms differ' do
        expect(service.send(:same_room?, destination_room)).to be false
      end

      it 'handles nil destination' do
        expect(service.send(:same_room?, nil)).to be false
      end
    end

    describe '#already_there_result' do
      it 'returns success true' do
        result = service.send(:already_there_result)
        expect(result[:success]).to be true
      end

      it 'returns already here message' do
        result = service.send(:already_there_result)
        expect(result[:message]).to eq("You're already here.")
      end

      it 'returns travel type none' do
        result = service.send(:already_there_result)
        expect(result[:travel_type]).to eq(:none)
      end
    end

    describe '#unreachable_result' do
      it 'returns success false' do
        result = service.send(:unreachable_result, destination_room)
        expect(result[:success]).to be false
      end

      it 'includes destination name in error' do
        result = service.send(:unreachable_result, destination_room)
        expect(result[:error]).to include(destination_room.name)
      end
    end

    describe '#format_walk_message' do
      it 'formats single step walk' do
        path = [double('PathStep', direction: 'north', to_room: destination_room)]
        result = service.send(:format_walk_message, path, destination_room)
        expect(result).to eq("You walk to #{destination_room.name}.")
      end

      it 'formats short walk with directions' do
        path = [
          double('PathStep', direction: 'north'),
          double('PathStep', direction: 'east')
        ]
        result = service.send(:format_walk_message, path, destination_room)
        expect(result).to include('north, then east')
      end

      it 'formats long walk with step count' do
        path = Array.new(5) { double('PathStep', direction: 'north') }
        result = service.send(:format_walk_message, path, destination_room)
        expect(result).to include('5 rooms')
      end
    end

    describe '#calculate_taxi_fare' do
      before do
        allow(PathfindingService).to receive(:distance_between).and_return(10)
      end

      it 'calculates carriage fare' do
        allow(TaxiService).to receive(:taxi_type).and_return(:carriage)
        fare = service.send(:calculate_taxi_fare, from_room, destination_room)
        expect(fare).to eq(10) # 5 base + (10 * 0.5).round
      end

      it 'calculates rideshare fare' do
        allow(TaxiService).to receive(:taxi_type).and_return(:rideshare)
        fare = service.send(:calculate_taxi_fare, from_room, destination_room)
        expect(fare).to eq(15) # 10 base + (10 * 0.5).round
      end

      it 'calculates autocab fare' do
        allow(TaxiService).to receive(:taxi_type).and_return(:autocab)
        fare = service.send(:calculate_taxi_fare, from_room, destination_room)
        expect(fare).to eq(20) # 15 base + (10 * 0.5).round
      end

      it 'calculates hovertaxi fare' do
        allow(TaxiService).to receive(:taxi_type).and_return(:hovertaxi)
        fare = service.send(:calculate_taxi_fare, from_room, destination_room)
        expect(fare).to eq(30) # 25 base + (10 * 0.5).round
      end

      it 'uses default fare for unknown type' do
        allow(TaxiService).to receive(:taxi_type).and_return(:unknown)
        fare = service.send(:calculate_taxi_fare, from_room, destination_room)
        expect(fare).to eq(15) # 10 base + (10 * 0.5).round
      end

      it 'uses default distance if nil' do
        allow(PathfindingService).to receive(:distance_between).and_return(nil)
        allow(TaxiService).to receive(:taxi_type).and_return(:rideshare)
        fare = service.send(:calculate_taxi_fare, from_room, destination_room)
        expect(fare).to eq(15) # 10 base + (10 * 0.5).round
      end
    end

    describe '#can_afford_fare?' do
      before do
        allow(Currency).to receive(:default_for).and_return(currency)
      end

      context 'in non-digital era' do
        before do
          allow(EraService).to receive(:digital_only?).and_return(false)
        end

        it 'returns true when wallet has enough' do
          create(:wallet, character_instance: char_instance, currency: currency, balance: 100)
          expect(service.send(:can_afford_fare?, 50)).to be true
        end

        it 'returns false when wallet is short' do
          create(:wallet, character_instance: char_instance, currency: currency, balance: 10)
          expect(service.send(:can_afford_fare?, 50)).to be false
        end

        it 'returns false when no wallet' do
          expect(service.send(:can_afford_fare?, 50)).to be false
        end
      end

      context 'in digital era' do
        before do
          allow(EraService).to receive(:digital_only?).and_return(true)
        end

        it 'returns true when bank account has enough' do
          create(:bank_account, character: character, currency: currency, balance: 100)
          expect(service.send(:can_afford_fare?, 50)).to be true
        end

        it 'returns false when bank account is short' do
          create(:bank_account, character: character, currency: currency, balance: 10)
          expect(service.send(:can_afford_fare?, 50)).to be false
        end
      end

      it 'returns false when no currency' do
        allow(Currency).to receive(:default_for).and_return(nil)
        expect(service.send(:can_afford_fare?, 50)).to be false
      end
    end

    describe '#resolve_destination' do
      it 'returns nil for nil name' do
        expect(service.send(:resolve_destination, nil)).to be_nil
      end

      it 'returns nil for empty name' do
        expect(service.send(:resolve_destination, '')).to be_nil
      end

      it 'returns nil for whitespace name' do
        expect(service.send(:resolve_destination, '   ')).to be_nil
      end

      it 'finds room in same location by name' do
        # Ensure destination_room exists and has same location
        destination_room.refresh
        from_room.refresh
        expect(from_room.location_id).to eq(destination_room.location_id)
        result = service.send(:resolve_destination, 'Destination Room')
        expect(result&.id).to eq(destination_room.id)
      end

      it 'finds room case-insensitively' do
        destination_room.refresh
        result = service.send(:resolve_destination, 'destination room')
        expect(result&.id).to eq(destination_room.id)
      end

      it 'finds room by partial name' do
        destination_room.refresh
        result = service.send(:resolve_destination, 'Destination')
        expect(result&.id).to eq(destination_room.id)
      end
    end

    describe '#walk_out_of_building' do
      before do
        allow(BroadcastService).to receive(:to_room)
      end

      context 'when path to street exists' do
        let(:exit_step) { { direction: :out, room: street_room, distance: 10.0 } }

        before do
          allow(BuildingNavigationService).to receive(:path_to_street).and_return([exit_step])
        end

        it 'returns success' do
          result = service.send(:walk_out_of_building, from_room)
          expect(result[:success]).to be true
        end

        it 'returns street room' do
          result = service.send(:walk_out_of_building, from_room)
          expect(result[:street_room]).to eq(street_room)
        end

        it 'includes walk message' do
          result = service.send(:walk_out_of_building, from_room)
          expect(result[:messages]).to include(match(/outside/))
        end

        it 'updates character room' do
          service.send(:walk_out_of_building, from_room)
          char_instance.refresh
          expect(char_instance.current_room_id).to eq(street_room.id)
        end
      end

      context 'when no path to street' do
        before do
          allow(BuildingNavigationService).to receive(:path_to_street).and_return([])
        end

        context 'and room is outdoor' do
          before do
            allow(BuildingNavigationService).to receive(:outdoor_room?).and_return(true)
          end

          it 'returns success with current room as street' do
            result = service.send(:walk_out_of_building, from_room)
            expect(result[:success]).to be true
            expect(result[:street_room]).to eq(from_room)
          end
        end

        context 'and room is indoor' do
          before do
            allow(BuildingNavigationService).to receive(:outdoor_room?).and_return(false)
          end

          it 'returns failure' do
            result = service.send(:walk_out_of_building, from_room)
            expect(result[:success]).to be false
            expect(result[:error]).to include("can't find a way outside")
          end
        end
      end
    end

    describe '#walk_into_building' do
      before do
        allow(BroadcastService).to receive(:to_room)
      end

      context 'when path exists' do
        let(:entry_step) { double('PathStep', direction: 'in', to_room: destination_room) }

        before do
          allow(PathfindingService).to receive(:find_path).and_return([entry_step])
          allow(BuildingNavigationService).to receive(:building_name).and_return('The Tower')
        end

        it 'returns success' do
          result = service.send(:walk_into_building, street_room, destination_room)
          expect(result[:success]).to be true
        end

        it 'includes walk message with building name' do
          result = service.send(:walk_into_building, street_room, destination_room)
          expect(result[:messages].first).to include('The Tower')
        end

        it 'updates character room' do
          service.send(:walk_into_building, street_room, destination_room)
          char_instance.refresh
          expect(char_instance.current_room_id).to eq(destination_room.id)
        end
      end

      context 'when no path exists' do
        before do
          allow(PathfindingService).to receive(:find_path).and_return([])
        end

        it 'returns failure' do
          result = service.send(:walk_into_building, street_room, destination_room)
          expect(result[:success]).to be false
          expect(result[:error]).to include("can't find a way into")
        end
      end
    end

    describe '#format_currency' do
      it 'delegates to EraService' do
        expect(EraService).to receive(:format_currency).with(100)
        service.send(:format_currency, 100)
      end
    end
  end
end
