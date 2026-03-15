# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Vehicles::CloseRoof, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when not in a vehicle' do
      it 'returns error' do
        result = command.execute('close roof')
        expect(result[:success]).to be false
        expect(result[:error]).to include('not in a vehicle')
      end
    end

    context 'when in a non-convertible vehicle' do
      let(:vehicle) do
        # Use production column names: char_id, room_id, opentop
        Vehicle.create(
          name: 'Regular Car',
          char_id: character.id,
          room_id: room.id,
          vtype: 'sedan',
          convertible: false
        )
      end

      before do
        vehicle
        character_instance.update(current_vehicle_id: vehicle.id)
      end

      it 'returns error' do
        result = command.execute('close roof')
        expect(result[:success]).to be false
        expect(result[:error]).to include("doesn't have a convertible roof")
      end
    end

    context 'when in a convertible vehicle with roof open' do
      let(:vehicle) do
        # Use production column names: char_id, room_id, opentop
        Vehicle.create(
          name: 'Sporty Convertible',
          char_id: character.id,
          room_id: room.id,
          vtype: 'convertible',
          convertible: true,
          opentop: true
        )
      end

      before do
        vehicle
        character_instance.update(current_vehicle_id: vehicle.id)
      end

      it 'returns success' do
        result = command.execute('close roof')
        expect(result[:success]).to be true
      end

      it 'returns confirmation message' do
        result = command.execute('close roof')
        expect(result[:message]).to include('close the roof')
      end

      it 'closes the roof' do
        command.execute('close roof')
        expect(vehicle.reload.roof_closed?).to be true
      end

      context 'when roof is already closed' do
        before { vehicle.update(opentop: false) }

        it 'returns error' do
          result = command.execute('close roof')
          expect(result[:success]).to be false
          expect(result[:error]).to include('already closed')
        end
      end
    end

    context 'as a passenger' do
      let(:vehicle) do
        Vehicle.create(
          name: 'Sporty Convertible',
          char_id: character.id,
          room_id: room.id,
          vtype: 'convertible',
          convertible: true,
          opentop: true
        )
      end

      before do
        vehicle
        character_instance.update(current_vehicle_id: vehicle.id)
      end

      it 'can still close the roof' do
        result = command.execute('close roof')
        expect(result[:success]).to be true
      end
    end

    context 'with aliases' do
      it 'works with roof close alias' do
        command_class, _words = Commands::Base::Registry.find_command('roof close')
        expect(command_class).to eq(Commands::Vehicles::CloseRoof)
      end
    end
  end
end
