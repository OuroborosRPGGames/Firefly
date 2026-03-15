# frozen_string_literal: true

# DelveParticipant tracks characters participating in a delve.
# Note: studied_monsters and cleared_blockers are JSONB columns - Sequel handles
# these natively through the pg_json extension, no serialization plugin needed.
class DelveParticipant < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :delve
  many_to_one :character_instance
  many_to_one :current_delve_room, class: :DelveRoom

  status_enum :status, %w[active extracted dead fled]

  def validate
    super
    validates_presence [:delve_id, :character_instance_id]
    validates_unique [:delve_id, :character_instance_id]
    validate_status_enum
  end

  def before_save
    super
    self.status ||= 'active'
    self.loot_collected ||= 0
    self.rooms_explored ||= 0
    self.joined_at ||= Time.now
    self.willpower_dice ||= 0
    self.studied_monsters ||= []
    self.cleared_blockers ||= []
    self.passed_traps ||= []
    self.trap_observation_states ||= {} if respond_to?(:trap_observation_states=)
  end

  def extract!
    update(status: 'extracted', extracted_at: Time.now)
  end

  def die!
    update(status: 'dead')
  end

  def flee!
    update(status: 'fled')
  end

  def add_loot!(value)
    update(loot_collected: (loot_collected || 0) + value)
  end

  def explore_room!
    update(rooms_explored: (rooms_explored || 0) + 1)
  end

  def move_to!(delve_room)
    update(current_delve_room_id: delve_room.id)
    explore_room! unless delve_room.explored?
    delve_room.explore!
  end

  # ====== Time Tracking ======

  # Get time remaining in fractional minutes (for display)
  def time_remaining
    return nil unless delve&.time_limit_minutes

    limit_seconds = delve.time_limit_minutes * 60
    remaining_seconds = limit_seconds - (time_spent_seconds || 0)
    [remaining_seconds / 60.0, 0].max.round(1)
  end

  # Get time remaining in whole seconds
  def time_remaining_seconds
    return nil unless delve&.time_limit_minutes

    limit_seconds = delve.time_limit_minutes * 60
    [limit_seconds - (time_spent_seconds || 0), 0].max
  end

  # Check if time has expired
  def time_expired?
    remaining = time_remaining_seconds
    remaining && remaining <= 0
  end

  # Spend time in minutes (legacy interface, converts to seconds)
  def spend_time!(minutes)
    spend_time_seconds!(minutes * 60)
  end

  # ====== Room & Level Management ======

  # Alias for current_delve_room for clearer code
  def current_room
    current_delve_room
  end

  # Move to a specific room
  def move_to_room!(room)
    update(
      current_delve_room_id: room.id,
      current_level: room.level
    )

    unless room.explored?
      explore_room!
      room.explore!
    end
  end

  # Descend to the next level
  def descend_level!
    next_level = (current_level || 1) + 1

    # Generate next level if needed
    if next_level > (delve.levels_generated || 1)
      delve.generate_next_level!
    end

    entrance = delve.entrance_room(next_level)
    move_to_room!(entrance) if entrance

    next_level
  end

  # ====== Combat & Damage Tracking ======

  # Add a monster kill
  def add_kill!
    update(monsters_killed: (monsters_killed || 0) + 1)
  end

  # Record a trap trigger
  def add_trap_trigger!
    update(traps_triggered: (traps_triggered || 0) + 1)
  end

  # Take damage
  def take_damage!(amount)
    update(damage_taken: (damage_taken || 0) + amount)
  end

  # Get total damage taken
  def total_damage
    damage_taken || 0
  end

  # ====== HP Management ======
  # HP is stored on character_instance.health (the one true HP pool).

  def current_hp
    character_instance&.health || GameConfig::Mechanics::DEFAULT_HP[:current]
  end

  def max_hp
    character_instance&.max_health || GameConfig::Mechanics::DEFAULT_HP[:max]
  end

  # Take HP damage and gain willpower dice
  def take_hp_damage!(amount)
    ci = character_instance
    return 0 unless ci

    new_hp = [ci.health - amount, 0].max
    ci.update(health: new_hp)

    # Gain willpower from taking damage (same as combat system)
    if amount > 0
      wp_config = GameConfig::Mechanics::WILLPOWER
      new_wp = [(willpower_dice || 0) + (amount * wp_config[:gain_per_hp_lost]), wp_config[:max_dice]].min
      update(damage_taken: (damage_taken || 0) + amount, willpower_dice: new_wp.floor)
    else
      update(damage_taken: (damage_taken || 0) + amount)
    end

    handle_defeat! if new_hp <= 0
    new_hp
  end

  # Heal HP
  # @param amount [Integer, nil] amount to heal, nil for full heal
  def heal!(amount = nil)
    ci = character_instance
    return unless ci

    if amount.nil?
      ci.update(health: ci.max_health)
    else
      new_hp = [ci.health + amount, ci.max_health].min
      ci.update(health: new_hp)
    end
  end

  # Check if defeated (HP <= 0)
  def defeated?
    current_hp <= 0
  end

  # Check if at full health
  def full_health?
    current_hp >= max_hp
  end

  # ====== Willpower ======

  # Add willpower dice (from Focus action)
  def add_willpower!(count = 1)
    max_wp = GameConfig::Mechanics::WILLPOWER[:max_dice]
    new_total = [(willpower_dice || 0) + count, max_wp].min
    update(willpower_dice: new_total)
  end

  # Use willpower dice
  # @return [Boolean] true if dice was available and used
  def use_willpower!
    return false unless (willpower_dice || 0) > 0

    update(willpower_dice: willpower_dice - 1)
    true
  end

  # ====== Study System ======

  # Add studied monster type (from Study action)
  def add_study!(monster_type)
    monsters = studied_monsters || []
    return if monsters.include?(monster_type)

    update(studied_monsters: monsters + [monster_type])
  end

  # Check if monster type has been studied
  def has_studied?(monster_type)
    (studied_monsters || []).include?(monster_type)
  end

  # Get study bonus (+2 if studied)
  def study_bonus_for(monster_type)
    has_studied?(monster_type) ? 2 : 0
  end

  # ====== Blocker Tracking ======

  # Mark a blocker as cleared by this participant
  def mark_blocker_cleared!(blocker_id)
    blockers = cleared_blockers || []
    return if blockers.include?(blocker_id)

    update(cleared_blockers: blockers + [blocker_id])
  end

  # Check if participant has cleared a blocker
  def has_cleared_blocker?(blocker_id)
    (cleared_blockers || []).include?(blocker_id)
  end

  # ====== Trap Passage Tracking ======

  # Mark a trap as passed through by this participant
  def mark_trap_passed!(trap_id)
    traps = passed_traps || []
    return if traps.include?(trap_id)

    update(passed_traps: traps + [trap_id])
  end

  # Check if participant has passed through a trap before (makes it easier)
  def has_passed_trap?(trap_id)
    (passed_traps || []).include?(trap_id)
  end

  # Get trap observation state for a specific trap.
  # @return [Hash, nil] state hash with "start" and "length", or nil
  def trap_observation_state(trap_id)
    return nil unless respond_to?(:trap_observation_states)

    states = trap_observation_states || {}
    states[trap_id.to_s]
  end

  # Persist trap observation state for a specific trap.
  # @param trap_id [Integer]
  # @param start [Integer]
  # @param length [Integer]
  def set_trap_observation_state!(trap_id, start:, length:)
    return unless respond_to?(:trap_observation_states=)

    states = (trap_observation_states || {}).dup
    states[trap_id.to_s] = { 'start' => start.to_i, 'length' => length.to_i }
    update(trap_observation_states: states)
  end

  # Clear stored observation state for a trap, or all traps if trap_id is nil.
  # @param trap_id [Integer, nil]
  def clear_trap_observation_state!(trap_id = nil)
    return unless respond_to?(:trap_observation_states=)

    if trap_id
      states = (trap_observation_states || {}).dup
      states.delete(trap_id.to_s)
      update(trap_observation_states: states)
    else
      update(trap_observation_states: {})
    end
  end

  # ====== Time Management (Seconds) ======

  # Spend time in seconds
  # @return [:ok, :time_expired]
  def spend_time_seconds!(seconds)
    new_seconds = (time_spent_seconds || 0) + seconds
    update(time_spent_seconds: new_seconds)

    if time_expired?
      handle_timeout!
      return :time_expired
    end

    :ok
  end

  # ====== Accessibility ======

  # Check if participant is in accessibility mode
  def accessibility_mode?
    character_instance&.character&.user&.accessibility_mode == true
  end

  # ====== Defeat & Timeout Handling ======

  # Handle defeat - lose 50% loot and mark as dead
  def handle_defeat!
    apply_exit_penalty!('dead')
  end

  # Handle timeout - lose 50% loot and mark as fled
  def handle_timeout!
    apply_exit_penalty!('fled')
  end

  private

  # Shared exit logic: deduct loot penalty, set exit status, restore character room,
  # and release pooled rooms if no active participants remain.
  # @param exit_status [String] 'dead' or 'fled'
  # @return [Integer] loot lost
  def apply_exit_penalty!(exit_status)
    # Idempotent guard: exit penalties should only apply once.
    return 0 unless active?

    penalty = GameSetting.get('delve_defeat_loot_penalty')&.to_f || 0.5
    loot_lost = ((loot_collected || 0) * penalty).to_i

    update(
      loot_collected: (loot_collected || 0) - loot_lost,
      status: exit_status
    )

    # Return character to a safe non-temporary room.
    ci = character_instance
    if ci
      restore_room = nil
      if pre_delve_room_id
        room = Room[pre_delve_room_id]
        restore_room = room if room && !room.temporary?
      end
      restore_room ||= ci.safe_fallback_room
      ci.update(current_room_id: restore_room.id) if restore_room
    end

    # Only release pooled delve rooms if no active participants remain.
    if defined?(TemporaryRoomPoolService) && delve && delve.active_participants.empty?
      TemporaryRoomPoolService.release_delve_rooms(delve)
      if delve.respond_to?(:fail!) && delve.respond_to?(:status) &&
         !%w[completed abandoned failed].include?(delve.status)
        delve.fail!
      end
    end

    loot_lost
  end
end
