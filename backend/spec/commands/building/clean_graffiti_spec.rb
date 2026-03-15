# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::CleanGraffiti, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when not owner' do
      it 'returns error' do
        result = command.execute('clean graffiti')
        expect(result[:success]).to be false
        expect(result[:message]).to include("own this room")
      end
    end

    context 'when owner' do
      before do
        room.update(owner_id: character.id)
      end

      context 'with no graffiti' do
        it 'returns error' do
          result = command.execute('clean graffiti')
          expect(result[:success]).to be false
          expect(result[:message]).to include('no graffiti to clean')
        end
      end

      context 'with graffiti' do
        before do
          Graffiti.create(room_id: room.id, text: 'Test graffiti 1')
          Graffiti.create(room_id: room.id, text: 'Test graffiti 2')
        end

        it 'returns success' do
          result = command.execute('clean graffiti')
          expect(result[:success]).to be true
        end

        it 'removes all graffiti' do
          expect { command.execute('clean graffiti') }
            .to change { room.graffiti_dataset.count }.from(2).to(0)
        end

        it 'returns count in message' do
          result = command.execute('clean graffiti')
          expect(result[:message]).to include('2 pieces')
        end
      end

      context 'with single graffiti' do
        before do
          Graffiti.create(room_id: room.id, text: 'Test graffiti')
        end

        it 'uses singular form' do
          result = command.execute('clean graffiti')
          expect(result[:message]).to include('1 piece of graffiti')
          expect(result[:message]).not_to include('pieces')
        end
      end
    end
  end
end
