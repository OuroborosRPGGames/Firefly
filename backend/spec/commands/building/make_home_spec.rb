# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::MakeHome, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:old_home) { create(:room, location: location, name: 'Old Home', short_description: 'Old home room') }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when not owner' do
      it 'returns error' do
        result = command.execute('make home')
        expect(result[:success]).to be false
        expect(result[:message]).to include('room you own')
      end
    end

    context 'when owner' do
      before do
        room.update(owner_id: character.id)
      end

      context 'with no previous home' do
        it 'returns success' do
          result = command.execute('make home')
          expect(result[:success]).to be true
        end

        it 'sets home room' do
          command.execute('make home')
          character.refresh
          expect(character.home_room_id).to eq(room.id)
        end

        it 'returns confirmation message' do
          result = command.execute('make home')
          expect(result[:message]).to include('set this room as your home')
        end
      end

      context 'with previous home' do
        before do
          old_home.update(owner_id: character.id)
          character.update(home_room_id: old_home.id)
        end

        it 'replaces the home' do
          command.execute('make home')
          character.refresh
          expect(character.home_room_id).to eq(room.id)
        end

        it 'mentions the old home in message' do
          result = command.execute('make home')
          expect(result[:message]).to include('replacing')
          expect(result[:message]).to include('Old Home')
        end
      end

      context 'using alias' do
        it 'works with makehome' do
          result = command.execute('makehome')
          expect(result[:success]).to be true
        end

        it 'works with sethome' do
          result = command.execute('sethome')
          expect(result[:success]).to be true
        end
      end
    end
  end
end
