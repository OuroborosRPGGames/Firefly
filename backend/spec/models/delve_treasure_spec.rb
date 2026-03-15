# frozen_string_literal: true

require 'spec_helper'

return unless DB.table_exists?(:delve_treasures)

RSpec.describe DelveTreasure do
  describe 'constants' do
    it 'defines CONTAINERS' do
      expect(described_class::CONTAINERS).to include(
        medieval: 'wooden chest',
        gaslight: 'brass strongbox',
        modern: 'metal safe',
        near_future: 'secure container',
        scifi: 'stasis pod'
      )
    end
  end

  describe 'associations' do
    it 'belongs to delve_room' do
      expect(described_class.association_reflections[:delve_room]).not_to be_nil
    end
  end

  describe 'instance methods' do
    it 'defines looted?' do
      expect(described_class.instance_methods).to include(:looted?)
    end

    it 'defines available?' do
      expect(described_class.instance_methods).to include(:available?)
    end

    it 'defines loot!' do
      expect(described_class.instance_methods).to include(:loot!)
    end

    it 'defines description' do
      expect(described_class.instance_methods).to include(:description)
    end

    it 'defines value_hint' do
      expect(described_class.instance_methods).to include(:value_hint)
    end
  end

  describe 'class methods' do
    it 'defines calculate_value' do
      expect(described_class).to respond_to(:calculate_value)
    end

    it 'defines container_for_era' do
      expect(described_class).to respond_to(:container_for_era)
    end
  end

  describe '#looted? behavior' do
    it 'returns true when looted is true' do
      treasure = described_class.new
      treasure.values[:looted] = true
      expect(treasure.looted?).to be true
    end

    it 'returns false when looted is false' do
      treasure = described_class.new
      treasure.values[:looted] = false
      expect(treasure.looted?).to be false
    end
  end

  describe '#available? behavior' do
    it 'returns true when not looted' do
      treasure = described_class.new
      treasure.values[:looted] = false
      expect(treasure.available?).to be true
    end

    it 'returns false when looted' do
      treasure = described_class.new
      treasure.values[:looted] = true
      expect(treasure.available?).to be false
    end
  end

  describe '#value_hint behavior' do
    it 'returns "a few coins" for low values' do
      treasure = described_class.new
      treasure.values[:gold_value] = 5
      expect(treasure.value_hint).to eq('a few coins')
    end

    it 'returns "a modest sum" for medium values' do
      treasure = described_class.new
      treasure.values[:gold_value] = 20
      expect(treasure.value_hint).to eq('a modest sum')
    end

    it 'returns "a king\'s ransom" for high values' do
      treasure = described_class.new
      treasure.values[:gold_value] = 200
      expect(treasure.value_hint).to eq("a king's ransom")
    end
  end

  describe '.calculate_value' do
    it 'returns integer value' do
      value = described_class.calculate_value(1)
      expect(value).to be_an(Integer)
    end

    it 'uses level multiplier' do
      # Level 2 should have 2x multiplier
      # Same seed should give consistent but scaled results
      rng1 = Random.new(12345)
      rng2 = Random.new(12345)

      val1 = described_class.calculate_value(1, rng1)
      val2 = described_class.calculate_value(2, rng2)

      # Level 2 value range is double level 1 range
      # Even if RNG gives same roll, the base range is higher
      expect(val2).to be >= val1
    end
  end

  describe '.container_for_era' do
    it 'returns correct container for medieval' do
      expect(described_class.container_for_era(:medieval)).to eq('wooden chest')
    end

    it 'returns correct container for scifi' do
      expect(described_class.container_for_era(:scifi)).to eq('stasis pod')
    end

    it 'returns fallback for unknown era' do
      expect(described_class.container_for_era(:unknown)).to eq('container')
    end
  end
end
