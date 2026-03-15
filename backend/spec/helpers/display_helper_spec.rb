# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DisplayHelper do
  describe 'module structure' do
    it 'is a module' do
      expect(described_class).to be_a(Module)
    end

    it 'uses module_function pattern' do
      expect(described_class).to respond_to(:display_name)
      expect(described_class).to respond_to(:character_display_name)
      expect(described_class).to respond_to(:participant_display_name)
    end
  end

  describe '.display_name' do
    it 'returns nil for nil input' do
      expect(described_class.display_name(nil)).to be_nil
    end

    it 'returns full_name when object responds to it' do
      obj = double(full_name: 'Full Name')
      allow(obj).to receive(:respond_to?).with(:full_name).and_return(true)
      expect(described_class.display_name(obj)).to eq('Full Name')
    end

    it 'returns name when object does not respond to full_name' do
      obj = double(name: 'Just Name')
      allow(obj).to receive(:respond_to?).with(:full_name).and_return(false)
      expect(described_class.display_name(obj)).to eq('Just Name')
    end
  end

  describe '.character_display_name' do
    it 'returns nil for nil character_instance' do
      expect(described_class.character_display_name(nil)).to be_nil
    end

    it 'returns character full_name through character_instance' do
      character = double(full_name: 'Character Full Name')
      allow(character).to receive(:respond_to?).with(:full_name).and_return(true)
      character_instance = double(character: character)
      expect(described_class.character_display_name(character_instance)).to eq('Character Full Name')
    end
  end

  describe '.participant_display_name' do
    it 'returns nil for nil participant' do
      expect(described_class.participant_display_name(nil)).to be_nil
    end

    it 'returns character full_name through participant.character_instance.character' do
      character = double(full_name: 'Participant Character')
      allow(character).to receive(:respond_to?).with(:full_name).and_return(true)
      character_instance = double(character: character)
      participant = double(character_instance: character_instance)
      expect(described_class.participant_display_name(participant)).to eq('Participant Character')
    end

    it 'returns nil when participant has nil character_instance' do
      participant = double(character_instance: nil)
      expect(described_class.participant_display_name(participant)).to be_nil
    end
  end

  describe 'usage as instance method' do
    let(:test_class) do
      Class.new do
        include DisplayHelper

        # module_function makes methods private when included
        # Make them public for usage
        public :display_name, :character_display_name, :participant_display_name
      end
    end

    let(:instance) { test_class.new }

    it 'can be called as instance method' do
      obj = double(full_name: 'Test Name')
      allow(obj).to receive(:respond_to?).with(:full_name).and_return(true)
      expect(instance.display_name(obj)).to eq('Test Name')
    end
  end
end
