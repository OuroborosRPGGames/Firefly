# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::Unpuppet do
  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['unpuppet']).to eq(described_class)
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('unpuppet')
    end

    it 'has category staff' do
      expect(described_class.category).to eq(:staff)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('Release')
    end

    it 'has usage' do
      expect(described_class.usage).to include('unpuppet')
    end
  end
end
