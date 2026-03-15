# frozen_string_literal: true

# Skip loading if table doesn't exist
return unless DB.table_exists?(:activity_participants)

class ActivityParticipant < Sequel::Model(:activity_participants)
  unrestrict_primary_key
  set_primary_key :id
  plugin :validation_helpers

  MAX_WILLPOWER = 10

  # Explicit column accessor for willpower_to_spend (added by migration 292)
  def willpower_to_spend
    self[:willpower_to_spend] || 0
  end

  def willpower_to_spend=(val)
    self[:willpower_to_spend] = val.to_i
  end

  # Relationships
  many_to_one :character, key: :char_id

  # Deferred associations (memoized to avoid N+1 queries)
  def instance
    @instance ||= ActivityInstance[instance_id]
  end

  def activity
    @activity ||= Activity[activity_parent]
  end

  def chosen_action
    return nil unless action_chosen

    ActivityAction[action_chosen]
  end

  def chosen_task
    tc = self[:task_chosen]
    return nil unless tc

    ActivityTask[tc]
  end

  def choose_task!(task_id)
    update(task_chosen: task_id)
  end

  def target_participant
    return nil unless action_target

    ActivityParticipant[action_target]
  end

  def validate
    super
    validates_presence [:instance_id, :char_id]
  end

  # Convenience accessors (memoized; clear with reload or new round)
  def character_instance
    @character_instance ||= CharacterInstance.first(character_id: char_id, online: true)
  end

  # Status checks
  def active?
    !!continue
  end

  def chosen?
    # effort_chosen stores special actions: 'help' or 'recover'
    # action_chosen is an integer (action ID)
    return !action_target.nil? if effort_chosen == 'help'
    return true if effort_chosen == 'recover'

    # Has chosen if action_chosen is set (non-nil integer)
    !action_chosen.nil?
  end
  alias has_chosen? chosen?
  alias ready? chosen?

  # Willpower
  def available_willpower
    self[:willpower] || 0
  end

  def willpower_ticks_remaining
    self[:willpower_ticks] || 0
  end

  def can_use_willpower?
    available_willpower > 0
  end

  def use_willpower!(amount = 1)
    return false if available_willpower < amount

    update(willpower: available_willpower - amount)
    true
  end

  def gain_willpower!(amount = 1)
    new_willpower = [available_willpower + amount, MAX_WILLPOWER].min
    update(willpower: new_willpower)
  end

  def tick_willpower!
    # Gain willpower from ticks (recovery over time)
    return unless willpower_ticks_remaining > 0

    gain_willpower!(1)
    update(willpower_ticks: willpower_ticks_remaining - 1)
  end

  # Risk choices
  def risk?
    risk_chosen && !risk_chosen.empty?
  end
  alias has_risk? risk?

  # Special ability flags
  def used_wildcard?
    !!self[:done_wildcard]
  end

  def used_extreme?
    !!self[:done_extreme]
  end

  def can_use_wildcard?
    !used_wildcard?
  end

  # Status effects
  def injured?
    !!injured
  end

  def warned?
    !!self[:warned]
  end

  def cursed?
    !!cursed
  end

  def vulnerable?
    !!vulnerable
  end

  def is_star?
    !!self[:is_star]
  end

  # Season mechanics
  def taking_bonus
    season_taking || 0
  end

  def giving_penalty
    season_giving || 0
  end

  # Score
  def current_score
    score || 0.0
  end

  def add_score!(amount)
    update(score: current_score + amount)
  end

  # Roll tracking
  def last_roll
    roll_result
  end

  def expected_roll
    expect_roll
  end

  def roll_bonus
    effort_bonus || 0
  end

  # Team
  def on_team?(team_name)
    team == team_name
  end

  def team_name
    if team == 'one'
      instance.team_name_one || 'Team 1'
    elsif team == 'two'
      instance.team_name_two || 'Team 2'
    else
      nil
    end
  end

  # Choice submission
  def submit_choice!(action_id:, risk: nil, target_id: nil, willpower: 0, task_id: nil)
    attrs = {
      action_chosen: action_id,
      effort_chosen: nil,
      risk_chosen: risk,
      action_target: target_id,
      willpower_to_spend: willpower.to_i,
      chosen_when: Time.now
    }
    attrs[:task_chosen] = task_id if task_id
    update(attrs)
  end

  def clear_choice!
    attrs = {
      action_chosen: nil,
      effort_chosen: nil,
      risk_chosen: nil,
      action_target: nil,
      willpower_to_spend: 0,
      roll_result: nil,
      expect_roll: nil,
      chosen_when: nil
    }
    attrs[:task_chosen] = nil
    update(attrs)
  end

  # Available actions for current round
  def available_actions
    return [] unless instance

    round = instance.current_round
    return [] unless round

    # Filter by role if applicable
    all_actions = round.available_actions
    return all_actions if role.nil? || role.empty?

    all_actions.select { |action| action.available_to_role?(role) }
  end

  # Favored skill tracking
  def used_favored?
    !!used_favored
  end

  def mark_favored_used!
    update(used_favored: true)
  end

  # ========================================
  # Branch Round Voting
  # ========================================

  def vote_for_branch!(branch_id)
    update(branch_vote: branch_id)
  end

  def voted_branch?
    !branch_vote.nil?
  end
  alias has_voted_branch? voted_branch?

  # ========================================
  # Rest Round Voting
  # ========================================

  def voted_continue?
    !!self[:voted_continue]
  end

  def vote_to_continue!
    update(voted_continue: true)
  end

  # ========================================
  # Free Roll Round (LLM-based)
  # ========================================

  def assess_used?
    !!assess_used
  end

  def use_assess!
    update(assess_used: true)
  end

  def reset_assess!
    update(assess_used: false)
  end

  def increment_action_count!
    update(action_count: (action_count || 0) + 1)
  end

  def total_actions
    action_count || 0
  end

  # ========================================
  # Help Mechanics (Advantage Dice)
  # ========================================

  def helping?
    effort_chosen == 'help' && !action_target.nil?
  end

  def being_helped_by
    return [] unless instance

    instance.participants.select do |p|
      p.helping? && p.action_target == id
    end
  end

  def helper_count
    being_helped_by.count
  end

  def advantage?
    helper_count > 0
  end
  alias has_advantage? advantage?

  def recovering?
    effort_chosen == 'recover'
  end

  # Display
  def display_name
    character&.full_name || "Participant #{id}"
  end

  def status_text
    if !active?
      'Inactive'
    elsif has_chosen?
      'Ready'
    else
      'Choosing'
    end
  end
end
