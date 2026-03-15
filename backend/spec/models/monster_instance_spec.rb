# frozen_string_literal: true

require 'spec_helper'

RSpec.describe LargeMonsterInstance do
  describe 'constants' do
    it 'defines STATUSES' do
      expect(described_class::STATUSES).to eq(%w[active collapsed defeated])
    end
  end

  describe 'associations' do
    it 'belongs to monster_template' do
      expect(described_class.association_reflections[:monster_template]).not_to be_nil
    end

    it 'belongs to fight' do
      expect(described_class.association_reflections[:fight]).not_to be_nil
    end

    it 'has many monster_segment_instances' do
      expect(described_class.association_reflections[:monster_segment_instances]).not_to be_nil
    end

    it 'has many monster_mount_states' do
      expect(described_class.association_reflections[:monster_mount_states]).not_to be_nil
    end
  end

  describe 'instance methods' do
    it 'defines current_hp_percent method' do
      expect(described_class.instance_methods).to include(:current_hp_percent)
    end

    it 'defines defeated? method' do
      expect(described_class.instance_methods).to include(:defeated?)
    end

    it 'defines collapsed? method' do
      expect(described_class.instance_methods).to include(:collapsed?)
    end

    it 'defines segments_that_can_attack method' do
      expect(described_class.instance_methods).to include(:segments_that_can_attack)
    end

    it 'defines active_segments method' do
      expect(described_class.instance_methods).to include(:active_segments)
    end

    it 'defines mounted_participants method' do
      expect(described_class.instance_methods).to include(:mounted_participants)
    end

    it 'defines occupied_hexes method' do
      expect(described_class.instance_methods).to include(:occupied_hexes)
    end

    it 'defines segment_at_hex method' do
      expect(described_class.instance_methods).to include(:segment_at_hex)
    end

    it 'defines apply_damage! method' do
      expect(described_class.instance_methods).to include(:apply_damage!)
    end

    it 'defines weak_point_segment method' do
      expect(described_class.instance_methods).to include(:weak_point_segment)
    end
  end

  describe '#current_hp_percent behavior' do
    it 'calculates percentage' do
      instance = described_class.new
      instance.values[:current_hp] = 50
      instance.values[:max_hp] = 100
      expect(instance.current_hp_percent).to eq(50.0)
    end

    it 'handles zero max_hp' do
      instance = described_class.new
      instance.values[:current_hp] = 0
      instance.values[:max_hp] = 0
      expect(instance.current_hp_percent).to eq(0)
    end
  end

  describe '#collapsed? behavior' do
    it 'returns true when status is collapsed' do
      instance = described_class.new
      instance.values[:status] = 'collapsed'
      expect(instance.collapsed?).to be true
    end

    it 'returns false when status is active' do
      instance = described_class.new
      instance.values[:status] = 'active'
      expect(instance.collapsed?).to be false
    end
  end
end
