# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::Decorate, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when not owner' do
      it 'returns error' do
        result = command.execute('decorate A lovely painting hangs on the wall.')
        expect(result[:success]).to be false
        expect(result[:message]).to include("not in a property you own")
      end
    end

    context 'when owner' do
      before do
        room.update(owner_id: character.id)
      end

      context 'with no description' do
        it 'returns error' do
          result = command.execute('decorate')
          expect(result[:success]).to be false
          expect(result[:message]).to include('What decoration')
        end
      end

      context 'with valid description' do
        it 'returns success' do
          result = command.execute('decorate A lovely painting hangs on the wall.')
          expect(result[:success]).to be true
        end

        it 'creates decoration record' do
          expect { command.execute('decorate A lovely painting hangs on the wall.') }
            .to change { Decoration.count }.by(1)
        end

        it 'associates with room' do
          command.execute('decorate A lovely painting hangs on the wall.')
          decoration = Decoration.last
          expect(decoration.room_id).to eq(room.id)
        end

        it 'stores the description' do
          command.execute('decorate A lovely painting hangs on the wall.')
          decoration = Decoration.last
          expect(decoration.description).to eq('A lovely painting hangs on the wall.')
        end

        it 'increments display order' do
          command.execute('decorate First decoration')
          command.execute('decorate Second decoration')
          decorations = Decoration.where(room_id: room.id).order(:display_order).all
          expect(decorations[0].display_order).to eq(1)
          expect(decorations[1].display_order).to eq(2)
        end
      end
    end
  end
end
