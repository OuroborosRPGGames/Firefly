# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Prisoner::Carry do
  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['carry']).to eq(described_class)
    end

    it 'has alias pickup' do
      cmd_class, _ = Commands::Base::Registry.find_command('pickup')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias lift' do
      cmd_class, _ = Commands::Base::Registry.find_command('lift')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('carry')
    end

    it 'has category combat' do
      expect(described_class.category).to eq(:combat)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('carry')
    end

    it 'has usage' do
      expect(described_class.usage).to include('carry')
    end

    it 'has examples' do
      expect(described_class.examples).to include('carry Bob')
    end
  end
end
