# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Oocrequest do
  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['oocrequest']).to eq(described_class)
    end

    it 'has alias oocreq' do
      cmd_class, _ = Commands::Base::Registry.find_command('oocreq')
      expect(cmd_class).to eq(described_class)
    end

    it 'has alias reqooc' do
      cmd_class, _ = Commands::Base::Registry.find_command('reqooc')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('oocrequest')
    end

    it 'has category communication' do
      expect(described_class.category).to eq(:communication)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('OOC')
    end

    it 'has usage' do
      expect(described_class.usage).to include('oocrequest')
    end

    it 'has examples' do
      expect(described_class.examples).to include('oocrequest Bob Hi, would you like to discuss the plot?')
    end
  end
end
