# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TtsService do
  describe '.available_voices' do
    it 'returns a hash with male and female voices' do
      voices = described_class.available_voices
      expect(voices).to be_a(Hash)
      expect(voices.keys).to contain_exactly(:female, :male)
    end

    it 'includes female voices' do
      voices = described_class.available_voices[:female]
      expect(voices.keys).to include('Kore', 'Zephyr', 'Aoede')
    end

    it 'includes male voices' do
      voices = described_class.available_voices[:male]
      expect(voices.keys).to include('Charon', 'Fenrir', 'Puck')
    end
  end

  describe '.voice_names' do
    it 'returns a flat array of all voice names' do
      names = described_class.voice_names
      expect(names).to be_an(Array)
      expect(names).to include('Kore', 'Charon', 'Zephyr', 'Fenrir')
    end

    it 'returns 30 voices total' do
      # 14 female + 16 male
      names = described_class.voice_names
      expect(names.length).to eq(30)
    end
  end

  describe '.valid_voice?' do
    it 'returns true for valid female voice' do
      expect(described_class.valid_voice?('Kore')).to be true
    end

    it 'returns true for valid male voice' do
      expect(described_class.valid_voice?('Charon')).to be true
    end

    it 'returns false for invalid voice' do
      expect(described_class.valid_voice?('InvalidVoice')).to be false
    end

    it 'returns false for nil' do
      expect(described_class.valid_voice?(nil)).to be false
    end

    it 'returns false for empty string' do
      expect(described_class.valid_voice?('')).to be false
    end
  end

  describe '.voice_info' do
    it 'returns voice info for valid female voice' do
      info = described_class.voice_info('Kore')
      expect(info).to be_a(Hash)
      expect(info[:name]).to eq('Kore')
      expect(info[:gender]).to eq(:female)
      expect(info[:description]).to be_a(String)
      expect(info[:locale]).to eq('en-US')
    end

    it 'returns voice info for valid male voice' do
      info = described_class.voice_info('Charon')
      expect(info).to be_a(Hash)
      expect(info[:name]).to eq('Charon')
      expect(info[:gender]).to eq(:male)
      expect(info[:description]).to include('Deep')
    end

    it 'returns nil for invalid voice' do
      info = described_class.voice_info('InvalidVoice')
      expect(info).to be_nil
    end
  end

  describe '.voices_by_gender' do
    it 'returns female voices' do
      voices = described_class.voices_by_gender(:female)
      expect(voices).to be_a(Hash)
      expect(voices.keys).to include('Kore', 'Zephyr')
      expect(voices.keys).not_to include('Charon')
    end

    it 'returns male voices' do
      voices = described_class.voices_by_gender(:male)
      expect(voices).to be_a(Hash)
      expect(voices.keys).to include('Charon', 'Fenrir')
      expect(voices.keys).not_to include('Kore')
    end

    it 'returns empty hash for invalid gender' do
      voices = described_class.voices_by_gender(:other)
      expect(voices).to eq({})
    end
  end

  describe '.available?' do
    it 'returns boolean' do
      result = described_class.available?
      expect([true, false]).to include(result)
    end
  end

  describe '.synthesize' do
    before do
      # Mock availability
      allow(described_class).to receive(:available?).and_return(false)
    end

    context 'when TTS not available' do
      it 'returns error' do
        result = described_class.synthesize('Test text')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/not available/i)
      end
    end

    context 'with nil text' do
      before do
        allow(described_class).to receive(:available?).and_return(true)
      end

      it 'returns error' do
        result = described_class.synthesize(nil)
        expect(result[:success]).to be false
        expect(result[:error]).to match(/required/i)
      end
    end

    context 'with empty text' do
      before do
        allow(described_class).to receive(:available?).and_return(true)
      end

      it 'returns error' do
        result = described_class.synthesize('')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/required/i)
      end

      it 'returns error for whitespace-only text' do
        result = described_class.synthesize('   ')
        expect(result[:success]).to be false
        expect(result[:error]).to match(/required/i)
      end
    end

    context 'with text too long' do
      before do
        allow(described_class).to receive(:available?).and_return(true)
      end

      it 'returns error' do
        long_text = 'a' * (TtsService::MAX_TEXT_LENGTH + 1)
        result = described_class.synthesize(long_text)
        expect(result[:success]).to be false
        expect(result[:error]).to match(/too long/i)
      end
    end
  end

  describe '.generate_preview' do
    before do
      allow(described_class).to receive(:synthesize).and_return({ success: true, data: { filename: 'test' } })
    end

    it 'calls synthesize with sample text' do
      described_class.generate_preview('Kore')
      expect(described_class).to have_received(:synthesize).with(
        anything,
        hash_including(voice_type: 'Kore', locale: 'en-US')
      )
    end

    it 'uses provided locale' do
      described_class.generate_preview('Charon', locale: 'en-GB')
      expect(described_class).to have_received(:synthesize).with(
        anything,
        hash_including(locale: 'en-GB')
      )
    end
  end

  describe '.cleanup_old_files' do
    context 'when audio directory does not exist' do
      before do
        allow(Dir).to receive(:exist?).with(TtsService.audio_dir).and_return(false)
      end

      it 'returns 0' do
        result = described_class.cleanup_old_files
        expect(result).to eq(0)
      end
    end

    context 'when audio directory exists' do
      before do
        allow(Dir).to receive(:exist?).with(TtsService.audio_dir).and_return(true)
        allow(Dir).to receive(:glob).and_return([])
      end

      it 'returns deleted count' do
        result = described_class.cleanup_old_files
        expect(result).to eq(0)
      end
    end
  end

  describe 'constants' do
    it 'defines audio_dir' do
      expect(TtsService.audio_dir).to be_a(String)
    end

    it 'defines AUDIO_CLEANUP_MINUTES' do
      expect(TtsService::AUDIO_CLEANUP_MINUTES).to be_an(Integer)
    end

    it 'defines MAX_TEXT_LENGTH' do
      expect(TtsService::MAX_TEXT_LENGTH).to be_an(Integer)
      expect(TtsService::MAX_TEXT_LENGTH).to be > 0
    end

    it 'defines DEFAULT_VOICE' do
      expect(TtsService::DEFAULT_VOICE).to be_a(String)
      expect(described_class.valid_voice?(TtsService::DEFAULT_VOICE)).to be true
    end

    it 'defines DEFAULT_LOCALE' do
      expect(TtsService::DEFAULT_LOCALE).to eq('en-US')
    end

    it 'defines CHIRP3_HD_VOICES' do
      expect(TtsService::CHIRP3_HD_VOICES).to be_a(Hash)
      expect(TtsService::CHIRP3_HD_VOICES.keys).to contain_exactly(:female, :male)
    end
  end

  describe 'voice descriptions' do
    it 'all female voices have descriptions' do
      TtsService::CHIRP3_HD_VOICES[:female].each do |name, info|
        expect(info[:description]).to be_a(String), "#{name} missing description"
        expect(info[:description]).not_to be_empty, "#{name} has empty description"
      end
    end

    it 'all male voices have descriptions' do
      TtsService::CHIRP3_HD_VOICES[:male].each do |name, info|
        expect(info[:description]).to be_a(String), "#{name} missing description"
        expect(info[:description]).not_to be_empty, "#{name} has empty description"
      end
    end

    it 'all voices have locales' do
      TtsService::CHIRP3_HD_VOICES.each do |_gender, voices|
        voices.each do |name, info|
          expect(info[:locale]).to be_a(String), "#{name} missing locale"
        end
      end
    end
  end
end
