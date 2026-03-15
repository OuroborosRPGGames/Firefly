# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::System::Accessibility, type: :command do
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Test', user: user) }
  let(:character_instance) { create(:character_instance, character: character, stance: 'standing') }

  describe 'command metadata' do
    it 'has correct name' do
      expect(described_class.command_name).to eq('accessibility')
    end

    it 'has correct aliases' do
      expect(described_class.alias_names).to include('a11y')
      expect(described_class.alias_names).to include('access')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:system)
    end
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    describe 'default (shows form)' do
      it 'shows accessibility form' do
        result = command.execute('accessibility')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:form)
        expect(result[:data][:title]).to eq('Accessibility Settings')
      end
    end

    describe 'status subcommand' do
      it 'shows current settings' do
        result = command.execute('accessibility status')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Accessibility Mode')
      end
    end

    describe 'mode on/off' do
      it 'enables accessibility mode' do
        result = command.execute('accessibility mode on')
        expect(result[:success]).to be true
        expect(result[:message]).to include('ON')
        expect(user.reload.accessibility_mode?).to be true
      end

      it 'disables accessibility mode' do
        user.configure_accessibility!(mode: true)
        result = command.execute('accessibility mode off')
        expect(result[:success]).to be true
        expect(result[:message]).to include('OFF')
        expect(user.reload.accessibility_mode?).to be false
      end

      it 'shows current mode status when no value given' do
        result = command.execute('accessibility mode')
        expect(result[:success]).to be true
        expect(result[:message]).to include('currently')
      end
    end

    describe 'reader on/off' do
      it 'enables screen reader optimization' do
        result = command.execute('accessibility reader on')
        expect(result[:success]).to be true
        expect(result[:message]).to include('ON')
        expect(user.reload.screen_reader_mode?).to be true
      end

      it 'disables screen reader optimization' do
        user.configure_accessibility!(screen_reader: true)
        result = command.execute('accessibility reader off')
        expect(result[:success]).to be true
        expect(result[:message]).to include('OFF')
      end
    end

    describe 'contrast on/off' do
      it 'enables high contrast mode' do
        result = command.execute('accessibility contrast on')
        expect(result[:success]).to be true
        expect(result[:message]).to include('ON')
        expect(user.reload.high_contrast_mode).to be true
      end

      it 'disables high contrast mode' do
        user.configure_accessibility!(high_contrast: true)
        result = command.execute('accessibility contrast off')
        expect(result[:success]).to be true
        expect(result[:message]).to include('OFF')
        expect(user.reload.high_contrast_mode).to be false
      end
    end

    describe 'effects on/off' do
      it 'enables full visual effects' do
        user.configure_accessibility!(reduced_effects: true)
        result = command.execute('accessibility effects on')
        expect(result[:success]).to be true
        expect(result[:message]).to include('full')
        expect(user.reload.reduced_visual_effects).to be false
      end

      it 'reduces visual effects' do
        result = command.execute('accessibility effects off')
        expect(result[:success]).to be true
        expect(result[:message]).to include('reduced')
        expect(user.reload.reduced_visual_effects).to be true
      end
    end

    describe 'typing pause on/off' do
      it 'enables TTS pause on typing' do
        user.configure_accessibility!(pause_on_typing: false)
        result = command.execute('accessibility typing on')
        expect(result[:success]).to be true
        expect(result[:message]).to include('ON')
        expect(user.reload.tts_pause_on_typing?).to be true
      end

      it 'disables TTS pause on typing' do
        result = command.execute('accessibility typing off')
        expect(result[:success]).to be true
        expect(result[:message]).to include('OFF')
        expect(user.reload.tts_pause_on_typing?).to be false
      end
    end

    describe 'auto resume on/off' do
      it 'enables TTS auto-resume' do
        user.configure_accessibility!(auto_resume: false)
        result = command.execute('accessibility resume on')
        expect(result[:success]).to be true
        expect(result[:message]).to include('ON')
        expect(user.reload.tts_auto_resume?).to be true
      end

      it 'disables TTS auto-resume' do
        result = command.execute('accessibility resume off')
        expect(result[:success]).to be true
        expect(result[:message]).to include('OFF')
        expect(user.reload.tts_auto_resume?).to be false
      end
    end

    describe 'speed' do
      it 'sets TTS speed' do
        result = command.execute('accessibility speed 1.5')
        expect(result[:success]).to be true
        expect(result[:message]).to include('1.5x')
        expect(user.reload.narrator_settings[:voice_speed]).to eq(1.5)
      end

      it 'rejects invalid speed' do
        result = command.execute('accessibility speed 10')
        expect(result[:success]).to be false
        expect(result[:message]).to include('between')
      end

      it 'shows current speed when no value given' do
        result = command.execute('accessibility speed')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Current TTS speed')
      end
    end

    describe 'help' do
      it 'shows help text' do
        result = command.execute('accessibility help')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Accessibility Commands')
        expect(result[:message]).to include('mode on/off')
        expect(result[:message]).to include('contrast on/off')
      end
    end

    describe 'keys subcommand' do
      it 'shows current key bindings' do
        result = command.execute('accessibility keys')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Replay Buffer Key Bindings')
        expect(result[:message]).to include('Alt+ArrowUp')
        expect(result[:message]).to include('Alt+ArrowDown')
      end

      it 'shows help for setting keys' do
        result = command.execute('accessibility keys')
        expect(result[:message]).to include('webclient settings panel')
      end
    end

    describe 'unknown setting' do
      it 'returns an error' do
        result = command.execute('accessibility unknown on')
        expect(result[:success]).to be false
        expect(result[:message]).to include('Unknown setting')
        expect(result[:message]).to include('unknown')
      end
    end
  end
end
