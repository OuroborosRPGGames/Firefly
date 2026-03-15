# frozen_string_literal: true

# Defines a body part/segment for a monster type.
# Each segment has its own HP pool, attacks, and special properties.
class MonsterSegmentTemplate < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :monster_template
  one_to_many :monster_segment_instances

  SEGMENT_TYPES = %w[head limb body tail wing tentacle core].freeze

  def validate
    super
    validates_presence [:monster_template_id, :name, :hp_percent, :attacks_per_round, :attack_speed]
    validates_max_length 50, :name
    validates_includes SEGMENT_TYPES, :segment_type if segment_type
    validates_integer :hp_percent
    validates_integer :attacks_per_round
    validates_integer :attack_speed
    validates_integer :reach
  end

  # Calculate attack segments for the 100-segment timeline
  # Similar to FightParticipant#attack_segments
  # @return [Array<Integer>] segment numbers (1-100) when this segment attacks
  def attack_segments
    return [] if attacks_per_round <= 0

    interval = 100.0 / attacks_per_round
    (1..attacks_per_round).map do |i|
      base_segment = ((i * interval) - interval / 2).round
      base_segment.clamp(1, 100)
    end
  end

  # Parse damage dice string into components
  # @return [Hash] { count: Integer, sides: Integer, modifier: Integer }
  def parsed_damage_dice
    match = (damage_dice || '2d8').match(/(\d+)d(\d+)([+-]\d+)?/)
    return { count: 2, sides: 8, modifier: 0 } unless match

    {
      count: match[1].to_i,
      sides: match[2].to_i,
      modifier: match[3].to_i
    }
  end

  # Roll damage for this segment
  # @return [Integer]
  def roll_damage
    dice = parsed_damage_dice
    total = 0
    dice[:count].times { total += rand(1..dice[:sides]) }
    total + dice[:modifier]
  end

  # Parse attack effects from JSONB
  # @return [Array<Hash>]
  def parsed_attack_effects
    return [] unless attack_effects

    if attack_effects.respond_to?(:to_a)
      attack_effects.to_a
    elsif attack_effects.is_a?(String)
      JSON.parse(attack_effects)
    else
      []
    end
  rescue JSON::ParserError
    []
  end

  # Check if this segment has a specific attack effect
  # @param effect_type [String] e.g., 'knockback', 'grab'
  # @return [Boolean]
  def has_effect?(effect_type)
    parsed_attack_effects.any? { |e| e['type'] == effect_type }
  end

  # Get the hex position for this segment relative to monster center,
  # accounting for facing direction rotation.
  # @param center_x [Integer]
  # @param center_y [Integer]
  # @param facing [Integer] 0-5 (0=E, 1=NE, 2=NW, 3=W, 4=SW, 5=SE)
  # @return [Array<Integer>] [x, y]
  def position_at(center_x, center_y, facing = 0)
    dx = hex_offset_x || 0
    dy = hex_offset_y || 0

    # Rotate offset by facing direction
    rotated_dx, rotated_dy = rotate_hex_offset(dx, dy, facing)

    [center_x + rotated_dx, center_y + rotated_dy]
  end

  private

  # Rotate hex offset by facing direction (60-degree increments).
  # Uses offset hex coordinate rotation for flat-top hexes.
  # @param dx [Integer] original x offset
  # @param dy [Integer] original y offset
  # @param facing [Integer] 0-5 rotation steps (clockwise)
  # @return [Array<Integer>] rotated [x, y]
  def rotate_hex_offset(dx, dy, facing)
    return [dx, dy] if facing.zero? || (dx.zero? && dy.zero?)

    # Apply rotation steps
    facing.times do
      # Hex rotation for 60-degree clockwise step
      # Convert to cube coordinates, rotate, convert back
      # For offset coords: new_x = -dy, new_y = dx + dy
      new_dx = -dy
      new_dy = dx + dy
      dx, dy = new_dx, new_dy
    end

    [dx, dy]
  end
end
