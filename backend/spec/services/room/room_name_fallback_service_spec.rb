# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomNameFallbackService do
  let(:location) { create(:location) }
  # Main room: 0-100 in both x and y (plaza type is outdoor for spatial adjacency)
  let(:room) { create(:room, location: location, name: 'Town Square', room_type: 'plaza', min_x: 0.0, max_x: 100.0, min_y: 0.0, max_y: 100.0) }
  # Tavern: north of room (shares edge at y=100)
  let(:tavern) { create(:room, location: location, name: 'Tavern', room_type: 'plaza', min_x: 0.0, max_x: 100.0, min_y: 100.0, max_y: 200.0) }
  # Market: south of room (shares edge at y=0)
  let(:market) { create(:room, location: location, name: 'Market', room_type: 'plaza', min_x: 0.0, max_x: 100.0, min_y: -100.0, max_y: 0.0) }
  let(:character) { create(:character) }
  let(:char_instance) { create(:character_instance, character: character, current_room_id: room.id) }

  # Ensure rooms are created before tests run
  before do
    room
    tavern
    market
  end

  describe '.try_fallback' do
    context 'with exact room name match' do
      it 'returns walk command for matching adjacent room' do
        result = described_class.try_fallback(char_instance, 'Tavern')
        expect(result).to eq('walk Tavern')
      end

      it 'matches case-insensitively' do
        result = described_class.try_fallback(char_instance, 'tavern')
        expect(result).to eq('walk Tavern')
      end

      it 'matches another adjacent room' do
        result = described_class.try_fallback(char_instance, 'market')
        expect(result).to eq('walk Market')
      end
    end

    context 'with non-matching input' do
      it 'returns nil for non-room input' do
        result = described_class.try_fallback(char_instance, 'look')
        expect(result).to be_nil
      end

      it 'returns nil for non-adjacent room name' do
        other_room = create(:room, name: 'Other Place')
        result = described_class.try_fallback(char_instance, 'Other Place')
        expect(result).to be_nil
      end

      it 'returns nil for partial matches' do
        result = described_class.try_fallback(char_instance, 'Tav')
        expect(result).to be_nil
      end
    end

    context 'with invalid input' do
      it 'returns nil for nil input' do
        result = described_class.try_fallback(char_instance, nil)
        expect(result).to be_nil
      end

      it 'returns nil for empty string' do
        result = described_class.try_fallback(char_instance, '')
        expect(result).to be_nil
      end

      it 'returns nil for whitespace-only input' do
        result = described_class.try_fallback(char_instance, '   ')
        expect(result).to be_nil
      end
    end

    context 'with no current room' do
      it 'returns nil when character has no room' do
        # Mock current_room to return nil instead of trying to update the validated field
        allow(char_instance).to receive(:current_room).and_return(nil)
        result = described_class.try_fallback(char_instance, 'Tavern')
        expect(result).to be_nil
      end
    end

    context 'with no exits' do
      let(:isolated_room) { create(:room, name: 'Isolated') }
      let(:isolated_instance) { create(:character_instance, character: character, current_room_id: isolated_room.id) }

      it 'returns nil when room has no exits' do
        result = described_class.try_fallback(isolated_instance, 'Tavern')
        expect(result).to be_nil
      end
    end

    context 'input trimming' do
      it 'handles leading/trailing whitespace' do
        result = described_class.try_fallback(char_instance, '  Tavern  ')
        expect(result).to eq('walk Tavern')
      end
    end
  end
end
