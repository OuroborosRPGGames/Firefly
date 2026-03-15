# frozen_string_literal: true

# Skip loading if table doesn't exist
return unless DB.table_exists?(:activity_instances)

class ActivityInstance < Sequel::Model(:activity_instances)
  unrestrict_primary_key
  set_primary_key :id
  plugin :validation_helpers
  plugin :timestamps

  # Relationships
  many_to_one :room
  many_to_one :event
  many_to_one :initiator, class: :Character, key: :initiator_id
  many_to_one :defender, class: :Character, key: :defender_id

  # Deferred associations (memoized to avoid N+1 queries)
  def activity
    @activity ||= Activity[activity_id]
  end

  def participants_dataset
    ActivityParticipant.where(instance_id: id)
  end

  def participants
    participants_dataset.all
  end

  def validate
    super
    validates_presence [:activity_id, :room_id]
  end

  # Status checks
  def running?
    running == true
  end

  def in_setup?
    # setup_stage semantics:
    # 0=created, 1=locked/setup, 2=started, 3=completed
    !setup_stage.nil? && setup_stage < 2
  end

  def completed?
    !running? || setup_stage == 3
  end

  def test_run?
    test_run == true || admin_test == true
  end

  def emergency?
    is_emergency == true
  end

  # Current round
  def current_round
    activity.round_at(rounds_done + 1, branch)
  end

  def current_round_number
    rounds_done + 1
  end

  def total_rounds
    rcount || activity.total_rounds
  end

  def progress_percentage
    return 0 if total_rounds.zero?

    ((rounds_done.to_f / total_rounds) * 100).round
  end

  # Participants
  def active_participants
    participants_dataset.where(continue: true)
  end

  def team_one_participants
    active_participants.where(team: 'one')
  end

  def team_two_participants
    active_participants.where(team: 'two')
  end

  def participant_for(character_instance)
    participants_dataset.where(char_id: character_instance.character_id).first
  end

  def has_participant?(character_instance)
    !participant_for(character_instance).nil?
  end

  # Scoring
  def team_one_total
    team_one_score || 0
  end

  def team_two_total
    team_two_score || 0
  end

  def enemy_total
    enemy_score || 0
  end

  def leading_team
    return nil if team_one_total == team_two_total

    team_one_total > team_two_total ? 'one' : 'two'
  end

  # Difficulty
  def current_difficulty
    base = this_enemy || 10
    base += random_difficulty || 0
    base += char_difficulty || 0
    base += (inc_difficulty || 0).to_i
    base
  end

  # Difficulty modifier (accumulated from failure consequences)
  def difficulty_modifier
    inc_difficulty || 0
  end

  def add_difficulty_modifier!(amount = 1)
    update(inc_difficulty: difficulty_modifier + amount)
  end

  # Finale modifier (accumulated NPC level increase for final battle)
  def finale_npc_modifier
    finale_modifier || 0
  end

  def add_finale_modifier!(amount = 1)
    update(finale_modifier: finale_npc_modifier + amount)
  end

  # Input tracking
  def all_ready?
    return false if active_participants.empty?

    # Use has_chosen? which handles recovery and help correctly
    active_participants.all?(&:has_chosen?)
  end

  def waiting_for_input?
    running? && !all_ready?
  end

  def time_since_last_round
    return nil unless last_round

    Time.now - last_round
  end

  def input_timed_out?(timeout_seconds = nil)
    # Use round-specific timeout or default 8 minutes
    timeout = timeout_seconds || current_round&.round_timeout || 480
    time = time_since_round_start
    return false unless time

    time >= timeout
  end

  def time_since_round_start
    return nil unless round_started_at

    Time.now - round_started_at
  end

  # ========================================
  # Post-Resolution Round Hold
  # ========================================

  # The :current_round integer column is repurposed as a hold-until epoch
  # timestamp for delayed round transitions. Round lookup uses
  # rounds_done + branch instead. Use the hold-timer methods below
  # rather than accessing :current_round directly.
  HOLD_TIMER_COLUMN = :current_round
  HOLD_TIMER_CLEARED = 0

  def post_resolution_hold_until
    raw = self[:current_round]
    return nil unless raw && raw.to_i.positive?

    Time.at(raw.to_i)
  end

  def post_resolution_hold_pending?
    !post_resolution_hold_until.nil?
  end

  def post_resolution_hold_active?
    hold_until = post_resolution_hold_until
    return false unless hold_until

    Time.now < hold_until
  end

  def post_resolution_hold_due?
    hold_until = post_resolution_hold_until
    return false unless hold_until

    Time.now >= hold_until
  end

  def post_resolution_hold_remaining_seconds
    hold_until = post_resolution_hold_until
    return 0 unless hold_until

    remaining = (hold_until - Time.now).ceil
    remaining.positive? ? remaining : 0
  end

  def queue_post_resolution_hold!(seconds)
    hold_until = Time.now + seconds.to_i
    update(HOLD_TIMER_COLUMN => hold_until.to_i)
    hold_until
  end

  def clear_post_resolution_hold!
    update(HOLD_TIMER_COLUMN => HOLD_TIMER_CLEARED)
  end

  # ========================================
  # Combat Round Integration
  # ========================================

  # Check if activity is paused for a fight
  def paused_for_combat?
    !paused_for_fight_id.nil?
  end

  def active_fight
    return nil unless paused_for_fight_id

    Fight[paused_for_fight_id]
  end

  def pause_for_fight!(fight)
    update(paused_for_fight_id: fight.id)
  end

  def resume_from_fight!
    update(paused_for_fight_id: nil)
  end

  # ========================================
  # Persuade Round Tracking
  # ========================================

  def increment_persuade_attempts!
    update(persuade_attempts: (persuade_attempts || 0) + 1)
  end

  def reset_persuade_attempts!
    update(persuade_attempts: 0)
  end

  # ========================================
  # Round Timing
  # ========================================

  def start_round_timer!
    update(round_started_at: Time.now)
  end

  # ========================================
  # Branch Voting (Branch Rounds)
  # ========================================

  def branch_votes
    votes = {}
    active_participants.each do |p|
      next unless p.branch_vote

      votes[p.branch_vote] ||= 0
      votes[p.branch_vote] += 1
    end
    votes
  end

  def majority_branch_vote
    votes = branch_votes
    return nil if votes.empty?

    total = active_participants.count
    # Find first option with more than half the votes (strict majority)
    votes.each do |branch_id, count|
      return branch_id if count > (total / 2.0)
    end

    # No majority yet
    nil
  end

  def all_voted_branch?
    active_participants.all? { |p| !p.branch_vote.nil? }
  end

  # ========================================
  # Rest Round Voting
  # ========================================

  def continue_votes
    active_participants.where(voted_continue: true).count
  end

  def majority_wants_continue?
    total = active_participants.count
    return false if total.zero?

    continue_votes > (total / 2.0)
  end

  def reset_continue_votes!
    # Batch update instead of N individual queries
    ActivityParticipant.where(id: active_participants.select(:id)).update(voted_continue: false)
  end

  # Round advancement
  def advance_round!
    update(
      rounds_done: rounds_done + 1,
      last_round: Time.now,
      round_started_at: Time.now,
      HOLD_TIMER_COLUMN => HOLD_TIMER_CLEARED
    )
    reset_participant_choices!
  end

  def reset_participant_choices!
    # Batch update instead of N individual queries
    ActivityParticipant.where(id: active_participants.select(:id)).update(
      action_chosen: nil,
      effort_chosen: nil,
      risk_chosen: nil,
      roll_result: nil,
      expect_roll: nil,
      chosen_when: nil,
      branch_vote: nil,
      voted_continue: false,
      assess_used: false,
      action_count: 0,
      task_chosen: nil,
      action_target: nil,
      willpower_to_spend: nil,
      has_emoted: false
    )
  end

  # Branching
  def switch_branch!(new_branch)
    update(branch: new_branch, branch_round_at: rounds_done)
  end

  def on_main_branch?
    branch == 0
  end

  # Creature aspects (special abilities)
  def active_aspects
    aspects = []
    aspects << :dragon if dragon
    aspects << :phoenix if phoenix
    aspects << :unicorn if unicorn
    aspects << :basilisk if basilisk
    aspects << :hydra if hydra
    aspects << :wraith if wraith
    aspects << :griffin if griffin
    aspects << :gorgon if gorgon
    aspects << :sphinx if sphinx
    aspects
  end

  def has_aspect?(aspect)
    send(aspect) == true
  end

  # Complete the activity
  def complete!(success: true)
    update(
      running: false,
      setup_stage: 3,
      completed_at: Time.now,
      HOLD_TIMER_COLUMN => HOLD_TIMER_CLEARED
    )

    # Record result if this is a real run
    unless test_run?
      activity.update(
        wins: (activity.wins || 0) + (success ? 1 : 0),
        losses: (activity.losses || 0) + (success ? 0 : 1),
        last_run: Time.now
      )
    end
  end

  # Display
  def status_text
    if completed?
      'Completed'
    elsif in_setup?
      'Setting Up'
    elsif waiting_for_input?
      'Waiting for Input'
    else
      'In Progress'
    end
  end

  def display_name
    "#{activity.display_name} (#{status_text})"
  end

  # ========================================
  # Remote Observers (Support/Oppose)
  # ========================================

  def remote_observers_dataset
    ActivityRemoteObserver.where(activity_instance_id: id)
  end

  def remote_observers
    remote_observers_dataset.all
  end

  def supporters
    remote_observers_dataset.active.supporters.all
  end

  def opposers
    remote_observers_dataset.active.opposers.all
  end

  def remote_observer_for(character_instance)
    remote_observers_dataset.active.where(character_instance_id: character_instance.id).first
  end

  def has_remote_observer?(character_instance)
    !remote_observer_for(character_instance).nil?
  end

  # Broadcast to all active remote observers
  def broadcast_to_observers(message, html: nil)
    remote_observers_dataset.active.each do |obs|
      BroadcastService.to_character(
        obs.character_instance,
        { content: message, html: html },
        type: :observer_feed
      )
    end
  end

  # Clear all observer actions (called at round end)
  def clear_observer_actions!
    remote_observers_dataset.update(
      action_type: nil,
      action_target_id: nil,
      action_secondary_target_id: nil,
      action_message: nil,
      action_submitted_at: nil
    )
  end
end
