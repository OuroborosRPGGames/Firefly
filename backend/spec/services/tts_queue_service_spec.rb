# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TtsQueueService do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:instance) { create(:character_instance, character: character) }
  let(:service) { described_class.new(instance) }

  describe 'constants' do
    it 'defines CONTENT_VOICES mapping' do
      expect(described_class::CONTENT_VOICES).to include(
        narrator: :narrator,
        room: :narrator,
        speech: :character
      )
    end
  end

  describe '#initialize' do
    it 'accepts a character_instance' do
      expect(service.character_instance).to eq(instance)
    end
  end

  describe '.should_queue_for?' do
    context 'when character instance is nil' do
      it 'returns false' do
        expect(described_class.should_queue_for?(nil)).to be false
      end
    end

    context 'when accessibility mode is disabled' do
      before do
        allow(instance).to receive(:accessibility_mode?).and_return(false)
        allow(instance).to receive(:tts_enabled?).and_return(true)
        allow(instance).to receive(:tts_paused?).and_return(false)
      end

      it 'returns false' do
        expect(described_class.should_queue_for?(instance)).to be false
      end
    end

    context 'when TTS is disabled' do
      before do
        allow(instance).to receive(:accessibility_mode?).and_return(true)
        allow(instance).to receive(:tts_enabled?).and_return(false)
        allow(instance).to receive(:tts_paused?).and_return(false)
      end

      it 'returns false' do
        expect(described_class.should_queue_for?(instance)).to be false
      end
    end

    context 'when TTS is paused' do
      before do
        allow(instance).to receive(:accessibility_mode?).and_return(true)
        allow(instance).to receive(:tts_enabled?).and_return(true)
        allow(instance).to receive(:tts_paused?).and_return(true)
      end

      it 'returns false' do
        expect(described_class.should_queue_for?(instance)).to be false
      end
    end

    context 'when all conditions are met' do
      before do
        allow(instance).to receive(:accessibility_mode?).and_return(true)
        allow(instance).to receive(:tts_enabled?).and_return(true)
        allow(instance).to receive(:tts_paused?).and_return(false)
      end

      it 'returns true' do
        expect(described_class.should_queue_for?(instance)).to be true
      end
    end
  end

  describe '.queue_for' do
    let(:service_double) { instance_double(described_class) }

    before do
      allow(described_class).to receive(:new).with(instance).and_return(service_double)
    end

    context 'for speech type with speaker' do
      let(:speaker) { double('Character') }

      it 'calls queue_speech' do
        expect(service_double).to receive(:queue_speech).with('Hello!', speaker: speaker)

        described_class.queue_for(instance, 'Hello!', type: :speech, speaker: speaker)
      end
    end

    context 'for other types' do
      it 'calls queue_narration' do
        expect(service_double).to receive(:queue_narration).with('You enter a room.', type: :room)

        described_class.queue_for(instance, 'You enter a room.', type: :room)
      end
    end
  end

  describe '#queue_narration' do
    before do
      allow(instance).to receive(:accessibility_mode?).and_return(true)
      allow(instance).to receive(:tts_enabled?).and_return(true)
      allow(instance).to receive(:tts_paused?).and_return(false)
    end

    context 'when should not queue' do
      before do
        allow(instance).to receive(:accessibility_mode?).and_return(false)
      end

      it 'returns nil' do
        expect(service.queue_narration('Test content')).to be_nil
      end
    end

    context 'when content is nil' do
      it 'returns nil' do
        expect(service.queue_narration(nil)).to be_nil
      end
    end

    context 'when content is empty' do
      it 'returns nil' do
        expect(service.queue_narration('   ')).to be_nil
      end
    end

    context 'with valid content' do
      let(:tts_result) { { success: true, audio_url: 'https://example.com/audio.mp3' } }
      let(:queue_item) { double('AudioQueueItem') }

      before do
        allow(character).to receive(:user).and_return(user)
        allow(user).to receive(:narrator_settings).and_return({
          voice_type: 'en-US-Standard-A',
          voice_pitch: 0.0,
          voice_speed: 1.0
        })
        allow(TtsService).to receive(:synthesize).and_return(tts_result)
        allow(AudioQueueItem).to receive(:next_sequence_for).and_return(1)
        allow(AudioQueueItem).to receive(:create).and_return(queue_item)
        allow(queue_item).to receive(:to_api_hash).and_return({ id: 1 })
      end

      it 'synthesizes audio and creates queue item' do
        expect(TtsService).to receive(:synthesize).with(
          'Room description',
          voice_type: 'en-US-Standard-A',
          pitch: 0.0,
          speed: 1.0
        )

        service.queue_narration('Room description', type: :room)
      end

      it 'returns queue item info' do
        result = service.queue_narration('Room description', type: :room)

        expect(result).to eq({ id: 1 })
      end
    end

    context 'when synthesis fails' do
      before do
        allow(character).to receive(:user).and_return(user)
        allow(user).to receive(:narrator_settings).and_return({
          voice_type: 'en-US-Standard-A',
          voice_pitch: 0.0,
          voice_speed: 1.0
        })
        allow(TtsService).to receive(:synthesize).and_return({ success: false, error: 'API error' })
      end

      it 'returns nil' do
        result = service.queue_narration('Room description')

        expect(result).to be_nil
      end
    end
  end

  describe '#queue_speech' do
    let(:speaker) { create(:character, forename: 'Bob', surname: 'Smith') }

    before do
      allow(instance).to receive(:accessibility_mode?).and_return(true)
      allow(instance).to receive(:tts_enabled?).and_return(true)
      allow(instance).to receive(:tts_paused?).and_return(false)
    end

    context 'when should not queue' do
      before do
        allow(instance).to receive(:accessibility_mode?).and_return(false)
      end

      it 'returns nil' do
        expect(service.queue_speech('Hello!')).to be_nil
      end
    end

    context 'when content is nil' do
      it 'returns nil' do
        expect(service.queue_speech(nil)).to be_nil
      end
    end

    context 'with valid content' do
      let(:tts_result) { { success: true, audio_url: 'https://example.com/audio.mp3' } }
      let(:queue_item) { double('AudioQueueItem') }

      before do
        allow(TtsService).to receive(:synthesize).and_return(tts_result)
        allow(AudioQueueItem).to receive(:next_sequence_for).and_return(1)
        allow(AudioQueueItem).to receive(:create).and_return(queue_item)
        allow(queue_item).to receive(:to_api_hash).and_return({ id: 1 })
        allow(speaker).to receive(:full_name).and_return('Bob Smith')
        allow(speaker).to receive(:respond_to?).with(:voice_settings).and_return(false)
      end

      it 'prefixes content with speaker name' do
        expect(TtsService).to receive(:synthesize).with(
          'Bob Smith says: Hello!',
          voice_type: anything,
          pitch: anything,
          speed: anything
        )

        service.queue_speech('Hello!', speaker: speaker)
      end
    end
  end

  describe '#pending_items' do
    let(:items_dataset) { double('Dataset') }
    let(:item1) { double('AudioQueueItem') }

    before do
      allow(instance).to receive(:tts_queue_position).and_return(5)
      allow(AudioQueueItem).to receive(:pending_for).and_return([item1])
      allow(item1).to receive(:to_api_hash).and_return({ id: 1, content: 'Test' })
    end

    it 'returns pending items from the current position' do
      expect(AudioQueueItem).to receive(:pending_for).with(instance.id, from_position: 5, limit: 20)

      service.pending_items
    end

    it 'converts items to API hash format' do
      result = service.pending_items

      expect(result).to eq([{ id: 1, content: 'Test' }])
    end

    it 'uses custom from_position and limit' do
      expect(AudioQueueItem).to receive(:pending_for).with(instance.id, from_position: 10, limit: 5)

      service.pending_items(from_position: 10, limit: 5)
    end
  end

  describe '#mark_played_up_to' do
    let(:items_dataset) { double('Dataset') }

    before do
      allow(instance).to receive(:audio_queue_items_dataset).and_return(items_dataset)
      allow(items_dataset).to receive(:where).and_return(items_dataset)
      allow(items_dataset).to receive(:update).and_return(3)
      allow(instance).to receive(:update)
    end

    it 'marks items as played' do
      expect(items_dataset).to receive(:update).with(hash_including(played: true))

      service.mark_played_up_to(10)
    end

    it 'updates the queue position' do
      expect(instance).to receive(:update).with(tts_queue_position: 10)

      service.mark_played_up_to(10)
    end

    it 'returns the count of items marked' do
      result = service.mark_played_up_to(10)

      expect(result).to eq(3)
    end
  end

  describe '#clear_queue' do
    let(:items_dataset) { double('Dataset') }

    before do
      allow(instance).to receive(:audio_queue_items_dataset).and_return(items_dataset)
      allow(items_dataset).to receive(:where).with(played: false).and_return(items_dataset)
      allow(items_dataset).to receive(:delete).and_return(5)
      allow(instance).to receive(:skip_to_latest!)
    end

    it 'deletes pending items' do
      expect(items_dataset).to receive(:delete).and_return(5)

      service.clear_queue
    end

    it 'skips to latest' do
      expect(instance).to receive(:skip_to_latest!)

      service.clear_queue
    end

    it 'returns the count of items cleared' do
      result = service.clear_queue

      expect(result).to eq(5)
    end
  end

  describe '#queue_stats' do
    let(:items_dataset) { double('Dataset') }

    before do
      allow(instance).to receive(:audio_queue_items_dataset).and_return(items_dataset)
      allow(items_dataset).to receive(:count).and_return(10)
      allow(items_dataset).to receive(:where).with(played: false).and_return(double(count: 3))
      allow(instance).to receive(:tts_paused?).and_return(false)
      allow(instance).to receive(:tts_queue_position).and_return(7)
    end

    it 'returns queue statistics' do
      result = service.queue_stats

      expect(result[:total]).to eq(10)
      expect(result[:pending]).to eq(3)
      expect(result[:played]).to eq(7)
      expect(result[:paused]).to be false
      expect(result[:position]).to eq(7)
    end
  end

  describe 'private methods' do
    describe 'should_queue?' do
      context 'when character_instance is nil' do
        let(:nil_service) { described_class.new(nil) }

        it 'returns false' do
          expect(nil_service.send(:should_queue?)).to be false
        end
      end
    end

    describe 'extract_character' do
      it 'returns character for Character object' do
        char = create(:character)
        result = service.send(:extract_character, char)
        expect(result).to eq(char)
      end

      it 'returns character for CharacterInstance object' do
        result = service.send(:extract_character, instance)
        expect(result).to eq(character)
      end

      it 'returns nil for other objects' do
        result = service.send(:extract_character, 'string')
        expect(result).to be_nil
      end
    end

    describe 'estimate_duration' do
      it 'estimates duration based on word count and speed' do
        # 10 words at 1.0x speed
        text = 'one two three four five six seven eight nine ten'
        duration = service.send(:estimate_duration, text, 1.0)

        # 10 words / 2.5 words per second = 4 seconds
        expect(duration).to eq(4.0)
      end

      it 'adjusts for speed multiplier' do
        text = 'one two three four five six seven eight nine ten'
        duration = service.send(:estimate_duration, text, 2.0)

        # 10 words / 2.5 words per second / 2.0 speed = 2 seconds
        expect(duration).to eq(2.0)
      end
    end

    describe 'narrator_voice_settings' do
      context 'when user exists' do
        before do
          allow(user).to receive(:narrator_settings).and_return({
            voice_type: 'custom-voice',
            voice_pitch: 0.5,
            voice_speed: 1.2
          })
        end

        it 'returns user narrator settings' do
          result = service.send(:narrator_voice_settings)

          expect(result[:voice_type]).to eq('custom-voice')
          expect(result[:voice_pitch]).to eq(0.5)
          expect(result[:voice_speed]).to eq(1.2)
        end
      end

      context 'when user is nil' do
        before do
          allow(instance).to receive(:character).and_return(nil)
        end

        it 'returns default settings' do
          result = service.send(:narrator_voice_settings)

          expect(result[:voice_type]).to eq(TtsService::DEFAULT_VOICE)
          expect(result[:voice_pitch]).to eq(0.0)
          expect(result[:voice_speed]).to eq(1.0)
        end
      end
    end
  end
end
