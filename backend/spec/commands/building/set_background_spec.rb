# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::SetBackground, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when not owner' do
      it 'returns error' do
        result = command.execute('set background https://example.com/bg.jpg')
        expect(result[:success]).to be false
        expect(result[:message]).to include("own this room")
      end
    end

    context 'when owner' do
      before do
        room.update(owner_id: character.id)
      end

      context 'with no URL provided' do
        context 'when no background is set' do
          it 'returns error' do
            result = command.execute('set background')
            expect(result[:success]).to be false
            expect(result[:message]).to include('What image URL')
          end
        end

        context 'when background is set' do
          before do
            room.update(default_background_url: 'https://example.com/old.jpg')
          end

          it 'removes the background' do
            result = command.execute('set background')
            expect(result[:success]).to be true
            room.refresh
            expect(room.default_background_url).to be_nil
          end
        end
      end

      context 'with invalid URL' do
        it 'returns error' do
          result = command.execute('set background not-a-url')
          expect(result[:success]).to be false
          expect(result[:message]).to include('valid URL')
        end
      end

      context 'with valid URL' do
        it 'returns success' do
          result = command.execute('set background https://example.com/room.jpg')
          expect(result[:success]).to be true
        end

        it 'sets the background URL' do
          command.execute('set background https://example.com/room.jpg')
          room.refresh
          expect(room.default_background_url).to eq('https://example.com/room.jpg')
        end

        it 'returns confirmation message' do
          result = command.execute('set background https://example.com/room.jpg')
          expect(result[:message]).to include('set the background')
        end
      end

      context 'using alias' do
        it 'works with setbg' do
          result = command.execute('setbg https://example.com/room.jpg')
          expect(result[:success]).to be true
        end
      end
    end
  end
end
