# frozen_string_literal: true

# Skip loading if table doesn't exist
return unless DB.table_exists?(:activity_tasks)

class ActivityTask < Sequel::Model(:activity_tasks)
  plugin :validation_helpers

  many_to_one :round, class: :ActivityRound, key: :activity_round_id

  def actions
    ActivityAction.where(task_id: id).order(:id).all
  end

  def validate
    super
    validates_presence [:activity_round_id, :task_number]
    validates_includes [1, 2], :task_number
  end

  def primary?
    task_number == 1
  end

  def secondary?
    task_number == 2
  end

  def active_for_count?(n)
    n >= (min_participants || 1)
  end

  def stat_set_for(label)
    label == 'b' ? (stat_set_b || []) : (stat_set_a || [])
  end

  def stat_set_b?
    !stat_set_b.nil? && !stat_set_b.empty?
  end

  def to_builder_json
    {
      id: id,
      activity_round_id: activity_round_id,
      task_number: task_number,
      description: description,
      stat_set_a: stat_set_a&.to_a || [],
      stat_set_b: stat_set_b&.to_a || [],
      dc_reduction: dc_reduction || 3,
      min_participants: min_participants || 1
    }
  end
end
