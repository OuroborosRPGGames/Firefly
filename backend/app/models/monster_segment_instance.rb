# frozen_string_literal: true

# Runtime state of a monster body part during combat.
# Tracks current HP, status, and attack state.
class MonsterSegmentInstance < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :large_monster_instance, class: :LargeMonsterInstance, key: :large_monster_instance_id
  many_to_one :monster_segment_template

  status_enum :status, %w[healthy damaged broken destroyed]

  def validate
    super
    validates_presence [:large_monster_instance_id, :monster_segment_template_id, :current_hp, :max_hp]
    validate_status_enum
  end

  # Get current HP as percentage
  # @return [Float]
  def hp_percent
    return 0 if max_hp.zero?

    (current_hp.to_f / max_hp * 100).round(1)
  end

  # Update status based on current HP percentage
  def update_status_from_hp!
    new_status = case hp_percent
                 when 0 then 'destroyed'
                 when 0.01..25 then 'broken'
                 when 25.01..50 then 'damaged'
                 else 'healthy'
                 end

    new_can_attack = new_status != 'destroyed'

    update(status: new_status, can_attack: new_can_attack)
  end

  # Apply damage to this segment
  # @param damage [Integer]
  # @return [Hash] { segment_hp_lost: Integer, new_status: String }
  def apply_damage!(damage)
    hp_before = current_hp
    new_hp = [current_hp - damage, 0].max
    update(current_hp: new_hp)

    update_status_from_hp!

    {
      segment_hp_lost: hp_before - new_hp,
      new_status: status
    }
  end

  # Check if this segment can attack this round
  # @return [Boolean]
  def can_attack_this_round?
    can_attack && (attacks_remaining_this_round || 0) > 0
  end

  # Use one attack for this round
  def use_attack!
    remaining = (attacks_remaining_this_round || 0) - 1
    update(attacks_remaining_this_round: [remaining, 0].max)
  end

  # Record that this segment attacked at a specific segment number
  # @param segment_number [Integer] 1-100
  def record_attack!(segment_number)
    use_attack!
    update(last_attack_segment: segment_number)
  end

  # Get the template name
  # @return [String]
  def name
    monster_segment_template.name
  end

  # Get the segment type
  # @return [String]
  def segment_type
    monster_segment_template.segment_type
  end

  # Check if this is the weak point
  # @return [Boolean]
  def weak_point?
    monster_segment_template.is_weak_point
  end

  # Check if this segment is required for mobility
  # @return [Boolean]
  def required_for_mobility?
    monster_segment_template.required_for_mobility
  end

  # Get hex position of this segment
  # @return [Array<Integer>] [x, y]
  def hex_position
    monster = large_monster_instance
    monster_segment_template.position_at(monster.center_hex_x, monster.center_hex_y)
  end

  # Roll damage for an attack from this segment
  # @return [Integer]
  def roll_damage
    monster_segment_template.roll_damage
  end

  # Get display status with color coding info
  # @return [Hash]
  def display_status
    {
      name: name,
      hp: current_hp,
      max_hp: max_hp,
      hp_percent: hp_percent,
      status: status,
      can_attack: can_attack,
      is_weak_point: weak_point?
    }
  end
end
