# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::Rename, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Original Name', short_description: 'A room') }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when not owner' do
      it 'returns error' do
        result = command.execute('rename New Name')
        expect(result[:success]).to be false
        expect(result[:message]).to include("own this room")
      end
    end

    context 'when owner' do
      before do
        room.update(owner_id: character.id)
      end

      context 'with no name provided' do
        it 'returns error' do
          result = command.execute('rename')
          expect(result[:success]).to be false
          expect(result[:message]).to include('What do you want to rename')
        end
      end

      context 'with name too long' do
        it 'returns error' do
          long_name = 'a' * 101
          result = command.execute("rename #{long_name}")
          expect(result[:success]).to be false
          expect(result[:message]).to include('100 characters or less')
        end
      end

      context 'with valid name' do
        it 'returns success' do
          result = command.execute('rename Cozy Den')
          expect(result[:success]).to be true
        end

        it 'updates the room name' do
          command.execute('rename Cozy Den')
          room.refresh
          expect(room.name).to eq('Cozy Den')
        end

        it 'returns confirmation message' do
          result = command.execute('rename Cozy Den')
          expect(result[:message]).to include("rename 'Original Name' to 'Cozy Den'")
        end
      end
    end
  end
end
