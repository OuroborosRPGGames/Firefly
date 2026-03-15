# frozen_string_literal: true

# NpcGoal tracks AI NPC goals, secrets, and triggers.
# Staff can set these to guide NPC behavior.
class NpcGoal < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character  # The NPC

  GOAL_TYPES = %w[
    objective secret trigger instruction preference
    short_term long_term reactive
  ].freeze
  PRIORITIES = %w[low medium high critical].freeze

  def validate
    super
    validates_presence [:character_id, :goal_type, self.class.content_column]
    validates_includes GOAL_TYPES, :goal_type
    validates_includes PRIORITIES, :priority if priority && self.class.priority_string?
  end

  def before_save
    super
    if self.class.priority_string?
      self.priority ||= 'medium'
    elsif self.class.columns.include?(:priority)
      self.priority ||= 5
    end
    self.active = true if self.class.uses_boolean_active? && !values.key?(:active)
    self.status ||= 'active' if self.class.uses_status_state? && !values.key?(:status)
    self.created_at ||= Time.now
  end

  def objective?
    goal_type == 'objective'
  end

  def secret?
    goal_type == 'secret'
  end

  def trigger?
    goal_type == 'trigger'
  end

  def instruction?
    goal_type == 'instruction'
  end

  def active?
    return active == true if self.class.uses_boolean_active?
    return status == 'active' if self.class.uses_status_state?

    true
  end

  def complete!
    updates = {}
    updates[:active] = false if self.class.uses_boolean_active?
    updates[:status] = 'completed' if self.class.uses_status_state?
    updates[:completed_at] = Time.now if self.class.columns.include?(:completed_at)
    update(updates)
  end

  def reveal!
    return unless secret?
    updates = {}
    updates[:revealed] = true if self.class.columns.include?(:revealed)
    updates[:revealed_at] = Time.now if self.class.columns.include?(:revealed_at)
    return if updates.empty?

    update(updates)
  end

  def revealed?
    return false unless self.class.columns.include?(:revealed)

    revealed == true
  end

  def high_priority?
    if priority.is_a?(String)
      %w[high critical].include?(priority)
    elsif self.class.columns.include?(:priority)
      priority.to_i <= 2
    else
      false
    end
  end

  def content_text
    if self.class.columns.include?(:content)
      content
    elsif self.class.columns.include?(:description)
      description
    end
  end

  # Get active goals for an NPC
  def self.active_for(npc)
    dataset = where(character_id: npc.id)
    dataset = dataset.where(active: true) if uses_boolean_active?
    dataset = dataset.where(status: 'active') if uses_status_state?

    if priority_string?
      dataset.order(Sequel.case({ 'critical' => 1, 'high' => 2, 'medium' => 3, 'low' => 4 }, 5, :priority))
    elsif columns.include?(:priority)
      dataset.order(:priority, Sequel.desc(:created_at))
    else
      dataset.order(Sequel.desc(:created_at))
    end
  end

  # Get unrevealed secrets for an NPC
  def self.secrets_for(npc)
    dataset = where(character_id: npc.id, goal_type: 'secret')
    dataset = dataset.where(revealed: false) if columns.include?(:revealed)
    dataset
  end

  def self.content_column
    columns.include?(:content) ? :content : :description
  end

  def self.priority_string?
    schema = db_schema[:priority]
    schema && schema[:type] == :string
  end

  def self.uses_boolean_active?
    columns.include?(:active)
  end

  def self.uses_status_state?
    columns.include?(:status)
  end
end
