# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::System::Reroll do
  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['reroll']).to eq(described_class)
    end

    it 'has alias newchar' do
      cmd_class, _ = Commands::Base::Registry.find_command('newchar')
      expect(cmd_class).to eq(described_class)
    end

    # Note: 'new character' alias is a multi-word alias
    it 'has alias new character' do
      cmd_class, _ = Commands::Base::Registry.find_command('new character')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('reroll')
    end

    it 'has category system' do
      expect(described_class.category).to eq(:system)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('new character')
    end

    it 'has usage' do
      expect(described_class.usage).to include('reroll')
    end

    it 'has examples' do
      expect(described_class.examples).to include('reroll')
    end
  end
end
