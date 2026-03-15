# frozen_string_literal: true

# Represents an active combat session in a room.
# Manages round progression, participant tracking, and combat state.
class Fight < Sequel::Model
  include StatusEnum
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  one_to_many :fight_participants
  one_to_many :fight_events
  one_to_many :fight_entry_delays
  one_to_many :large_monster_instances, class: :LargeMonsterInstance, key: :fight_id
  many_to_one :room

  status_enum :status, %w[input resolving narrative complete]
  INPUT_TIMEOUT_SECONDS = GameConfig::Timeouts::FIGHT_INPUT_TIMEOUT
  NPC_ONLY_TIMEOUT_SECONDS = GameConfig::Timeouts::FIGHT_NPC_ONLY_TIMEOUT
  STALE_TIMEOUT_SECONDS = GameConfig::Timeouts::FIGHT_STALE_TIMEOUT

  # Hex system migration date - fights after this use new system
  HEX_SYSTEM_MIGRATION_DATE = Time.new(2026, 2, 16, 0, 0, 0).freeze

  def validate
    super
    validates_presence [:room_id]
    validate_status_enum
  end

  def before_create
    super
    self.started_at ||= Time.now
    self.last_action_at ||= Time.now
    self.round_number ||= 1
    self.status ||= 'input'

    # Arena dimensions: battle map hex data is authoritative when present.
    # Fall back to room feet bounds, then defaults.
    if room && room.has_battle_map && room.room_hexes_dataset.any?
      max_hx = room.room_hexes_dataset.max(:hex_x) || 0
      max_hy = room.room_hexes_dataset.max(:hex_y) || 0
      self.arena_width = max_hx + 1
      self.arena_height = max_hy >= 2 ? (max_hy + 1) / 4 + 1 : 1
      self.arena_height = [self.arena_height, 1].max
    elsif room && room.min_x && room.max_x && room.min_y && room.max_y
      room_width = room.max_x - room.min_x
      room_height = room.max_y - room.min_y
      self.arena_width, self.arena_height = HexGrid.arena_dimensions_from_feet(room_width, room_height)
    else
      self.arena_width ||= 10
      self.arena_height ||= 10
    end

    reset_input_deadline!
  end

  # Check if any human (non-NPC) players are in the fight
  # @return [Boolean] true if at least one human player
  def has_human_participants?
    # Before save (no id yet), no participants exist
    return false unless id

    # Use _dataset to always query DB - avoids stale association cache
    # (fight_participants may be cached as empty from before participants were added)
    fight_participants_dataset.all.any? do |p|
      char = p.character_instance&.character
      char && !char.npc?
    end
  end
  alias human_participants? has_human_participants?

  # Calculate appropriate timeout based on participants
  # Uses shorter timeout for NPC-only fights to speed up AI combat
  # @return [Integer] timeout in seconds
  def effective_timeout_seconds
    has_human_participants? ? INPUT_TIMEOUT_SECONDS : NPC_ONLY_TIMEOUT_SECONDS
  end

  # Reset the input deadline based on participant composition
  def reset_input_deadline!
    self.input_deadline_at = Time.now + effective_timeout_seconds
  end

  # Check if input period has timed out
  def input_timed_out?
    input_deadline_at && Time.now > input_deadline_at
  end

  # Check if all participants have completed their input
  def all_inputs_complete?
    active_participants.all?(&:input_complete)
  end

  # Get participants who are still active in the fight.
  # A participant is inactive if:
  # - They're knocked out (HP reduced to 0)
  # - They fled/surrendered/withdrew (also sets is_knocked_out for simplicity)
  # - The fight ended and cleanup marked them as out
  #
  # Note: is_knocked_out is the universal "no longer participating" flag.
  # It gets set whenever a participant leaves the fight for any reason.
  def active_participants
    fight_participants_dataset.where(is_knocked_out: false)
  end

  # Active large-monster records for this fight.
  # Delve fights may set has_monster without using LargeMonsterInstance records.
  def active_large_monsters_dataset
    large_monster_instances_dataset.where(status: 'active')
  end

  def has_active_large_monster?
    active_large_monsters_dataset.any?
  end
  alias active_large_monster? has_active_large_monster?

  def active_large_monster
    active_large_monsters_dataset.first
  end

  # Check if a specific character instance is still active in this fight
  def participant_active?(character_instance_id)
    fight_participants_dataset
      .where(character_instance_id: character_instance_id, is_knocked_out: false)
      .any?
  end

  # Get participants who still need to provide input
  def participants_needing_input
    fight_participants_dataset.where(input_complete: false, is_knocked_out: false)
  end

  # Transition to resolution phase
  def advance_to_resolution!
    update(status: 'resolving', last_action_at: Time.now)
  end

  # Transition to narrative phase
  def advance_to_narrative!
    update(status: 'narrative', last_action_at: Time.now)
  end

  # Complete the current round and prepare for the next
  def complete_round!
    self.round_number += 1
    reset_participant_choices!
    reset_input_deadline!
    update(status: 'input', last_action_at: Time.now, round_started_at: Time.now)
  end

  # End the fight and mark all participants as finished
  def complete!
    self.status = 'complete'
    self.last_action_at = Time.now
    self.combat_ended_at = Time.now
    save_changes

    unless spar_mode?
      # Only mark as knocked out in real combat, not sparring
      fight_participants_dataset.where(is_knocked_out: false).update(is_knocked_out: true)
      reset_knockout_wake_timers!
    end

    # Clean up monster NPC instances so they don't wake up or linger
    cleanup_npc_instances! if has_monster

    # Clean up lit battlemap files
    DynamicLightingService.cleanup_fight_lighting(self)

    # Snap characters back to valid room positions — combat hex grids can extend
    # beyond the room's actual bounds (inflated grids for small rooms).
    clamp_participants_to_room_bounds!

    # Resume activity if this fight was spawned by an activity
    if activity_instance_id
      # Players win if any non-NPC participant was still standing when fight ended
      # (all participants get knocked out in complete!, so check HP > 0 before that)
      victory = fight_participants_dataset.where(is_npc: false).all.any? { |p| p.current_hp.to_i > 0 }
      ActivityCombatService.on_fight_complete(self, victory)
    end

    # Resume Auto-GM session loop if this fight belongs to an active Auto-GM session.
    begin
      if defined?(AutoGmSession) && defined?(AutoGm::AutoGmSessionService)
        auto_session = AutoGmSession.where(current_fight_id: id, status: 'combat').first
        if auto_session
          player_standing = fight_participants_dataset
                            .eager(character_instance: :character)
                            .all
                            .any? do |participant|
            ci = participant.character_instance
            ci && !ci.character&.npc? && participant.current_hp.to_i > 0
          end

          result = player_standing ? :victory : :defeat
          AutoGm::AutoGmSessionService.process_combat_complete(auto_session, self, result)
        end
      end
    rescue StandardError => e
      warn "[Fight] Auto-GM completion callback failed for fight #{id}: #{e.message}"
    end
  end

  # Snap any participant whose character ended up outside room bounds back to a
  # valid position.  Combat hex grids may be larger than the room (small-room
  # inflation) so characters can drift beyond the true room polygon.
  def clamp_participants_to_room_bounds!
    fight_participants_dataset.where(is_npc: false).eager(:character_instance).each do |p|
      ci = p.character_instance
      next unless ci

      # Skip if already valid
      next if ci.within_room_bounds?

      ci.move_to_valid_position(ci.x || 0.0, ci.y || 0.0, ci.z, snap_to_valid: true)
    end
  rescue StandardError => e
    warn "[Fight] Failed to clamp positions for fight #{id}: #{e.message}"
  end

  # Reset wake timers for all knocked-out PC participants in this fight
  # Called when combat ends so player characters can wake up after the fight
  def reset_knockout_wake_timers!
    # Eager load character_instance to avoid N+1 queries
    fight_participants_dataset.where(is_knocked_out: true, is_npc: false).eager(:character_instance).each do |participant|
      char_inst = participant.character_instance
      next unless char_inst&.unconscious?

      PrisonerService.reset_wake_timers!(char_inst)
    end
  end

  # Clean up NPC character instances after fight ends
  # Monster NPCs are temporary — mark them dead so they don't wake up or linger
  def cleanup_npc_instances!
    fight_participants_dataset.where(is_npc: true).eager(:character_instance).each do |participant|
      char_inst = participant.character_instance
      next unless char_inst

      char_inst.update(status: 'dead', online: false, can_wake_at: nil, auto_wake_at: nil)
    end
  end

  # Check if fight is still ongoing
  def ongoing?
    %w[input resolving narrative].include?(status)
  end

  # Check if this fight uses the new hex system
  # Old fights (before migration) keep old mechanics
  # New fights use scaled distances, boolean cover, concealed
  #
  # @return [Boolean]
  def uses_new_hex_system?
    created_at > HEX_SYSTEM_MIGRATION_DATE
  end

  # === Spar Mode ===
  # Sparring matches track "touches" instead of HP damage

  # Check if this is a sparring match
  def spar_mode?
    mode == 'spar'
  end

  # Get the winner of a spar match (the one with fewer touches)
  def spar_winner
    return nil unless spar_mode? && complete?

    fight_participants.reject { |p| p.touch_count >= p.max_hp }.first
  end

  # Get the loser of a spar match (the one who reached max touches)
  def spar_loser
    return nil unless spar_mode? && complete?

    fight_participants.find { |p| p.touch_count >= p.max_hp }
  end

  # Check if fight is in input phase
  def accepting_input?
    status == 'input'
  end

  # === Round Locking ===
  # Prevents choice changes during resolution

  # Check if round is locked (resolution in progress)
  def round_locked?
    !!round_locked
  end

  # Lock the round when resolution begins
  def lock_round!
    update(round_locked: true)
  end

  # Unlock the round when new round starts
  def unlock_round!
    update(round_locked: false)
  end

  # Get the winner if fight is complete with one standing
  def winner
    return nil unless complete?

    # complete! marks participants knocked out to close the fight, so
    # winner must be derived from remaining HP instead of is_knocked_out.
    standing = fight_participants_dataset.all.select { |p| p.current_hp.to_i > 0 }
    standing.first if standing.count == 1
  end

  # Check if fight is stale (no activity for 15 minutes)
  def stale?
    return false unless ongoing?

    last_activity = last_action_at || started_at || created_at
    Time.now - last_activity > STALE_TIMEOUT_SECONDS
  end

  # Check if fight should end (0 or 1 active participants, side eliminated, or spar victory)
  def should_end?
    return false unless ongoing?

    if spar_mode?
      # In spar mode, fight ends when anyone reaches max touches
      fight_participants.any? { |p| p.touch_count >= p.max_hp }
    else
      # End if ≤1 active OR if any side is fully eliminated (knocked out/surrendered)
      active_participants.count <= 1 || side_eliminated?
    end
  end

  # Check if all participants on any side are knocked out/surrendered
  def side_eliminated?
    sides = fight_participants.map(&:side).uniq
    return false if sides.size < 2 # Need at least 2 sides for elimination

    sides.any? do |side|
      fight_participants_dataset.where(side: side).all.all?(&:is_knocked_out)
    end
  end

  # Get the winning side (the one that's NOT fully eliminated)
  def winning_side
    return nil unless side_eliminated?

    sides = fight_participants.map(&:side).uniq
    sides.find do |side|
      !fight_participants_dataset.where(side: side).all.all?(&:is_knocked_out)
    end
  end

  # Check if fight needs cleanup (stale or should end)
  def needs_cleanup?
    stale? || should_end?
  end

  # Class method to find all fights needing cleanup
  def self.needing_cleanup
    where(status: %w[input resolving narrative]).all.select(&:needs_cleanup?)
  end

  CLEANUP_STALE_HOURS = 24  # Hours before a fight is considered abandonded

  # Class method to clean up very stale fights (older than 24 hours)
  # These are fights that were never properly completed - delete them entirely
  def self.cleanup_stale_fights!
    stale_cutoff = Time.now - (CLEANUP_STALE_HOURS * 3600)
    stale_fights = where(status: %w[input resolving narrative])
                   .where { created_at < stale_cutoff }

    # Delete participants first (foreign key constraint)
    # Use select_map for efficient single-query ID extraction
    stale_fight_ids = stale_fights.select_map(:id)
    return 0 if stale_fight_ids.empty?

    FightParticipant.where(fight_id: stale_fight_ids).delete
    FightEvent.where(fight_id: stale_fight_ids).delete
    FightEntryDelay.where(fight_id: stale_fight_ids).delete if defined?(FightEntryDelay)

    # Delete the fights
    stale_fights.delete
  end

  # Class method to check if a participant is in any active fight
  # More reliable than checking individual fights
  def self.participant_in_active_fight?(character_instance_id)
    FightParticipant
      .where(character_instance_id: character_instance_id, is_knocked_out: false)
      .eager(:fight)
      .all
      .any? { |fp| fp.fight&.ongoing? }
  end

  # === Battle Map Generation Status ===

  # Check if fight is waiting for battle map generation
  # @return [Boolean]
  def awaiting_battle_map?
    !!battle_map_generating
  end

  # Check if combat input is allowed
  # Block input during map generation
  # @return [Boolean]
  def can_accept_combat_input?
    accepting_input? && !awaiting_battle_map?
  end

  # Mark generation as started
  def start_battle_map_generation!
    update(battle_map_generating: true)
  end

  # Mark generation as complete
  def complete_battle_map_generation!
    update(battle_map_generating: false)
  end

  private

  # Reset all participant choices for the new round
  def reset_participant_choices!
    fight_participants.each do |p|
      next if p.is_knocked_out

      p.update(
        input_complete: false,
        input_stage: 'main_menu',
        main_action: 'attack',
        tactical_action: nil,
        # New tactic system fields
        tactic_choice: nil,
        tactic_target_participant_id: nil,
        movement_completed_segment: nil,
        movement_action: 'stand_still',
        target_participant_id: nil,
        movement_target_participant_id: nil,
        pending_damage_total: 0,
        incoming_attack_count: 0,
        willpower_dice_used_this_round: 0,
        # Battle map combat tracking - reset each round
        acted_this_round: false,
        moved_this_round: false
        # Note: ignore_hazard_avoidance is NOT reset - it's a persistent toggle
      )
      # Grant willpower for round progression: +0.5 per round, max 3.0
      new_willpower = [p.willpower_dice.to_f + 0.5, 3.0].min
      p.update(willpower_dice: new_willpower)
    end

    # Unlock round for new input phase
    unlock_round!
  end
end
