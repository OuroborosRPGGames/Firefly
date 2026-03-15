# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Prisoner::DropPrisoner do
  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['release']).to eq(described_class)
    end

    it 'has alias letgo' do
      cmd_class, _ = Commands::Base::Registry.find_command('letgo')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias putdown' do
      cmd_class, _ = Commands::Base::Registry.find_command('putdown')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('release')
    end

    it 'has category combat' do
      expect(described_class.category).to eq(:combat)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('Release')
    end

    it 'has usage' do
      expect(described_class.usage).to include('release')
    end

    it 'has examples' do
      expect(described_class.examples).to include('release')
    end
  end
end
