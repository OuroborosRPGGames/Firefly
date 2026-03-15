# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcGoal do
  # Note: Model references columns that may differ from DB schema
  # Testing what's safely testable

  describe 'associations' do
    it 'belongs to a character' do
      expect(described_class.association_reflections[:character]).not_to be_nil
    end
  end

  describe '#objective?' do
    it 'returns true when goal_type is objective' do
      goal = described_class.new
      goal.values[:goal_type] = 'objective'
      expect(goal.objective?).to be true
    end

    it 'returns false when goal_type is not objective' do
      goal = described_class.new
      goal.values[:goal_type] = 'secret'
      expect(goal.objective?).to be false
    end
  end

  describe '#secret?' do
    it 'returns true when goal_type is secret' do
      goal = described_class.new
      goal.values[:goal_type] = 'secret'
      expect(goal.secret?).to be true
    end
  end

  describe '#trigger?' do
    it 'returns true when goal_type is trigger' do
      goal = described_class.new
      goal.values[:goal_type] = 'trigger'
      expect(goal.trigger?).to be true
    end
  end

  describe '#instruction?' do
    it 'returns true when goal_type is instruction' do
      goal = described_class.new
      goal.values[:goal_type] = 'instruction'
      expect(goal.instruction?).to be true
    end
  end

  describe 'constants' do
    it 'has GOAL_TYPES constant' do
      expect(described_class::GOAL_TYPES).to include('objective')
      expect(described_class::GOAL_TYPES).to include('secret')
      expect(described_class::GOAL_TYPES).to include('short_term')
    end

    it 'has PRIORITIES constant' do
      expect(described_class::PRIORITIES).to include('high')
      expect(described_class::PRIORITIES).to include('critical')
    end
  end

  describe '#high_priority?' do
    it 'returns true for high priority' do
      goal = described_class.new
      goal.values[:priority] = 'high'
      expect(goal.high_priority?).to be true
    end

    it 'returns true for critical priority' do
      goal = described_class.new
      goal.values[:priority] = 'critical'
      expect(goal.high_priority?).to be true
    end

    it 'returns false for medium priority' do
      goal = described_class.new
      goal.values[:priority] = 'medium'
      expect(goal.high_priority?).to be false
    end

    it 'returns false for low priority' do
      goal = described_class.new
      goal.values[:priority] = 'low'
      expect(goal.high_priority?).to be false
    end

    it 'handles legacy numeric priority values' do
      goal = described_class.new
      goal.values[:priority] = 1
      expect(goal.high_priority?).to be true
    end
  end

  describe '#content_text' do
    it 'returns description when content column is not available' do
      goal = described_class.new
      goal.values[:description] = 'Guard the archive'
      expect(goal.content_text).to eq('Guard the archive')
    end
  end

  describe '.active_for' do
    let(:npc) { create(:character, :npc) }

    it 'uses status-based filtering for legacy schema' do
      active_goal = described_class.create(
        character_id: npc.id,
        goal_type: 'short_term',
        description: 'Keep watch at the gate',
        status: 'active',
        priority: 2
      )

      described_class.create(
        character_id: npc.id,
        goal_type: 'short_term',
        description: 'This should be excluded',
        status: 'completed',
        priority: 1
      )

      results = described_class.active_for(npc).all
      expect(results.map(&:id)).to include(active_goal.id)
      expect(results.map(&:description)).not_to include('This should be excluded')
    end
  end
end
