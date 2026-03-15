# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EmoteFormatterService do
  let(:location) { create(:location) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room', location: location) }
  let(:reality) { create(:reality) }

  let(:user1) { create(:user) }
  let(:emoting_character) { create(:character, forename: 'Alice', surname: 'Smith', user: user1, distinctive_color: '#FF5733') }
  let(:emoting_instance) { create(:character_instance, character: emoting_character, reality: reality, current_room: room) }

  let(:user2) { create(:user) }
  let(:viewer_character) { create(:character, forename: 'Bob', surname: 'Jones', user: user2) }
  let(:viewer_instance) { create(:character_instance, character: viewer_character, reality: reality, current_room: room) }

  let(:room_characters) { [emoting_instance, viewer_instance] }

  describe '.format_for_viewer' do
    context 'with nil or empty text' do
      it 'returns nil for nil input' do
        result = described_class.format_for_viewer(nil, emoting_character, viewer_instance, room_characters)
        expect(result).to be_nil
      end

      it 'returns empty string for empty input' do
        result = described_class.format_for_viewer('', emoting_character, viewer_instance, room_characters)
        expect(result).to eq('')
      end
    end

    context 'with pure action text (no speech)' do
      it 'returns formatted action text' do
        emote = 'waves at everyone'
        result = described_class.format_for_viewer(emote, emoting_character, viewer_instance, room_characters)
        expect(result).to include('waves')
      end
    end

    context 'with speech text' do
      it 'wraps speech in color span' do
        emote = 'says "Hello everyone!"'
        result = described_class.format_for_viewer(emote, emoting_character, viewer_instance, room_characters)
        expect(result).to include('<span style="color:#FF5733">')
        expect(result).to include('Hello everyone!')
        expect(result).to include('</span>')
      end

      it 'preserves quotes around speech' do
        emote = 'says "Hi"'
        result = described_class.format_for_viewer(emote, emoting_character, viewer_instance, room_characters)
        expect(result).to include('"')
      end
    end

    context 'with no speech color set' do
      let(:emoting_character) { create(:character, forename: 'Alice', surname: 'Smith', user: user1, distinctive_color: nil) }

      it 'returns speech without color formatting' do
        emote = 'says "Hello"'
        result = described_class.format_for_viewer(emote, emoting_character, viewer_instance, room_characters)
        expect(result).not_to include('<span')
        expect(result).to include('Hello')
      end
    end

    context 'with invalid speech color' do
      let(:emoting_character) { create(:character, forename: 'Alice', surname: 'Smith', user: user1, distinctive_color: 'invalid') }

      it 'returns speech without color formatting' do
        emote = 'says "Hello"'
        result = described_class.format_for_viewer(emote, emoting_character, viewer_instance, room_characters)
        expect(result).not_to include('<span')
      end
    end

    context 'with mixed action and speech' do
      it 'formats both appropriately' do
        emote = 'waves and says "Hi there!"'
        result = described_class.format_for_viewer(emote, emoting_character, viewer_instance, room_characters)
        expect(result).to include('waves')
        expect(result).to include('Hi there!')
      end
    end

    context 'with nil room_characters' do
      it 'returns action text unsubstituted' do
        emote = 'waves'
        result = described_class.format_for_viewer(emote, emoting_character, viewer_instance, nil)
        expect(result).to include('waves')
      end
    end

    context 'with empty room_characters' do
      it 'returns action text unsubstituted' do
        emote = 'waves'
        result = described_class.format_for_viewer(emote, emoting_character, viewer_instance, [])
        expect(result).to include('waves')
      end
    end

    context 'color validation' do
      it 'accepts valid 6-digit hex colors' do
        char = create(:character, forename: 'Test', surname: 'User', user: user1, distinctive_color: '#AABBCC')
        emote = 'says "Test"'
        result = described_class.format_for_viewer(emote, char, viewer_instance, room_characters)
        expect(result).to include('color:#AABBCC')
      end

      it 'accepts valid 3-digit hex colors' do
        char = create(:character, forename: 'Test', surname: 'User', user: user1, distinctive_color: '#ABC')
        emote = 'says "Test"'
        result = described_class.format_for_viewer(emote, char, viewer_instance, room_characters)
        expect(result).to include('color:#ABC')
      end

      it 'rejects colors without hash' do
        char = create(:character, forename: 'Test', surname: 'User', user: user1, distinctive_color: 'FF5733')
        emote = 'says "Test"'
        result = described_class.format_for_viewer(emote, char, viewer_instance, room_characters)
        expect(result).not_to include('<span')
      end
    end
  end
end
