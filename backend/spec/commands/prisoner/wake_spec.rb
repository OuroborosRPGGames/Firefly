# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Prisoner::Wake do
  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['wake']).to eq(described_class)
    end

    it 'has alias rouse' do
      cmd_class, _ = Commands::Base::Registry.find_command('rouse')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias awaken' do
      cmd_class, _ = Commands::Base::Registry.find_command('awaken')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('wake')
    end

    it 'has category combat' do
      expect(described_class.category).to eq(:combat)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('Wake')
    end

    it 'has usage' do
      expect(described_class.usage).to include('wake')
    end

    it 'has examples' do
      expect(described_class.examples).to include('wake Bob')
    end
  end
end
