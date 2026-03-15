# frozen_string_literal: true

# Records individual events during combat for narrative generation.
# Events include attacks, hits, misses, movement, and knockouts.
class FightEvent < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :fight
  many_to_one :actor_participant, class: :FightParticipant, key: :actor_participant_id
  many_to_one :target_participant, class: :FightParticipant, key: :target_participant_id

  EVENT_TYPES = %w[
    attack hit miss move weapon_switch knockout death out_of_range damage_applied
    monster_attack monster_shake_off monster_hit weak_point_hit monster_attack_miss
    monster_segment_attack monster_segment_damage monster_weak_point_attack monster_attack_failed
    monster_segment_destroyed monster_collapsed monster_defeated monster_turn monster_move
    segment_destroyed weak_point_attack attacker_flung player_thrown_off
    fight_ended_peacefully shot_blocked movement_blocked hazard_damage
    ability ability_start ability_hit ability_heal ability_no_target ability_execute ability_execute_bonus
    ability_lifesteal ability_split_damage ability_forced_movement ability_knockdown
    status_applied status_tick damage_tick healing_tick process_ticks movement movement_step
    burning_spread attack_redirected action round_damage_summary
    flee_success flee_failed surrender
  ].freeze
  WEAPON_TYPES = %w[melee ranged unarmed natural_melee natural_ranged].freeze

  def validate
    super
    validates_presence [:fight_id, :round_number, :segment, :event_type]
    validates_includes EVENT_TYPES, :event_type if event_type
    validates_includes WEAPON_TYPES, :weapon_type if weapon_type
  end

  # Parse the details JSON into a hash
  def details_hash
    return {} unless details

    case details
    when Hash
      details
    when String
      JSON.parse(details, symbolize_names: true)
    else
      {}
    end
  rescue JSON::ParserError
    {}
  end

  # Get actor name
  def actor_name
    actor_participant&.character_name || 'Unknown'
  end

  # Get target name
  def target_name
    target_participant&.character_name || 'Unknown'
  end

  # Check if this was a successful attack
  def hit?
    event_type == 'hit'
  end

  # Check if this was a missed attack
  def miss?
    event_type == 'miss'
  end

  # Check if this was a movement event
  def movement?
    event_type == 'move'
  end

  # Check if this was a knockout
  def knockout?
    event_type == 'knockout'
  end
end
