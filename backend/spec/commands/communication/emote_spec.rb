# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Emote, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }
  let(:other_character) { create(:character) }
  let(:other_instance) { create(:character_instance, character: other_character, current_room: room, reality: reality) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with basic emote text' do
      it 'processes emote and broadcasts to room' do
        result = command.execute('emote looks around nervously.')

        expect(result[:success]).to be true
        expect(result[:message]).to include(character.forename)
        expect(result[:message]).to include('looks around nervously')
      end
    end

    context 'with no emote text provided' do
      it 'returns error asking what to emote' do
        result = command.execute('emote')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/What did you want to emote\?/i)
      end

      it 'handles empty string' do
        result = command.execute('emote ')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/What did you want to emote\?/i)
      end
    end

    context 'with @mention targeting' do
      before { other_instance } # ensure other character is in the room

      it 'resolves @forename in emote text without errors' do
        result = command.execute("emote smiles at @#{other_character.forename} warmly")
        expect(result[:success]).to be true
      end

      it 'handles unresolved @mentions gracefully' do
        result = command.execute('emote looks at @nobody warmly')
        expect(result[:success]).to be true
        expect(result[:message]).to include('@nobody')
      end
    end

    context 'with adverbs' do
      it 'incorporates adverbs into the emote' do
        result = command.execute('emote quickly looks around nervously.')

        expect(result[:success]).to be true
        expect(result[:message].downcase).to include('quickly')
        expect(result[:message]).to include(character.forename)
      end
    end
  end

  describe '#can_execute?' do
    subject(:command) { described_class.new(character_instance) }

    it 'returns true when character is in a room' do
      expect(command.can_execute?).to be true
    end

    it 'returns false when character has no room' do
      # Mock a scenario where location is nil (character not in a room)
      allow(command).to receive(:location).and_return(nil)
      expect(command.can_execute?).to be false
    end
  end

  describe 'rate limiting in crowded rooms' do
    subject(:command) { described_class.new(character_instance) }

    context 'when room has more than 8 characters' do
      before do
        # Create 8 more characters (9 total with our test character)
        8.times do
          char = create_test_character
          create_test_character_instance(character: char, room: room, reality: reality)
        end
      end

      it 'records emotes for rate limiting' do
        EmoteRateLimitService.clear(character_instance.id)
        expect(EmoteRateLimitService.get_emote_count(character_instance.id)).to eq(0)

        result = command.execute('emote looks around.')
        expect(result[:success]).to be true
        expect(EmoteRateLimitService.get_emote_count(character_instance.id)).to eq(1)
      end

      it 'blocks emotes when rate limit exceeded' do
        # Record 3 emotes (at limit)
        3.times { EmoteRateLimitService.record_emote(character_instance.id) }

        result = command.execute('emote tries another emote.')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Please wait')
      end

      it 'allows emotes for spotlighted characters' do
        character_instance.spotlight_on!
        3.times { EmoteRateLimitService.record_emote(character_instance.id) }

        result = command.execute('emote performs dramatically.')
        expect(result[:success]).to be true
      end
    end

    context 'when room has 8 or fewer characters' do
      it 'does not rate limit' do
        # Just our character and one other
        other_instance

        # Should work even after many emotes
        result = command.execute('emote tests rate limiting.')
        expect(result[:success]).to be true
      end
    end
  end

  describe 'spotlight decrement' do
    subject(:command) { described_class.new(character_instance) }

    it 'decrements spotlight after emote for unlimited spotlight' do
      character_instance.spotlight_on!
      expect(character_instance.spotlighted?).to be true

      command.execute('emote performs dramatically.')
      character_instance.reload
      expect(character_instance.spotlighted?).to be false
    end

    it 'decrements spotlight count for counted spotlight' do
      character_instance.spotlight_on!(count: 3)

      command.execute('emote performs.')
      character_instance.reload
      expect(character_instance.spotlighted?).to be true
      expect(character_instance.spotlight_remaining).to eq(2)
    end

    it 'turns off spotlight when count reaches zero' do
      character_instance.spotlight_on!(count: 1)

      command.execute('emote performs.')
      character_instance.reload
      expect(character_instance.spotlighted?).to be false
    end
  end

  # Use shared example for command metadata
  # Note: 'subtle' is no longer an alias - it's a separate command
  it_behaves_like "command metadata", 'emote', :roleplaying, ['pose', ':']
end
