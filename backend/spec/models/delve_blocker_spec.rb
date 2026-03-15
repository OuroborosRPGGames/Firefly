# frozen_string_literal: true

require 'spec_helper'

return unless DB.table_exists?(:delve_blockers)

RSpec.describe DelveBlocker do
  describe 'constants' do
    it 'defines BLOCKER_TYPES' do
      expect(described_class::BLOCKER_TYPES).to eq(%w[barricade locked_door gap narrow])
    end

    it 'defines DIRECTIONS' do
      expect(described_class::DIRECTIONS).to eq(%w[north south east west])
    end

    it 'defines STAT_SETTINGS' do
      expect(described_class::STAT_SETTINGS).to include('barricade', 'locked_door', 'gap', 'narrow')
    end

    it 'defines DEFAULT_STATS' do
      expect(described_class::DEFAULT_STATS).to include('barricade' => 'STR', 'locked_door' => 'DEX')
    end
  end

  describe 'associations' do
    it 'belongs to delve_room' do
      expect(described_class.association_reflections[:delve_room]).not_to be_nil
    end
  end

  describe 'instance methods' do
    it 'defines cleared?' do
      expect(described_class.instance_methods).to include(:cleared?)
    end

    it 'defines causes_damage_on_fail?' do
      expect(described_class.instance_methods).to include(:causes_damage_on_fail?)
    end

    it 'defines stat_for_check' do
      expect(described_class.instance_methods).to include(:stat_for_check)
    end

    it 'defines effective_difficulty' do
      expect(described_class.instance_methods).to include(:effective_difficulty)
    end

    it 'defines clear!' do
      expect(described_class.instance_methods).to include(:clear!)
    end

    it 'defines description' do
      expect(described_class.instance_methods).to include(:description)
    end

    it 'defines action_verb' do
      expect(described_class.instance_methods).to include(:action_verb)
    end
  end

  describe '#cleared? behavior' do
    it 'returns true when cleared is true' do
      blocker = described_class.new
      blocker.values[:cleared] = true
      expect(blocker.cleared?).to be true
    end

    it 'returns false when cleared is false' do
      blocker = described_class.new
      blocker.values[:cleared] = false
      expect(blocker.cleared?).to be false
    end
  end

  describe '#causes_damage_on_fail? behavior' do
    it 'returns true for gap type' do
      blocker = described_class.new
      blocker.values[:blocker_type] = 'gap'
      expect(blocker.causes_damage_on_fail?).to be true
    end

    it 'returns true for narrow type' do
      blocker = described_class.new
      blocker.values[:blocker_type] = 'narrow'
      expect(blocker.causes_damage_on_fail?).to be true
    end

    it 'returns false for barricade type' do
      blocker = described_class.new
      blocker.values[:blocker_type] = 'barricade'
      expect(blocker.causes_damage_on_fail?).to be false
    end
  end

  describe '#effective_difficulty behavior' do
    it 'calculates effective difficulty' do
      blocker = described_class.new
      blocker.values[:difficulty] = 10
      blocker.values[:easier_attempts] = 2
      expect(blocker.effective_difficulty).to eq(8)
    end

    it 'has minimum of 1' do
      blocker = described_class.new
      blocker.values[:difficulty] = 5
      blocker.values[:easier_attempts] = 10
      expect(blocker.effective_difficulty).to eq(1)
    end
  end
end
