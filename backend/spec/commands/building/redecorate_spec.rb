# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::Redecorate, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when not owner' do
      it 'returns error' do
        result = command.execute('redecorate Minimalist style.')
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
          result = command.execute('redecorate')
          expect(result[:success]).to be false
          expect(result[:message]).to include('What decoration')
        end
      end

      context 'with no existing decorations' do
        it 'returns success' do
          result = command.execute('redecorate Minimalist style.')
          expect(result[:success]).to be true
        end

        it 'creates new decoration' do
          expect { command.execute('redecorate Minimalist style.') }
            .to change { Decoration.count }.by(1)
        end
      end

      context 'with existing decorations' do
        before do
          Decoration.create(room_id: room.id, name: 'Old 1', description: 'Old decoration 1', display_order: 1)
          Decoration.create(room_id: room.id, name: 'Old 2', description: 'Old decoration 2', display_order: 2)
        end

        it 'returns success' do
          result = command.execute('redecorate Minimalist style.')
          expect(result[:success]).to be true
        end

        it 'removes old decorations' do
          command.execute('redecorate Minimalist style.')
          expect(room.decorations_dataset.count).to eq(1)
        end

        it 'creates new decoration with new description' do
          command.execute('redecorate Minimalist style.')
          decoration = Decoration.where(room_id: room.id).first
          expect(decoration.description).to eq('Minimalist style.')
        end

        it 'mentions replaced count in message' do
          result = command.execute('redecorate Minimalist style.')
          expect(result[:message]).to include('replacing 2 decorations')
        end
      end
    end
  end
end
