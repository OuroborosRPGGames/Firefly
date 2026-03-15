# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Prisoner::Gag do
  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['gag']).to eq(described_class)
    end

    it 'has alias muzzle' do
      cmd_class, _ = Commands::Base::Registry.find_command('muzzle')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('gag')
    end

    it 'has category combat' do
      expect(described_class.category).to eq(:combat)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('Gag')
    end

    it 'has usage' do
      expect(described_class.usage).to include('gag')
    end

    it 'has examples' do
      expect(described_class.examples).to include('gag Bob')
    end
  end
end
