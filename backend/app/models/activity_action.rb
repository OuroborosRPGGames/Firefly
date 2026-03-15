# frozen_string_literal: true

# Skip loading if table doesn't exist
return unless DB.table_exists?(:activity_actions)

class ActivityAction < Sequel::Model(:activity_actions)
  unrestrict_primary_key
  set_primary_key :id
  plugin :validation_helpers

  # Deferred associations
  def activity
    Activity[activity_parent]
  end

  def task
    return nil unless task_id

    ActivityTask[task_id]
  end

  def validate
    super
    validates_presence [:activity_parent, :choice_string]
  end

  # Convenience accessors
  def choice_text
    choice_string
  end

  def success_text
    output_string
  end

  def failure_text
    fail_string
  end

  # Skills required for this action
  def required_skills
    skills = []
    skills << skill_one if skill_one && skill_one > 0
    skills << skill_two if skill_two && skill_two > 0
    skills << skill_three if skill_three && skill_three > 0
    skills << skill_four if skill_four && skill_four > 0
    skills << skill_five if skill_five && skill_five > 0
    skills
  end

  def skill_ids
    skill_list || required_skills
  end

  def skill_count
    skill_ids.length
  end

  # Get stats for this action from a character
  # Stat IDs are stored directly on the action (skill_one..skill_five / skill_list),
  # so we look them up by ID and get the character's value — no universe/stat_block needed.
  def stat_values_for(character_instance)
    return [] unless character_instance
    return [] if skill_ids.empty?

    skill_ids.map do |stat_id|
      stat = Stat.find(id: stat_id)
      next 0 unless stat

      StatAllocationService.get_stat_value(character_instance, stat.abbreviation) || 0
    end.compact
  end

  # Calculate stat bonus based on the activity's stat calculation rules
  def stat_bonus_for(character_instance)
    values = stat_values_for(character_instance)
    return 0 if values.empty?

    case values.length
    when 1
      values.first
    when 2
      # Two-stat system: sum both
      values.sum
    else
      # Multiple of same category: average
      values.sum / values.length
    end
  end

  # Calculate stat bonus from the parent task's stat set (A or B)
  # Falls back to existing stat_bonus_for when no task is assigned
  def task_stat_bonus_for(character_instance)
    parent_task = task
    return stat_bonus_for(character_instance) unless parent_task

    label = self[:stat_set_label]
    stat_ids = parent_task.stat_set_for(label || 'a')
    return stat_bonus_for(character_instance) if stat_ids.empty?

    return 0 unless character_instance

    values = stat_ids.map do |stat_id|
      stat = Stat.find(id: stat_id)
      next 0 unless stat

      StatAllocationService.get_stat_value(character_instance, stat.abbreviation) || 0
    end.compact

    return 0 if values.empty?

    values.length <= 2 ? values.sum : values.sum / values.length
  end

  # Variable risk sides (e.g. 3 = d3 rolling -3..+3)
  def risk_sides_value
    self[:risk_sides]
  end

  # Display
  def display_name
    choice_string
  end

  # Check if this action is available to a specific role
  # @param role [String, nil] the participant's role
  # @return [Boolean] true if role can use this action
  def available_to_role?(role)
    # No role restriction means all roles allowed
    return true if StringHelper.blank?(allowed_roles)
    # No participant role means access to all actions
    return true if StringHelper.blank?(role)

    allowed_list = allowed_roles.split(',').map { |r| r.strip.downcase }
    allowed_list.include?(role.to_s.strip.downcase)
  end

  # Get list of allowed roles
  # @return [Array<String>] roles that can use this action (empty = all)
  def allowed_role_list
    return [] if StringHelper.blank?(allowed_roles)

    allowed_roles.split(',').map(&:strip)
  end
end
