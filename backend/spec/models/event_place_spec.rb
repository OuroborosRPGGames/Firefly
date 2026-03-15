# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EventPlace do
  describe 'constants' do
    it 'defines PLACE_TYPES' do
      expect(described_class::PLACE_TYPES).to eq(%w[furniture seating stage bar table booth lounge other])
    end
  end

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
    it 'defines at_capacity?' do
      expect(described_class.instance_methods).to include(:at_capacity?)
    end

    it 'defines sit_action' do
      expect(described_class.instance_methods).to include(:sit_action)
    end

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

  describe '#sit_action behavior' do
    it 'returns default_sit_action when set' do
      place = described_class.new
      place.values[:default_sit_action] = 'lounges on'
      expect(place.sit_action).to eq('lounges on')
    end

    it 'returns "sits at" when default_sit_action is empty' do
      place = described_class.new
      place.values[:default_sit_action] = nil
      expect(place.sit_action).to eq('sits at')
    end
  end

  describe '#display_text behavior' do
    it 'returns name when capacity is 1' do
      place = described_class.new
      place.values[:name] = 'Chair'
      place.values[:capacity] = 1
      expect(place.display_text).to eq('Chair')
    end

    it 'includes seat count when capacity > 1' do
      place = described_class.new
      place.values[:name] = 'Couch'
      place.values[:capacity] = 3
      expect(place.display_text).to eq('Couch (3 seats)')
    end
  end

  describe '#at_capacity? behavior' do
    it 'returns false when capacity is nil' do
      place = described_class.new
      place.values[:capacity] = nil
      expect(place.at_capacity?).to be false
    end

    it 'returns false when capacity is 0' do
      place = described_class.new
      place.values[:capacity] = 0
      expect(place.at_capacity?).to be false
    end
  end
end
