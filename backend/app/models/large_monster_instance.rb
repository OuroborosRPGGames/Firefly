# frozen_string_literal: true

# An active monster in a fight.
# Tracks position, HP, status, and links to segment instances.
class LargeMonsterInstance < Sequel::Model(:monster_instances)
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :monster_template
  many_to_one :fight
  one_to_many :monster_segment_instances
  one_to_many :monster_mount_states

  status_enum :status, %w[active collapsed defeated]

  def validate
    super
    validates_presence [:monster_template_id, :fight_id, :current_hp, :max_hp]
    validate_status_enum
  end

  # Get all hexes this monster occupies
  # @return [Array<Array<Integer>>] Array of [x, y] pairs
  def occupied_hexes
    monster_template.occupied_hexes_at(center_hex_x, center_hex_y)
  end

  # Check if a hex is occupied by this monster
  # @param hex_x [Integer]
  # @param hex_y [Integer]
  # @return [Boolean]
  def occupies_hex?(hex_x, hex_y)
    occupied_hexes.include?([hex_x, hex_y])
  end

  # Get segment instance at a specific hex position
  # @param hex_x [Integer]
  # @param hex_y [Integer]
  # @return [MonsterSegmentInstance, nil]
  def segment_at_hex(hex_x, hex_y)
    monster_segment_instances.find do |seg|
      template = seg.monster_segment_template
      seg_pos = template.position_at(center_hex_x, center_hex_y)
      seg_pos == [hex_x, hex_y]
    end
  end

  # Get segment instance closest to a hex position
  # @param hex_x [Integer]
  # @param hex_y [Integer]
  # @return [MonsterSegmentInstance, nil]
  def closest_segment_to(hex_x, hex_y)
    active_segments.min_by do |seg|
      template = seg.monster_segment_template
      seg_pos = template.position_at(center_hex_x, center_hex_y)
      dx = seg_pos[0] - hex_x
      dy = seg_pos[1] - hex_y
      Math.sqrt(dx * dx + dy * dy)
    end
  end

  # Get current HP as a percentage
  # @return [Float]
  def current_hp_percent
    return 0 if max_hp.zero?

    (current_hp.to_f / max_hp * 100).round(1)
  end

  # Check if monster is defeated (below defeat threshold)
  # @return [Boolean]
  def defeated?
    current_hp_percent <= monster_template.defeat_threshold_percent
  end

  # Get all segments that aren't destroyed
  # @return [Array<MonsterSegmentInstance>]
  def active_segments
    monster_segment_instances.reject { |s| s.status == 'destroyed' }
  end

  # Get segments that can still attack
  # @return [Array<MonsterSegmentInstance>]
  def segments_that_can_attack
    active_segments.select(&:can_attack)
  end

  # Get all currently mounted participants
  # @return [Array<FightParticipant>]
  def mounted_participants
    monster_mount_states.map(&:fight_participant).compact
  end

  # Get mount states for participants who are NOT clinging (vulnerable to shake-off)
  # @return [Array<MonsterMountState>]
  def vulnerable_mount_states
    monster_mount_states.reject { |ms| ms.mount_action_is_cling? }
  end

  # Get the weak point segment instance
  # @return [MonsterSegmentInstance, nil]
  def weak_point_segment
    monster_segment_instances.find { |s| s.monster_segment_template.is_weak_point }
  end

  # Trigger collapse state
  def collapse!
    update(status: 'collapsed')
  end

  # Mark monster as defeated
  def defeat!
    update(status: 'defeated')
  end

  # Get display name
  # @return [String]
  def display_name
    monster_template.name
  end

  # Move monster to new center position
  # @param new_x [Integer]
  # @param new_y [Integer]
  def move_to(new_x, new_y)
    update(center_hex_x: new_x, center_hex_y: new_y)
  end

  # Turn monster to face a specific direction
  # Also rotates all mounted participants
  # @param direction [Integer] 0-5 hex direction
  def turn_to(direction)
    MonsterHexService.new(self).turn_monster(direction)
  end

  # Turn monster to face a target position
  # Also rotates all mounted participants
  # @param target_x [Integer]
  # @param target_y [Integer]
  def turn_towards(target_x, target_y)
    MonsterHexService.new(self).turn_towards(target_x, target_y)
  end

  # Get direction to face a target hex
  # @param target_x [Integer]
  # @param target_y [Integer]
  # @return [Integer] 0-5
  def direction_to(target_x, target_y)
    MonsterHexService.new(self).calculate_facing_towards(target_x, target_y)
  end

  # Apply damage to total HP (called after segment damage)
  # @param damage [Integer]
  # @return [Integer] HP remaining
  def apply_damage!(damage)
    new_hp = [current_hp - damage, 0].max
    update(current_hp: new_hp)

    if defeated?
      defeat!
    end

    new_hp
  end

  # Reset segment attacks for new round
  def reset_for_new_round!
    monster_segment_instances.each do |seg|
      seg.update(
        attacks_remaining_this_round: seg.monster_segment_template.attacks_per_round,
        last_attack_segment: nil
      )
    end
  end
end
