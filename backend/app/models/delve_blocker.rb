# frozen_string_literal: true

# DelveBlocker represents a skill check obstacle blocking a direction.
# Types: barricade (strength), locked_door (dexterity), gap (agility), narrow (agility)
return unless DB.table_exists?(:delve_blockers)

class DelveBlocker < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :delve_room

  BLOCKER_TYPES = %w[barricade locked_door gap narrow].freeze
  DIRECTIONS = %w[north south east west].freeze

  # Maps blocker types to their GameSetting keys for stat configuration
  STAT_SETTINGS = {
    'barricade' => 'delve_barricade_stat',
    'locked_door' => 'delve_lockpick_stat',
    'gap' => 'delve_jump_stat',
    'narrow' => 'delve_balance_stat'
  }.freeze

  # Default stats if GameSetting not configured
  DEFAULT_STATS = {
    'barricade' => 'STR',
    'locked_door' => 'DEX',
    'gap' => 'AGI',
    'narrow' => 'AGI'
  }.freeze

  def validate
    super
    validates_presence [:delve_room_id, :direction, :blocker_type]
    validates_includes BLOCKER_TYPES, :blocker_type if blocker_type
    validates_includes DIRECTIONS, :direction if direction
    validates_unique [:delve_room_id, :direction]
  end

  def before_save
    super
    self.difficulty ||= 10
    self.easier_attempts ||= 0
    self.cleared = false if cleared.nil?
  end

  # ====== State Checks ======

  def cleared?
    cleared == true
  end

  # Blockers where failure causes damage
  def causes_damage_on_fail?
    %w[gap narrow].include?(blocker_type)
  end

  # ====== Stat Configuration ======

  # Get the stat abbreviation used for this blocker's skill check
  def stat_for_check
    setting_key = STAT_SETTINGS[blocker_type]
    GameSetting.get(setting_key) || DEFAULT_STATS[blocker_type] || 'STR'
  end

  # Get effective difficulty (base - easier attempts)
  def effective_difficulty
    [difficulty - (easier_attempts || 0), 1].max
  end

  # ====== Actions ======

  # Mark this blocker as cleared
  def clear!
    update(cleared: true, cleared_at: Time.now)
  end

  # Increment easier attempts counter
  def increment_easier_attempts!
    update(easier_attempts: (easier_attempts || 0) + 1)
  end

  # ====== Display ======

  # Get description based on blocker type
  def description
    case blocker_type
    when 'barricade'
      'A heavy barricade blocks the way. It needs to be broken through.'
    when 'locked_door'
      'A locked door bars passage. The lock needs to be picked.'
    when 'gap'
      'A dangerous gap stretches across the path. You need to jump across.'
    when 'narrow'
      'The passage narrows to a precarious ledge. Careful balance is required.'
    else
      'An obstacle blocks the way.'
    end
  end

  # Get action verb for this blocker
  def action_verb
    case blocker_type
    when 'barricade' then 'break'
    when 'locked_door' then 'pick'
    when 'gap' then 'jump'
    when 'narrow' then 'balance'
    else 'attempt'
    end
  end
end
