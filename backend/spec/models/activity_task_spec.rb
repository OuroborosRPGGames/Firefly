# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityTask do
  let(:activity) { create(:activity) }
  let(:round) { create(:activity_round, activity: activity) }

  describe 'validations' do
    it 'requires activity_round_id' do
      task = ActivityTask.new(task_number: 1)
      expect(task.valid?).to be false
    end

    it 'requires task_number' do
      task = ActivityTask.new(activity_round_id: round.id)
      expect(task.valid?).to be false
    end

    it 'only allows task_number 1 or 2' do
      task = ActivityTask.new(activity_round_id: round.id, task_number: 3)
      expect(task.valid?).to be false
    end

    it 'is valid with required fields' do
      task = ActivityTask.new(activity_round_id: round.id, task_number: 1, description: 'Test')
      expect(task.valid?).to be true
    end

    it 'enforces unique [activity_round_id, task_number]' do
      create(:activity_task, round: round, task_number: 1)
      expect {
        create(:activity_task, round: round, task_number: 1)
      }.to raise_error(Sequel::UniqueConstraintViolation)
    end
  end

  describe '#primary? and #secondary?' do
    it 'identifies primary tasks' do
      task = build(:activity_task, round: round, task_number: 1)
      expect(task.primary?).to be true
      expect(task.secondary?).to be false
    end

    it 'identifies secondary tasks' do
      task = build(:activity_task, round: round, task_number: 2)
      expect(task.primary?).to be false
      expect(task.secondary?).to be true
    end
  end

  describe '#active_for_count?' do
    it 'returns true when participant count meets minimum' do
      task = build(:activity_task, round: round, min_participants: 3)
      expect(task.active_for_count?(3)).to be true
      expect(task.active_for_count?(5)).to be true
    end

    it 'returns false when participant count below minimum' do
      task = build(:activity_task, round: round, min_participants: 3)
      expect(task.active_for_count?(2)).to be false
    end

    it 'defaults to 1 when min_participants is nil' do
      task = build(:activity_task, round: round, min_participants: nil)
      expect(task.active_for_count?(1)).to be true
    end
  end

  describe '#stat_set_for' do
    let(:task) do
      create(:activity_task, round: round, task_number: 1,
             stat_set_a: Sequel.pg_array([1, 2], :integer),
             stat_set_b: Sequel.pg_array([3], :integer))
    end

    it 'returns stat set A for label a' do
      expect(task.stat_set_for('a').to_a).to eq([1, 2])
    end

    it 'returns stat set B for label b' do
      expect(task.stat_set_for('b').to_a).to eq([3])
    end

    it 'returns stat set A for nil label' do
      expect(task.stat_set_for(nil).to_a).to eq([1, 2])
    end

    it 'returns empty array when stat_set_b is nil' do
      task2 = create(:activity_task, round: round, task_number: 2)
      expect(task2.stat_set_for('b')).to eq([])
    end
  end

  describe '#stat_set_b?' do
    it 'returns true when stat_set_b has values' do
      task = create(:activity_task, round: round, task_number: 1,
                    stat_set_b: Sequel.pg_array([1], :integer))
      expect(task.stat_set_b?).to be true
    end

    it 'returns false when stat_set_b is nil' do
      task = create(:activity_task, round: round, task_number: 1)
      expect(task.stat_set_b?).to be false
    end
  end

  describe '#round association' do
    it 'returns the parent round' do
      task = create(:activity_task, round: round, task_number: 1)
      expect(task.round).to eq(round)
    end
  end

  describe '#actions' do
    it 'returns actions assigned to this task' do
      task = create(:activity_task, round: round, task_number: 1)
      action1 = create(:activity_action, activity: activity, task_id: task.id)
      action2 = create(:activity_action, activity: activity, task_id: nil)

      expect(task.actions.map(&:id)).to include(action1.id)
      expect(task.actions.map(&:id)).not_to include(action2.id)
    end
  end

  describe '#to_builder_json' do
    it 'returns expected hash structure' do
      task = create(:activity_task, round: round, task_number: 1,
                    description: 'Test task', dc_reduction: 5, min_participants: 2,
                    stat_set_a: Sequel.pg_array([1], :integer))
      json = task.to_builder_json

      expect(json[:id]).to eq(task.id)
      expect(json[:task_number]).to eq(1)
      expect(json[:description]).to eq('Test task')
      expect(json[:dc_reduction]).to eq(5)
      expect(json[:min_participants]).to eq(2)
      expect(json[:stat_set_a]).to eq([1])
    end
  end
end
