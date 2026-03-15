# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::CancelScene do
  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['cancelscene']).to eq(described_class)
    end

    it 'has alias deletescene' do
      cmd_class, _ = Commands::Base::Registry.find_command('deletescene')
      expect(cmd_class).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('cancelscene')
    end

    it 'has category staff' do
      expect(described_class.category).to eq(:staff)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('Cancel')
    end

    it 'has usage' do
      expect(described_class.usage).to include('cancelscene')
    end

    it 'has examples' do
      expect(described_class.examples).to include('cancelscene 5')
    end
  end
end
