# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TtsNarrationService do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:room) { create(:room) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe 'class methods' do
    it 'responds to narrate' do
      expect(described_class).to respond_to(:narrate)
    end

    it 'responds to narrate_async' do
      expect(described_class).to respond_to(:narrate_async)
    end

    it 'responds to narrate_batch' do
      expect(described_class).to respond_to(:narrate_batch)
    end

    it 'responds to narrate_room_entry' do
      expect(described_class).to respond_to(:narrate_room_entry)
    end

    it 'responds to narrate_emote' do
      expect(described_class).to respond_to(:narrate_emote)
    end
  end

  describe '.narrate_async' do
    before do
      allow(TtsService).to receive(:available?).and_return(true)
    end

    context 'with invalid preconditions' do
      it 'returns queued: false for nil character_instance' do
        result = described_class.narrate_async(nil, 'test', type: :system)
        expect(result[:queued]).to be false
        expect(result[:reason]).to eq('No character instance')
      end

      it 'returns queued: false when TTS is disabled for character' do
        allow(character_instance).to receive(:tts_enabled?).and_return(false)
        result = described_class.narrate_async(character_instance, 'test', type: :system)
        expect(result[:queued]).to be false
        expect(result[:reason]).to eq('TTS not enabled for character')
      end

      it 'returns queued: false when narration disabled for type' do
        allow(character_instance).to receive(:tts_enabled?).and_return(true)
        allow(character_instance).to receive(:should_narrate?).with(:system).and_return(false)
        result = described_class.narrate_async(character_instance, 'test', type: :system)
        expect(result[:queued]).to be false
        expect(result[:reason]).to include('Narration disabled for type')
      end

      it 'returns queued: false when TTS service unavailable' do
        allow(character_instance).to receive(:tts_enabled?).and_return(true)
        allow(character_instance).to receive(:should_narrate?).and_return(true)
        allow(TtsService).to receive(:available?).and_return(false)
        result = described_class.narrate_async(character_instance, 'test', type: :system)
        expect(result[:queued]).to be false
        expect(result[:reason]).to eq('TTS service not available')
      end
    end

    context 'with valid preconditions' do
      before do
        allow(character_instance).to receive(:tts_enabled?).and_return(true)
        allow(character_instance).to receive(:should_narrate?).and_return(true)
      end

      it 'returns queued: true with a request_id' do
        result = described_class.narrate_async(character_instance, 'test', type: :system)
        expect(result[:queued]).to be true
        expect(result[:request_id]).to be_a(String)
        expect(result[:request_id].length).to eq(36) # UUID format
      end

      it 'returns immediately without blocking' do
        start_time = Time.now
        described_class.narrate_async(character_instance, 'test', type: :system)
        elapsed = Time.now - start_time
        expect(elapsed).to be < 0.1 # Should return almost immediately
      end

      it 'calls the callback with result when provided' do
        callback_result = nil
        callback = ->(result) { callback_result = result }

        allow(described_class).to receive(:narrate).and_return({ audio_url: '/audios/test.mp3', type: :narrator })
        allow(BroadcastService).to receive(:to_character)
        allow(Thread).to receive(:new) { |&block| block.call }

        described_class.narrate_async(
          character_instance,
          'test content',
          type: :system,
          callback: callback
        )

        expect(callback_result).not_to be_nil
        expect(callback_result[:audio_url]).to eq('/audios/test.mp3')
      end

      it 'broadcasts result to character when broadcast: true' do
        allow(described_class).to receive(:narrate).and_return({ audio_url: '/audios/test.mp3', type: :narrator })
        allow(Thread).to receive(:new) { |&block| block.call }
        expect(BroadcastService).to receive(:to_character).with(
          character_instance,
          nil,
          type: :tts_audio,
          data: hash_including(:request_id, :audio_url, :narration_type)
        )

        described_class.narrate_async(
          character_instance,
          'test content',
          type: :system,
          broadcast: true
        )
      end

      it 'does not broadcast when broadcast: false' do
        allow(described_class).to receive(:narrate).and_return({ audio_url: '/audios/test.mp3', type: :narrator })
        allow(Thread).to receive(:new) { |&block| block.call }
        expect(BroadcastService).not_to receive(:to_character)

        described_class.narrate_async(
          character_instance,
          'test content',
          type: :system,
          broadcast: false
        )
      end
    end
  end

  describe '.narrate' do
    before do
      allow(TtsService).to receive(:available?).and_return(true)
      allow(character_instance).to receive(:tts_enabled?).and_return(true)
      allow(character_instance).to receive(:should_narrate?).and_return(true)
    end

    it 'returns nil for nil character_instance' do
      result = described_class.narrate(nil, 'test', type: :system)
      expect(result).to be_nil
    end

    it 'returns nil when TTS is disabled' do
      allow(character_instance).to receive(:tts_enabled?).and_return(false)
      result = described_class.narrate(character_instance, 'test', type: :system)
      expect(result).to be_nil
    end

    it 'returns nil when TTS service unavailable' do
      allow(TtsService).to receive(:available?).and_return(false)
      result = described_class.narrate(character_instance, 'test', type: :system)
      expect(result).to be_nil
    end
  end
end
