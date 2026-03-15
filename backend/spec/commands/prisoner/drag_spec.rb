# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Prisoner::Drag do
  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['drag']).to eq(described_class)
    end

    it 'has alias haul' do
      cmd_class, _ = Commands::Base::Registry.find_command('haul')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('drag')
    end

    it 'has category combat' do
      expect(described_class.category).to eq(:combat)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('Drag')
    end

    it 'has usage' do
      expect(described_class.usage).to include('drag')
    end

    it 'has examples' do
      expect(described_class.examples).to include('drag Bob')
    end
  end
end
