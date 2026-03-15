# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::SEmote, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }
  let(:other_character) { create(:character) }
  let(:other_instance) { create(:character_instance, character: other_character, current_room: room, reality: reality) }

  describe 'command metadata' do
    it_behaves_like "command metadata", 'semote', :roleplaying, ['smartemote', 'sem']
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with valid emote text' do
      it 'broadcasts emote to room' do
        result = command.execute('semote waves hello to everyone.')

        expect(result[:success]).to be true
        expect(result[:message]).to include(character.forename)
        expect(result[:message]).to include('waves hello to everyone')
      end

      it 'returns success with emote message' do
        result = command.execute('semote stretches lazily.')

        expect(result[:success]).to be true
        expect(result[:message]).to include('stretches lazily')
      end
    end

    context 'with empty emote text' do
      it 'rejects empty emotes' do
        result = command.execute('semote')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/What did you want to emote\?/i)
      end

      it 'rejects whitespace-only emotes' do
        result = command.execute('semote   ')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/What did you want to emote\?/i)
      end
    end

    context 'when character is in combat' do
      before do
        # Create a fight and add the character as a participant
        fight = create(:fight, room: room)
        create(:fight_participant, fight: fight, character_instance: character_instance)
      end

      it 'still broadcasts the emote' do
        result = command.execute('semote swings wildly.')

        expect(result[:success]).to be true
        expect(result[:message]).to include('swings wildly')
      end

      it 'skips LLM processing when in combat' do
        # LLM processing should be skipped, so SemoteInterpreterService should not be called
        expect(SemoteInterpreterService).not_to receive(:interpret)

        command.execute('semote swings wildly.')
      end
    end

    context 'when character is not in combat' do
      it 'spawns background thread for LLM processing' do
        # We should see Thread.new being called for async processing
        allow(Thread).to receive(:new).and_yield

        # Mock the interpreter and executor services
        allow(SemoteInterpreterService).to receive(:interpret).and_return({
          success: true,
          actions: [{ command: 'stand', target: nil }]
        })
        allow(SemoteExecutorService).to receive(:execute_actions_sequentially)

        command.execute('semote stands up quickly.')

        expect(SemoteInterpreterService).to have_received(:interpret)
      end
    end
  end

  describe '#can_execute?' do
    subject(:command) { described_class.new(character_instance) }

    it 'returns true when character is in a room' do
      expect(command.can_execute?).to be true
    end

    it 'returns false when character has no room' do
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

      it 'blocks emotes when rate limit exceeded' do
        # Record 3 emotes (at limit)
        3.times { EmoteRateLimitService.record_emote(character_instance.id) }

        result = command.execute('semote tries to speak.')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Please wait')
      end
    end
  end

  describe 'spotlight behavior' do
    subject(:command) { described_class.new(character_instance) }

    it 'decrements spotlight after semote' do
      character_instance.spotlight_on!
      expect(character_instance.spotlighted?).to be true

      command.execute('semote performs dramatically.')
      character_instance.reload
      expect(character_instance.spotlighted?).to be false
    end
  end
end
