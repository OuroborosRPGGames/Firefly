# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::Windows, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room', curtains: false) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when not owner' do
      it 'returns error' do
        result = command.execute('windows')
        expect(result[:success]).to be false
        expect(result[:message]).to include("own this room")
      end
    end

    context 'when owner' do
      before do
        room.update(owner_id: character.id)
      end

      context 'when curtains are open' do
        before do
          room.update(curtains: false)
        end

        it 'returns success' do
          result = command.execute('windows')
          expect(result[:success]).to be true
        end

        it 'closes the curtains' do
          command.execute('windows')
          room.refresh
          expect(room.curtains).to be true
        end

        it 'returns close message' do
          result = command.execute('windows')
          expect(result[:message]).to include('close the curtains')
        end
      end

      context 'when curtains are closed' do
        before do
          room.update(curtains: true)
        end

        it 'opens the curtains' do
          command.execute('windows')
          room.refresh
          expect(room.curtains).to be false
        end

        it 'returns open message' do
          result = command.execute('windows')
          expect(result[:message]).to include('open the curtains')
        end
      end
    end
  end
end
