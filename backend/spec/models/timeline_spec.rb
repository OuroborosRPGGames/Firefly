# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Timeline do
  describe 'constants' do
    it 'defines TIMELINE_TYPES' do
      expect(described_class::TIMELINE_TYPES).to eq(%w[snapshot historical])
    end

    it 'defines DEFAULT_RESTRICTIONS' do
      expect(described_class::DEFAULT_RESTRICTIONS).to include(
        'no_death' => true,
        'no_prisoner' => true,
        'no_xp' => true,
        'rooms_read_only' => true
      )
    end
  end

  describe 'associations' do
    it 'belongs to reality' do
      expect(described_class.association_reflections[:reality]).not_to be_nil
    end

    it 'belongs to source_character' do
      expect(described_class.association_reflections[:source_character]).not_to be_nil
    end

    it 'belongs to zone' do
      expect(described_class.association_reflections[:zone]).not_to be_nil
    end

    it 'has many character_instances' do
      expect(described_class.association_reflections[:character_instances]).not_to be_nil
    end
  end

  describe 'instance methods' do
    it 'defines snapshot?' do
      expect(described_class.instance_methods).to include(:snapshot?)
    end

    it 'defines historical?' do
      expect(described_class.instance_methods).to include(:historical?)
    end

    it 'defines past_timeline?' do
      expect(described_class.instance_methods).to include(:past_timeline?)
    end

    it 'defines parsed_restrictions' do
      expect(described_class.instance_methods).to include(:parsed_restrictions)
    end

    it 'defines no_death?' do
      expect(described_class.instance_methods).to include(:no_death?)
    end

    it 'defines no_prisoner?' do
      expect(described_class.instance_methods).to include(:no_prisoner?)
    end

    it 'defines no_xp?' do
      expect(described_class.instance_methods).to include(:no_xp?)
    end

    it 'defines rooms_read_only?' do
      expect(described_class.instance_methods).to include(:rooms_read_only?)
    end

    it 'defines display_name' do
      expect(described_class.instance_methods).to include(:display_name)
    end

    it 'defines deactivate!' do
      expect(described_class.instance_methods).to include(:deactivate!)
    end

    it 'defines in_use?' do
      expect(described_class.instance_methods).to include(:in_use?)
    end
  end

  describe 'class methods' do
    it 'defines find_or_create_historical' do
      expect(described_class).to respond_to(:find_or_create_historical)
    end

    it 'defines find_or_create_from_snapshot' do
      expect(described_class).to respond_to(:find_or_create_from_snapshot)
    end
  end

  describe '#snapshot? behavior' do
    it 'returns true for snapshot timeline_type' do
      timeline = described_class.new
      timeline.values[:timeline_type] = 'snapshot'
      expect(timeline.snapshot?).to be true
    end

    it 'returns false for historical timeline_type' do
      timeline = described_class.new
      timeline.values[:timeline_type] = 'historical'
      expect(timeline.snapshot?).to be false
    end
  end

  describe '#historical? behavior' do
    it 'returns true for historical timeline_type' do
      timeline = described_class.new
      timeline.values[:timeline_type] = 'historical'
      expect(timeline.historical?).to be true
    end

    it 'returns false for snapshot timeline_type' do
      timeline = described_class.new
      timeline.values[:timeline_type] = 'snapshot'
      expect(timeline.historical?).to be false
    end
  end

  describe '#past_timeline? behavior' do
    it 'returns true for snapshot' do
      timeline = described_class.new
      timeline.values[:timeline_type] = 'snapshot'
      expect(timeline.past_timeline?).to be true
    end

    it 'returns true for historical' do
      timeline = described_class.new
      timeline.values[:timeline_type] = 'historical'
      expect(timeline.past_timeline?).to be true
    end
  end

  describe '#parsed_restrictions behavior' do
    it 'returns empty hash when restrictions is nil' do
      timeline = described_class.new
      timeline.values[:restrictions] = nil
      expect(timeline.parsed_restrictions).to eq({})
    end
  end

  describe 'concurrency-safe find_or_create methods' do
    it 'returns existing historical timeline after unique constraint race' do
      zone = double('Zone', id: 42, name: 'Downtown')
      existing = double('Timeline')
      reality = double('Reality', id: 99)

      allow(described_class).to receive(:first).and_return(nil, existing)
      allow(Reality).to receive(:create).and_return(reality)
      allow(described_class).to receive(:create) { raise Sequel::UniqueConstraintViolation, 'duplicate key' }

      result = described_class.find_or_create_historical(year: 1920, zone: zone)
      expect(result).to eq(existing)
    end

    it 'returns existing snapshot timeline after unique constraint race' do
      snapshot = double('CharacterSnapshot', id: 55, name: 'Battle Eve', character_id: 101)
      existing = double('Timeline')
      reality = double('Reality', id: 123)

      allow(described_class).to receive(:first).and_return(nil, existing)
      allow(Reality).to receive(:create).and_return(reality)
      allow(described_class).to receive(:create) { raise Sequel::UniqueConstraintViolation, 'duplicate key' }

      result = described_class.find_or_create_from_snapshot(snapshot)
      expect(result).to eq(existing)
    end
  end
end
