# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::ResizeRoom, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when not owner' do
      it 'returns error' do
        result = command.execute('resize room 10 10 3')
        expect(result[:success]).to be false
        expect(result[:message]).to include("own this room")
      end
    end

    context 'when owner' do
      before do
        room.update(owner_id: character.id)
      end

      context 'with missing dimensions' do
        it 'returns error' do
          result = command.execute('resize room 10 10')
          expect(result[:success]).to be false
          expect(result[:message]).to include('Usage')
        end
      end

      context 'with invalid dimensions' do
        it 'returns error for zero values' do
          result = command.execute('resize room 0 10 3')
          expect(result[:success]).to be false
          expect(result[:message]).to include('positive numbers')
        end

        it 'returns error for negative values' do
          result = command.execute('resize room -5 10 3')
          expect(result[:success]).to be false
          # Negative values fail regex validation before positivity check
          expect(result[:message]).to include('valid numbers')
        end
      end

      context 'with valid dimensions' do
        it 'returns success' do
          result = command.execute('resize room 10 10 3')
          expect(result[:success]).to be true
        end

        it 'updates the room dimensions' do
          command.execute('resize room 10 10 3')
          room.refresh
          expect(room.min_x).to eq(-5.0)
          expect(room.max_x).to eq(5.0)
          expect(room.min_y).to eq(-5.0)
          expect(room.max_y).to eq(5.0)
          expect(room.max_z).to eq(3.0)
        end

        it 'returns confirmation message' do
          result = command.execute('resize room 10 10 3')
          expect(result[:message]).to include('10.0x10.0x3.0')
        end
      end
    end
  end
end
