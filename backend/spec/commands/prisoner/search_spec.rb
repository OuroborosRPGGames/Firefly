# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Prisoner::Search do
  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['search']).to eq(described_class)
    end

    it 'has alias frisk' do
      cmd_class, _ = Commands::Base::Registry.find_command('frisk')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias rob' do
      cmd_class, _ = Commands::Base::Registry.find_command('rob')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('search')
    end

    it 'has category combat' do
      expect(described_class.category).to eq(:combat)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('Search')
    end

    it 'has usage' do
      expect(described_class.usage).to include('search')
    end

    it 'has examples' do
      expect(described_class.examples).to include('search Bob')
    end
  end
end
