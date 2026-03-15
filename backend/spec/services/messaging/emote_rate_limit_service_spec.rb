# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EmoteRateLimitService do
  let(:reality) { create_test_reality }
  let(:room) { create_test_room }
  let(:character) { create_test_character }
  let(:character_instance) { create_test_character_instance(character: character, room: room, reality: reality) }

  before do
    # Clear any existing rate limit keys
    described_class.clear(character_instance.id)
  end

  describe '.check' do
    context 'when room has 8 or fewer characters' do
      it 'returns allowed without checking rate limit' do
        # Just our character
        result = described_class.check(character_instance, room)
        expect(result[:allowed]).to be true
        expect(result[:remaining]).to eq(3)
      end
    end

    context 'when room has more than 8 characters' do
      before do
        # Create 8 more characters (9 total)
        8.times do
          char = create_test_character
          create_test_character_instance(character: char, room: room, reality: reality)
        end
      end

      it 'allows emotes within the limit' do
        result = described_class.check(character_instance, room)
        expect(result[:allowed]).to be true
      end

      it 'blocks emotes after exceeding the limit' do
        # Record 3 emotes (at limit)
        3.times { described_class.record_emote(character_instance.id) }

        result = described_class.check(character_instance, room)
        expect(result[:allowed]).to be false
        expect(result[:message]).to include('Please wait')
      end

      it 'shows remaining emotes' do
        described_class.record_emote(character_instance.id)
        result = described_class.check(character_instance, room)

        expect(result[:allowed]).to be true
        expect(result[:remaining]).to eq(2)
      end

      context 'when character is exempt' do
        it 'allows unlimited emotes for spotlighted characters' do
          character_instance.spotlight_on!
          3.times { described_class.record_emote(character_instance.id) }

          result = described_class.check(character_instance, room)
          expect(result[:allowed]).to be true
          expect(result[:exempt]).to be true
        end

        it 'allows unlimited emotes for event organizers' do
          Event.create(
            name: 'Test Event',
            organizer_id: character.id,
            status: 'active',
            room_id: room.id,
            event_type: 'party',
            starts_at: Time.now
          )

          3.times { described_class.record_emote(character_instance.id) }

          result = described_class.check(character_instance, room)
          expect(result[:allowed]).to be true
        end

        it 'allows unlimited emotes for event staff' do
          organizer_char = create_test_character
          event = Event.create(
            name: 'Test Event',
            organizer_id: organizer_char.id,
            status: 'active',
            room_id: room.id,
            event_type: 'party',
            starts_at: Time.now
          )
          EventAttendee.create(
            event_id: event.id,
            character_id: character.id,
            role: 'staff'
          )

          3.times { described_class.record_emote(character_instance.id) }

          result = described_class.check(character_instance, room)
          expect(result[:allowed]).to be true
        end
      end
    end
  end

  describe '.record_emote' do
    it 'increments the emote count' do
      expect(described_class.get_emote_count(character_instance.id)).to eq(0)

      described_class.record_emote(character_instance.id)
      expect(described_class.get_emote_count(character_instance.id)).to eq(1)

      described_class.record_emote(character_instance.id)
      expect(described_class.get_emote_count(character_instance.id)).to eq(2)
    end
  end

  describe '.rate_limiting_active?' do
    it 'returns false for 8 or fewer characters' do
      expect(described_class.rate_limiting_active?(room, reality.id)).to be false
    end

    it 'returns true for more than 8 characters' do
      8.times do
        char = create_test_character
        create_test_character_instance(character: char, room: room, reality: reality)
      end

      expect(described_class.rate_limiting_active?(room, reality.id)).to be true
    end
  end

  describe '.clear' do
    it 'resets the emote count' do
      described_class.record_emote(character_instance.id)
      described_class.record_emote(character_instance.id)
      expect(described_class.get_emote_count(character_instance.id)).to eq(2)

      described_class.clear(character_instance.id)
      expect(described_class.get_emote_count(character_instance.id)).to eq(0)
    end
  end
end
