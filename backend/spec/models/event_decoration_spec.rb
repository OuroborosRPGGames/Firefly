# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EventDecoration do
  describe 'associations' do
    it 'belongs to event' do
      expect(described_class.association_reflections[:event]).not_to be_nil
    end

    it 'belongs to room' do
      expect(described_class.association_reflections[:room]).not_to be_nil
    end

    it 'belongs to created_by' do
      expect(described_class.association_reflections[:created_by]).not_to be_nil
    end
  end

  describe 'instance methods' do
    it 'defines display_text' do
      expect(described_class.instance_methods).to include(:display_text)
    end
  end

  describe 'class methods' do
    it 'defines for_event_room' do
      expect(described_class).to respond_to(:for_event_room)
    end

    it 'defines for_event' do
      expect(described_class).to respond_to(:for_event)
    end

    it 'defines add_to_event' do
      expect(described_class).to respond_to(:add_to_event)
    end

    it 'defines cleanup_event!' do
      expect(described_class).to respond_to(:cleanup_event!)
    end
  end

  describe '#display_text behavior' do
    it 'returns name when description is empty' do
      dec = described_class.new
      dec.values[:name] = 'Test Decoration'
      dec.values[:description] = nil
      expect(dec.display_text).to eq('Test Decoration')
    end

    it 'returns name and description when description is present' do
      dec = described_class.new
      dec.values[:name] = 'Test Decoration'
      dec.values[:description] = 'A shiny thing'
      expect(dec.display_text).to eq('Test Decoration - A shiny thing')
    end
  end
end
