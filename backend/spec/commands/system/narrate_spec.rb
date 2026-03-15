# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::System::Narrate, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true,
           tts_enabled: false,
           tts_paused: false,
           tts_queue_position: 0)
  end

  subject(:command) { described_class.new(character_instance) }

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'narrate', :system, %w[tts voice]

  describe '#execute' do
    before do
      # Default: TTS is available
      allow(TtsService).to receive(:available?).and_return(true)
    end

    context 'with no arguments (toggle)' do
      it 'toggles TTS from off to on' do
        result = command.execute('narrate')

        expect(result[:success]).to be true
        expect(result[:message]).to include('ON')
        expect(character_instance.reload.tts_enabled?).to be true
      end

      it 'toggles TTS from on to off' do
        character_instance.update(tts_enabled: true)
        result = command.execute('narrate')

        expect(result[:success]).to be true
        expect(result[:message]).to include('OFF')
        expect(character_instance.reload.tts_enabled?).to be false
      end

      it 'returns error when TTS service is unavailable' do
        allow(TtsService).to receive(:available?).and_return(false)

        result = command.execute('narrate')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not currently available')
      end
    end

    context 'with "on" subcommand' do
      it 'enables TTS narration' do
        result = command.execute('narrate on')

        expect(result[:success]).to be true
        expect(result[:message]).to include('ON')
        expect(result[:data][:tts_enabled]).to be true
        expect(character_instance.reload.tts_enabled?).to be true
      end

      it 'works with "enable" alias' do
        result = command.execute('narrate enable')

        expect(result[:success]).to be true
        expect(result[:data][:tts_enabled]).to be true
      end

      it 'returns error when TTS service is unavailable' do
        allow(TtsService).to receive(:available?).and_return(false)

        result = command.execute('narrate on')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not currently available')
      end
    end

    context 'with "off" subcommand' do
      before { character_instance.update(tts_enabled: true) }

      it 'disables TTS narration' do
        result = command.execute('narrate off')

        expect(result[:success]).to be true
        expect(result[:message]).to include('OFF')
        expect(result[:data][:tts_enabled]).to be false
        expect(character_instance.reload.tts_enabled?).to be false
      end

      it 'works with "disable" alias' do
        result = command.execute('narrate disable')

        expect(result[:success]).to be true
        expect(result[:data][:tts_enabled]).to be false
      end
    end

    context 'with "status" subcommand' do
      it 'shows TTS status when disabled' do
        result = command.execute('narrate status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('TTS Narration: OFF')
        expect(result[:data]).to have_key(:tts_settings)
        expect(result[:data]).to have_key(:available)
      end

      it 'shows TTS status when enabled' do
        character_instance.update(tts_enabled: true)

        result = command.execute('narrate status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('TTS Narration: ON')
      end

      it 'shows content settings' do
        result = command.execute('narrate status')

        expect(result[:message]).to include('Content Settings:')
        expect(result[:message]).to include('Speech')
        expect(result[:message]).to include('Actions')
        expect(result[:message]).to include('Room descriptions')
        expect(result[:message]).to include('System messages')
      end

      it 'shows character voice settings' do
        result = command.execute('narrate status')

        expect(result[:message]).to include('Your Character Voice:')
      end

      it 'shows narrator voice settings when user exists' do
        result = command.execute('narrate status')

        expect(result[:message]).to include('Your Narrator Voice:')
      end

      it 'shows TTS service availability' do
        result = command.execute('narrate status')

        expect(result[:message]).to include('TTS Service: Available')
      end

      it 'shows unavailable when service is down' do
        allow(TtsService).to receive(:available?).and_return(false)

        result = command.execute('narrate status')

        expect(result[:message]).to include('TTS Service: Not Available')
      end
    end

    context 'with "config" subcommand' do
      it 'shows config help when no setting provided' do
        result = command.execute('narrate config')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Configure what content types')
        expect(result[:message]).to include('narrate config speech')
      end

      it 'configures speech setting to off' do
        result = command.execute('narrate config speech off')

        expect(result[:success]).to be true
        expect(result[:message]).to include('TTS speech narration is now OFF')
        expect(result[:data][:setting]).to eq('speech')
        expect(result[:data][:enabled]).to be false
      end

      it 'configures speech setting to on' do
        character_instance.update(tts_narrate_speech: false)

        result = command.execute('narrate config speech on')

        expect(result[:success]).to be true
        expect(result[:message]).to include('TTS speech narration is now ON')
        expect(result[:data][:enabled]).to be true
      end

      it 'configures actions setting' do
        result = command.execute('narrate config actions off')

        expect(result[:success]).to be true
        expect(result[:message]).to include('TTS actions narration is now OFF')
      end

      it 'configures rooms setting' do
        result = command.execute('narrate config rooms off')

        expect(result[:success]).to be true
        expect(result[:message]).to include('TTS rooms narration is now OFF')
      end

      it 'configures system setting' do
        result = command.execute('narrate config system off')

        expect(result[:success]).to be true
        expect(result[:message]).to include('TTS system narration is now OFF')
      end

      it 'accepts true/false values' do
        result = command.execute('narrate config speech true')

        expect(result[:success]).to be true
        expect(result[:data][:enabled]).to be true
      end

      it 'accepts 1/0 values' do
        result = command.execute('narrate config speech 0')

        expect(result[:success]).to be true
        expect(result[:data][:enabled]).to be false
      end

      it 'returns error for invalid setting' do
        result = command.execute('narrate config invalid on')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid setting')
        expect(result[:error]).to include('speech, actions, rooms, system')
      end

      it 'returns error for invalid value' do
        result = command.execute('narrate config speech maybe')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid value')
        expect(result[:error]).to include("'on' or 'off'")
      end
    end

    context 'with "pause" subcommand' do
      before { character_instance.update(tts_enabled: true) }

      it 'pauses TTS narration' do
        result = command.execute('narrate pause')

        expect(result[:success]).to be true
        expect(result[:message]).to include('paused')
        expect(result[:data][:tts_paused]).to be true
        expect(result[:data][:action]).to eq(:pause)
        expect(character_instance.reload.tts_paused?).to be true
      end

      it 'works with "stop" alias' do
        result = command.execute('narrate stop')

        expect(result[:success]).to be true
        expect(result[:data][:action]).to eq(:pause)
      end

      it 'returns error when TTS is not enabled' do
        character_instance.update(tts_enabled: false)

        result = command.execute('narrate pause')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not enabled')
      end

      it 'returns message when already paused' do
        character_instance.update(tts_paused: true)

        result = command.execute('narrate pause')

        expect(result[:success]).to be true
        expect(result[:message]).to include('already paused')
      end
    end

    context 'with "resume" subcommand' do
      before { character_instance.update(tts_enabled: true, tts_paused: true) }

      it 'resumes TTS narration' do
        result = command.execute('narrate resume')

        expect(result[:success]).to be true
        expect(result[:message]).to include('resumed')
        expect(result[:data][:tts_paused]).to be false
        expect(result[:data][:action]).to eq(:resume)
        expect(character_instance.reload.tts_paused?).to be false
      end

      it 'works with "play" alias' do
        result = command.execute('narrate play')

        expect(result[:success]).to be true
        expect(result[:data][:action]).to eq(:resume)
      end

      it 'works with "continue" alias' do
        result = command.execute('narrate continue')

        expect(result[:success]).to be true
        expect(result[:data][:action]).to eq(:resume)
      end

      it 'returns error when TTS is not enabled' do
        character_instance.update(tts_enabled: false)

        result = command.execute('narrate resume')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not enabled')
      end

      it 'returns message when not paused' do
        character_instance.update(tts_paused: false)

        result = command.execute('narrate resume')

        expect(result[:success]).to be true
        expect(result[:message]).to include('already playing')
      end

      it 'shows pending item count' do
        character_instance.update(tts_paused: true)
        # Mock pending items
        allow(character_instance).to receive(:pending_audio_items)
          .and_return(double(count: 5))

        result = command.execute('narrate resume')

        expect(result[:success]).to be true
        expect(result[:data][:pending_count]).to eq(5)
      end
    end

    context 'with "skip" subcommand' do
      before { character_instance.update(tts_enabled: true) }

      it 'skips forward with positive amount' do
        result = command.execute('narrate skip +15')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Skipping forward 15 seconds')
        expect(result[:data][:skip_seconds]).to eq(15)
        expect(result[:data][:direction]).to eq('forward')
        expect(result[:data][:action]).to eq(:skip)
      end

      it 'skips backward with negative amount' do
        result = command.execute('narrate skip -15')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Skipping backward 15 seconds')
        expect(result[:data][:skip_seconds]).to eq(-15)
        expect(result[:data][:direction]).to eq('backward')
      end

      it 'accepts plain number' do
        result = command.execute('narrate skip 30')

        expect(result[:success]).to be true
        expect(result[:data][:skip_seconds]).to eq(30)
      end

      it 'accepts amount with s suffix' do
        result = command.execute('narrate skip +10s')

        expect(result[:success]).to be true
        expect(result[:data][:skip_seconds]).to eq(10)
      end

      it 'returns error when TTS is not enabled' do
        character_instance.update(tts_enabled: false)

        result = command.execute('narrate skip +15')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not enabled')
      end

      it 'returns error when no amount specified' do
        result = command.execute('narrate skip')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Specify skip amount')
      end

      it 'returns error for invalid amount' do
        result = command.execute('narrate skip abc')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid skip amount')
      end
    end

    context 'with "current" subcommand' do
      before { character_instance.update(tts_enabled: true, tts_queue_position: 5) }

      it 'skips to latest content' do
        result = command.execute('narrate current')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Skipped to latest')
        expect(result[:data][:action]).to eq(:skip_to_current)
      end

      it 'works with "latest" alias' do
        result = command.execute('narrate latest')

        expect(result[:success]).to be true
        expect(result[:data][:action]).to eq(:skip_to_current)
      end

      it 'works with "now" alias' do
        result = command.execute('narrate now')

        expect(result[:success]).to be true
        expect(result[:data][:action]).to eq(:skip_to_current)
      end

      it 'returns error when TTS is not enabled' do
        character_instance.update(tts_enabled: false)

        result = command.execute('narrate current')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not enabled')
      end
    end

    context 'with "clear" subcommand' do
      before { character_instance.update(tts_enabled: true) }

      it 'clears the queue' do
        # Mock the dataset delete
        dataset = double
        allow(dataset).to receive(:where).with(played: false).and_return(dataset)
        allow(dataset).to receive(:delete).and_return(3)
        allow(character_instance).to receive(:audio_queue_items_dataset).and_return(dataset)
        allow(character_instance).to receive(:skip_to_latest!)

        result = command.execute('narrate clear')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Cleared 3 items')
        expect(result[:data][:cleared_count]).to eq(3)
        expect(result[:data][:action]).to eq(:clear_queue)
      end

      it 'returns error when TTS is not enabled' do
        character_instance.update(tts_enabled: false)

        result = command.execute('narrate clear')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not enabled')
      end
    end

    context 'with "queue" subcommand' do
      before { character_instance.update(tts_enabled: true, tts_queue_position: 5) }

      it 'shows queue status when empty' do
        # Mock empty pending items
        allow(character_instance).to receive(:pending_audio_items)
          .and_return(double(all: [], count: 0))

        result = command.execute('narrate queue')

        expect(result[:success]).to be true
        expect(result[:message]).to include('TTS Queue Status')
        expect(result[:message]).to include('Pending Items: 0')
        expect(result[:data][:pending_count]).to eq(0)
      end

      it 'shows queue with items' do
        # Create a mock object that responds to truncate (since truncate is from ActiveSupport)
        mock_text = double('text', truncate: 'Hello world')

        item = double(
          sequence_number: 1,
          content_type: 'speech',
          original_text: mock_text,
          to_api_hash: { id: 1 }
        )

        dataset = double(all: [item], count: 1)
        allow(dataset).to receive(:first).with(5).and_return([item])
        allow(character_instance).to receive(:pending_audio_items).and_return(dataset)

        result = command.execute('narrate queue')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Pending Items: 1')
        expect(result[:message]).to include('Next items:')
      end

      it 'shows paused state' do
        character_instance.update(tts_paused: true)
        allow(character_instance).to receive(:pending_audio_items)
          .and_return(double(all: [], count: 0))

        result = command.execute('narrate queue')

        expect(result[:message]).to include('State: PAUSED')
        expect(result[:data][:paused]).to be true
      end

      it 'shows playing state' do
        allow(character_instance).to receive(:pending_audio_items)
          .and_return(double(all: [], count: 0))

        result = command.execute('narrate queue')

        expect(result[:message]).to include('State: PLAYING')
        expect(result[:data][:paused]).to be false
      end

      it 'returns error when TTS is not enabled' do
        character_instance.update(tts_enabled: false)

        result = command.execute('narrate queue')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not enabled')
      end
    end

    context 'with unrecognized subcommand' do
      it 'treats as toggle (default behavior)' do
        result = command.execute('narrate toggle')

        expect(result[:success]).to be true
        # Should toggle since 'toggle' is not a recognized subcommand
      end
    end
  end

  describe 'command aliases' do
    it 'works with tts alias' do
      allow(TtsService).to receive(:available?).and_return(true)
      result = command.execute('tts on')

      expect(result[:success]).to be true
    end

    it 'works with voice alias' do
      allow(TtsService).to receive(:available?).and_return(true)
      result = command.execute('voice on')

      expect(result[:success]).to be true
    end
  end

  describe '#parse_skip_amount' do
    it 'parses positive number with plus sign' do
      expect(command.send(:parse_skip_amount, '+15')).to eq(15)
    end

    it 'parses negative number' do
      expect(command.send(:parse_skip_amount, '-15')).to eq(-15)
    end

    it 'parses plain number' do
      expect(command.send(:parse_skip_amount, '30')).to eq(30)
    end

    it 'strips s suffix' do
      expect(command.send(:parse_skip_amount, '+10s')).to eq(10)
    end

    it 'returns nil for non-numeric' do
      expect(command.send(:parse_skip_amount, 'abc')).to be_nil
    end

    it 'returns nil for nil input' do
      expect(command.send(:parse_skip_amount, nil)).to be_nil
    end
  end
end
