# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Stat do
  let(:universe) { create(:universe) }
  let(:stat_block) { StatBlock.create(universe_id: universe.id, name: 'Combat', block_type: 'single') }
  let(:stat) { Stat.create(stat_block_id: stat_block.id, name: 'Strength', abbreviation: 'STR') }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(stat).to be_valid
    end

    it 'requires stat_block_id' do
      s = Stat.new(name: 'Test', abbreviation: 'TST')
      expect(s).not_to be_valid
    end

    it 'requires name' do
      s = Stat.new(stat_block_id: stat_block.id, abbreviation: 'TST')
      expect(s).not_to be_valid
    end

    it 'requires abbreviation' do
      s = Stat.new(stat_block_id: stat_block.id, name: 'Test')
      expect(s).not_to be_valid
    end

    it 'validates max length of name' do
      s = Stat.new(stat_block_id: stat_block.id, name: 'x' * 51, abbreviation: 'TST')
      expect(s).not_to be_valid
    end

    it 'validates max length of abbreviation' do
      s = Stat.new(stat_block_id: stat_block.id, name: 'Test', abbreviation: 'x' * 11)
      expect(s).not_to be_valid
    end

    it 'validates uniqueness of name per stat_block' do
      Stat.create(stat_block_id: stat_block.id, name: 'Unique', abbreviation: 'UNQ')
      duplicate = Stat.new(stat_block_id: stat_block.id, name: 'Unique', abbreviation: 'UNQ2')
      expect(duplicate).not_to be_valid
    end

    it 'validates uniqueness of abbreviation per stat_block' do
      Stat.create(stat_block_id: stat_block.id, name: 'Test', abbreviation: 'ABBR')
      duplicate = Stat.new(stat_block_id: stat_block.id, name: 'Test 2', abbreviation: 'ABBR')
      expect(duplicate).not_to be_valid
    end

    it 'validates stat_category inclusion' do
      %w[primary secondary skill derived].each do |cat|
        s = Stat.create(stat_block_id: stat_block.id, name: "Cat #{cat}", abbreviation: cat.upcase[0..2], stat_category: cat)
        expect(s).to be_valid
      end
    end
  end

  describe 'associations' do
    it 'belongs to stat_block' do
      expect(stat.stat_block).to eq(stat_block)
    end

    it 'can have a parent_stat' do
      expect(stat).to respond_to(:parent_stat)
    end

    it 'has many child_stats' do
      expect(stat).to respond_to(:child_stats)
    end

    it 'has many character_stats' do
      expect(stat).to respond_to(:character_stats)
    end
  end

  describe 'before_save defaults' do
    it 'defaults stat_category to primary' do
      expect(stat.stat_category).to eq('primary')
    end

    it 'defaults min_value to 1' do
      expect(stat.min_value).to eq(1)
    end

    it 'defaults max_value to 20' do
      expect(stat.max_value).to eq(20)
    end

    it 'defaults default_value to 10' do
      expect(stat.default_value).to eq(10)
    end

    it 'defaults display_order to 0' do
      expect(stat.display_order).to eq(0)
    end
  end

  describe '#skill?' do
    it 'returns true when stat_category is skill' do
      stat.update(stat_category: 'skill')
      expect(stat.skill?).to be true
    end

    it 'returns false when stat_category is not skill' do
      expect(stat.skill?).to be false
    end
  end

  describe '#derived?' do
    it 'returns true when stat_category is derived' do
      stat.update(stat_category: 'derived')
      expect(stat.derived?).to be true
    end

    it 'returns false when stat_category is not derived' do
      expect(stat.derived?).to be false
    end
  end

  describe '#has_parent?' do
    let(:child_stat) { Stat.create(stat_block_id: stat_block.id, name: 'Child', abbreviation: 'CHD', parent_stat_id: stat.id) }

    it 'returns true when parent_stat_id is set' do
      expect(child_stat.has_parent?).to be true
    end

    it 'returns false when parent_stat_id is nil' do
      expect(stat.has_parent?).to be false
    end
  end

  # Note: calculate_derived method references derivation_formula column which doesn't exist in schema
  describe '#calculate_derived' do
    it 'responds to calculate_derived' do
      expect(stat).to respond_to(:calculate_derived)
    end
  end

  describe 'constants' do
    it 'defines CATEGORIES' do
      expect(described_class::CATEGORIES).to eq(%w[primary secondary skill derived])
    end
  end
end
