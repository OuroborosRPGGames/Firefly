# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StatBlock do
  let(:universe) { create(:universe) }
  let(:stat_block) { StatBlock.create(universe_id: universe.id, name: 'Test Stats', block_type: 'single') }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(stat_block).to be_valid
    end

    it 'requires universe_id' do
      sb = StatBlock.new(name: 'Test', block_type: 'single')
      expect(sb).not_to be_valid
    end

    it 'requires name' do
      sb = StatBlock.new(universe_id: universe.id, block_type: 'single')
      expect(sb).not_to be_valid
    end

    it 'requires block_type' do
      sb = StatBlock.new(universe_id: universe.id, name: 'Test')
      expect(sb).not_to be_valid
    end

    it 'validates max length of name' do
      sb = StatBlock.new(universe_id: universe.id, name: 'x' * 101, block_type: 'single')
      expect(sb).not_to be_valid
    end

    it 'validates uniqueness of name per universe' do
      StatBlock.create(universe_id: universe.id, name: 'Combat', block_type: 'single')
      duplicate = StatBlock.new(universe_id: universe.id, name: 'Combat', block_type: 'single')
      expect(duplicate).not_to be_valid
    end

    it 'validates block_type inclusion' do
      %w[single paired].each do |type|
        sb = StatBlock.create(universe_id: universe.id, name: "#{type} block", block_type: type)
        expect(sb).to be_valid
      end

      sb = StatBlock.new(universe_id: universe.id, name: 'Invalid', block_type: 'invalid')
      expect(sb).not_to be_valid
    end

    it 'validates cost_formula inclusion when present' do
      %w[doubling_every_other linear_increasing].each do |formula|
        sb = StatBlock.create(universe_id: universe.id, name: "Formula #{formula}", block_type: 'single', cost_formula: formula)
        expect(sb).to be_valid
      end
    end
  end

  describe 'associations' do
    it 'belongs to universe' do
      expect(stat_block.universe).to eq(universe)
    end

    it 'has many stats' do
      expect(stat_block).to respond_to(:stats)
    end
  end

  describe 'before_save defaults' do
    it 'defaults is_default to false' do
      expect(stat_block.is_default).to be false
    end

    it 'defaults total_points to 50 for single type' do
      expect(stat_block.total_points).to eq(50)
    end

    it 'defaults total_points to 25 for paired type' do
      paired = StatBlock.create(universe_id: universe.id, name: 'Paired', block_type: 'paired')
      expect(paired.total_points).to eq(25)
    end

    it 'defaults min_stat_value to 1' do
      expect(stat_block.min_stat_value).to eq(1)
    end

    it 'defaults max_stat_value to 10 for single type' do
      expect(stat_block.max_stat_value).to eq(10)
    end

    it 'defaults max_stat_value to 5 for paired type' do
      paired = StatBlock.create(universe_id: universe.id, name: 'Paired', block_type: 'paired')
      expect(paired.max_stat_value).to eq(5)
    end

    it 'defaults cost_formula for single type' do
      expect(stat_block.cost_formula).to eq('doubling_every_other')
    end

    it 'defaults cost_formula for paired type' do
      paired = StatBlock.create(universe_id: universe.id, name: 'Paired', block_type: 'paired')
      expect(paired.cost_formula).to eq('linear_increasing')
    end

    it 'defaults primary_label to Stats' do
      expect(stat_block.primary_label).to eq('Stats')
    end

    it 'defaults secondary_label to Skills' do
      expect(stat_block.secondary_label).to eq('Skills')
    end
  end

  describe '#single?' do
    it 'returns true for single block type' do
      expect(stat_block.single?).to be true
    end

    it 'returns false for paired block type' do
      paired = StatBlock.create(universe_id: universe.id, name: 'Paired', block_type: 'paired')
      expect(paired.single?).to be false
    end
  end

  describe '#paired?' do
    it 'returns false for single block type' do
      expect(stat_block.paired?).to be false
    end

    it 'returns true for paired block type' do
      paired = StatBlock.create(universe_id: universe.id, name: 'Paired', block_type: 'paired')
      expect(paired.paired?).to be true
    end
  end

  describe '#point_cost_for_level' do
    context 'with doubling_every_other formula' do
      # Formula: ((level + 1) / 2.0).ceil
      # Level 1: (2/2.0).ceil = 1
      # Level 2: (3/2.0).ceil = 2
      # Level 3: (4/2.0).ceil = 2
      # Level 4: (5/2.0).ceil = 3
      # Level 10: (11/2.0).ceil = 6

      it 'returns 0 for level 0 or below' do
        expect(stat_block.point_cost_for_level(0)).to eq(0)
        expect(stat_block.point_cost_for_level(-1)).to eq(0)
      end

      it 'returns 1 for level 1' do
        expect(stat_block.point_cost_for_level(1)).to eq(1)
      end

      it 'returns 2 for level 2' do
        expect(stat_block.point_cost_for_level(2)).to eq(2)
      end

      it 'returns 2 for level 3' do
        expect(stat_block.point_cost_for_level(3)).to eq(2)
      end

      it 'returns 3 for level 4' do
        expect(stat_block.point_cost_for_level(4)).to eq(3)
      end

      it 'returns 6 for level 10' do
        expect(stat_block.point_cost_for_level(10)).to eq(6)
      end
    end

    context 'with linear_increasing formula' do
      let(:paired_block) { StatBlock.create(universe_id: universe.id, name: 'Paired', block_type: 'paired') }

      it 'returns the level value' do
        expect(paired_block.point_cost_for_level(1)).to eq(1)
        expect(paired_block.point_cost_for_level(2)).to eq(2)
        expect(paired_block.point_cost_for_level(3)).to eq(3)
        expect(paired_block.point_cost_for_level(5)).to eq(5)
      end
    end
  end

  describe '#total_cost_for_level' do
    it 'returns 0 for level 0 or below' do
      expect(stat_block.total_cost_for_level(0)).to eq(0)
      expect(stat_block.total_cost_for_level(-1)).to eq(0)
    end

    it 'returns cumulative cost for doubling_every_other' do
      # Level 1: 1, Level 2: 1+2=3, Level 3: 1+2+2=5, Level 4: 1+2+2+3=8
      expect(stat_block.total_cost_for_level(1)).to eq(1)
      expect(stat_block.total_cost_for_level(2)).to eq(3)
      expect(stat_block.total_cost_for_level(3)).to eq(5)
      expect(stat_block.total_cost_for_level(4)).to eq(8)
    end
  end

  describe '.default_for' do
    it 'returns the default stat block for universe when is_default is true' do
      sb = StatBlock.create(universe_id: universe.id, name: 'Default', block_type: 'single', is_default: true)
      expect(described_class.default_for(universe)).to eq(sb)
    end

    it 'returns a stat block for the universe if no default set' do
      # Ensure stat_block exists
      stat_block
      result = described_class.default_for(universe)
      expect(result).not_to be_nil
      expect(result.universe_id).to eq(universe.id)
    end

    it 'returns nil if no stat blocks exist' do
      other_universe = create(:universe)
      expect(described_class.default_for(other_universe)).to be_nil
    end
  end

  describe '#to_allocation_config' do
    it 'returns hash with block configuration' do
      config = stat_block.to_allocation_config
      expect(config[:id]).to eq(stat_block.id)
      expect(config[:name]).to eq('Test Stats')
      expect(config[:block_type]).to eq('single')
      expect(config[:total_points]).to eq(50)
      expect(config[:min_stat_value]).to eq(1)
      expect(config[:max_stat_value]).to eq(10)
      expect(config[:stats]).to be_an(Array)
    end
  end

  describe 'constants' do
    it 'defines BLOCK_TYPES' do
      expect(described_class::BLOCK_TYPES).to eq(%w[single paired])
    end

    it 'defines COST_FORMULAS' do
      expect(described_class::COST_FORMULAS).to eq(%w[doubling_every_other linear_increasing])
    end
  end

  describe '#primary_stats' do
    it 'returns stats with primary category ordered by display_order' do
      stat1 = create(:stat, stat_block: stat_block, stat_category: 'primary', display_order: 2)
      stat2 = create(:stat, stat_block: stat_block, stat_category: 'primary', display_order: 1)
      create(:stat, stat_block: stat_block, stat_category: 'skill', display_order: 0)

      result = stat_block.primary_stats.all
      expect(result).to eq([stat2, stat1])
    end
  end

  describe '#secondary_stats' do
    it 'returns stats with secondary category ordered by display_order' do
      stat1 = create(:stat, stat_block: stat_block, stat_category: 'secondary', display_order: 2)
      stat2 = create(:stat, stat_block: stat_block, stat_category: 'secondary', display_order: 1)
      create(:stat, stat_block: stat_block, stat_category: 'primary', display_order: 0)

      result = stat_block.secondary_stats.all
      expect(result).to eq([stat2, stat1])
    end
  end

  describe '#skills' do
    it 'returns stats with skill category ordered by display_order' do
      skill1 = create(:stat, stat_block: stat_block, stat_category: 'skill', display_order: 2)
      skill2 = create(:stat, stat_block: stat_block, stat_category: 'skill', display_order: 1)
      create(:stat, stat_block: stat_block, stat_category: 'primary', display_order: 0)

      result = stat_block.skills.all
      expect(result).to eq([skill2, skill1])
    end
  end

  describe '#calculate_allocation_cost' do
    let!(:stat1) { create(:stat, stat_block: stat_block, stat_category: 'primary', display_order: 0) }
    let!(:stat2) { create(:stat, stat_block: stat_block, stat_category: 'primary', display_order: 1) }

    it 'calculates total cost for allocations' do
      # Level 3 costs 5 points total (1+2+2), Level 2 costs 3 points (1+2)
      allocations = { stat1.id => 3, stat2.id => 2 }
      expect(stat_block.calculate_allocation_cost(allocations)).to eq(8)
    end

    it 'ignores stats not in the block' do
      allocations = { stat1.id => 3, 999999 => 10 }
      expect(stat_block.calculate_allocation_cost(allocations)).to eq(5)
    end

    it 'handles string keys in allocations' do
      allocations = { stat1.id.to_s => 3 }
      expect(stat_block.calculate_allocation_cost(allocations)).to eq(5)
    end

    context 'with category filter' do
      let(:paired_block) { StatBlock.create(universe_id: universe.id, name: 'Paired', block_type: 'paired') }
      let!(:primary_stat) { create(:stat, stat_block: paired_block, stat_category: 'primary') }
      let!(:secondary_stat) { create(:stat, stat_block: paired_block, stat_category: 'secondary') }

      it 'filters by primary category' do
        allocations = { primary_stat.id => 2, secondary_stat.id => 3 }
        # linear_increasing: level 2 = 1+2 = 3
        expect(paired_block.calculate_allocation_cost(allocations, category: 'primary')).to eq(3)
      end

      it 'filters by secondary category' do
        allocations = { primary_stat.id => 2, secondary_stat.id => 3 }
        # linear_increasing: level 3 = 1+2+3 = 6
        expect(paired_block.calculate_allocation_cost(allocations, category: 'secondary')).to eq(6)
      end
    end
  end

  describe '#validate_allocation' do
    context 'with single block type' do
      let!(:stat1) { create(:stat, stat_block: stat_block, stat_category: 'primary', name: 'Strength') }
      let!(:stat2) { create(:stat, stat_block: stat_block, stat_category: 'primary', name: 'Dexterity') }

      it 'returns valid for allocation within limits' do
        # Level 5 costs 1+2+2+3+3 = 11 points each, total 22
        allocations = { stat1.id => 5, stat2.id => 5 }
        result = stat_block.validate_allocation(allocations)

        expect(result[:valid]).to be true
        expect(result[:errors]).to be_empty
        expect(result[:total_spent]).to eq(22)
        expect(result[:total_remaining]).to eq(28)
      end

      it 'returns errors when total points exceeded' do
        # Set lower total points for testing
        stat_block.update(total_points: 10)
        allocations = { stat1.id => 5, stat2.id => 5 }
        result = stat_block.validate_allocation(allocations)

        expect(result[:valid]).to be false
        expect(result[:errors]).to include(a_string_matching(/exceed.*10 points/))
      end

      it 'returns errors when stat below minimum' do
        allocations = { stat1.id => 0, stat2.id => 5 }
        result = stat_block.validate_allocation(allocations)

        expect(result[:valid]).to be false
        expect(result[:errors]).to include(a_string_matching(/Strength below minimum/))
      end

      it 'returns errors when stat exceeds maximum' do
        allocations = { stat1.id => 11, stat2.id => 5 }
        result = stat_block.validate_allocation(allocations)

        expect(result[:valid]).to be false
        expect(result[:errors]).to include(a_string_matching(/Strength exceeds maximum/))
      end

      it 'handles string keys in allocations' do
        allocations = { stat1.id.to_s => 5, stat2.id.to_s => 5 }
        result = stat_block.validate_allocation(allocations)

        expect(result[:valid]).to be true
      end

      it 'handles string values in allocations' do
        allocations = { stat1.id => '5', stat2.id => '5' }
        result = stat_block.validate_allocation(allocations)

        expect(result[:valid]).to be true
      end
    end

    context 'with paired block type' do
      let(:paired_block) { StatBlock.create(universe_id: universe.id, name: 'Paired', block_type: 'paired') }
      let!(:primary_stat1) { create(:stat, stat_block: paired_block, stat_category: 'primary', name: 'Strength') }
      let!(:primary_stat2) { create(:stat, stat_block: paired_block, stat_category: 'primary', name: 'Dexterity') }
      let!(:secondary_stat1) { create(:stat, stat_block: paired_block, stat_category: 'secondary', name: 'Melee') }
      let!(:secondary_stat2) { create(:stat, stat_block: paired_block, stat_category: 'secondary', name: 'Ranged') }

      it 'returns valid for allocation within both pools' do
        # For paired: total_points=25 (primary), secondary_points=25
        # linear_increasing: level 3 = 1+2+3 = 6 each
        allocations = {
          primary_stat1.id => 3, primary_stat2.id => 3,
          secondary_stat1.id => 3, secondary_stat2.id => 3
        }
        result = paired_block.validate_allocation(allocations)

        expect(result[:valid]).to be true
        expect(result[:primary_spent]).to eq(12)
        expect(result[:secondary_spent]).to eq(12)
        expect(result[:primary_remaining]).to eq(13)
        expect(result[:secondary_remaining]).to eq(13)
      end

      it 'returns errors when primary points exceeded' do
        paired_block.update(total_points: 5)
        allocations = {
          primary_stat1.id => 3, primary_stat2.id => 3,
          secondary_stat1.id => 1, secondary_stat2.id => 1
        }
        result = paired_block.validate_allocation(allocations)

        expect(result[:valid]).to be false
        expect(result[:errors]).to include(a_string_matching(/Primary stats exceed/))
      end

      it 'returns errors when secondary points exceeded' do
        paired_block.update(secondary_points: 5)
        allocations = {
          primary_stat1.id => 1, primary_stat2.id => 1,
          secondary_stat1.id => 3, secondary_stat2.id => 3
        }
        result = paired_block.validate_allocation(allocations)

        expect(result[:valid]).to be false
        expect(result[:errors]).to include(a_string_matching(/Secondary stats exceed/))
      end
    end
  end

  describe '#point_cost_for_level with unknown formula' do
    it 'falls back to level as cost' do
      # Bypass validation for testing the else branch
      stat_block.this.update(cost_formula: 'unknown')
      stat_block.refresh
      expect(stat_block.point_cost_for_level(5)).to eq(5)
    end
  end
end
