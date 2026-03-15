# frozen_string_literal: true

# Value object representing an NPC's natural attack
# This encapsulates attack data stored in NpcArchetype.npc_attacks JSONB
#
# @example Creating from JSONB data
#   attack = NpcAttack.new({
#     'name' => 'Bite',
#     'attack_type' => 'melee',
#     'damage_dice' => '2d6',
#     'damage_type' => 'physical',
#     'attack_speed' => 5,
#     'range_hexes' => 1
#   })
#
# @example Using a weapon template
#   attack = NpcAttack.from_template('sword', name: 'Rusty Sword')
#
class NpcAttack
  attr_reader :name, :attack_type, :damage_dice, :damage_type,
              :attack_speed, :range_hexes, :weapon_template,
              :hit_message, :miss_message, :critical_message,
              :melee_reach

  # Initialize from a hash (usually from JSONB)
  # @param data [Hash] Attack attributes
  def initialize(data)
    data = data.transform_keys(&:to_s)
    @name = data['name'] || 'Attack'
    @attack_type = data['attack_type'] || 'melee'
    @damage_dice = data['damage_dice'] || '2d6'
    @damage_type = data['damage_type'] || 'physical'
    @attack_speed = (data['attack_speed'] || 5).to_i
    @range_hexes = (data['range_hexes'] || 1).to_i
    @weapon_template = data['weapon_template']
    @hit_message = data['hit_message']
    @miss_message = data['miss_message']
    @critical_message = data['critical_message']
    @melee_reach = (data['melee_reach'] || GameConfig::Mechanics::REACH[:unarmed_reach]).to_i
  end

  # Create an attack from a weapon template
  # @param template_name [String] Name of the template (e.g., 'sword', 'bite')
  # @param overrides [Hash] Attributes to override from the template
  # @return [NpcAttack]
  def self.from_template(template_name, **overrides)
    template = GameConfig::NpcAttacks::WEAPON_TEMPLATES[template_name.to_s]
    raise ArgumentError, "Unknown weapon template: #{template_name}" unless template

    data = template.transform_keys(&:to_s).merge(
      'name' => overrides[:name] || template_name.to_s.tr('_', ' ').capitalize,
      'weapon_template' => template_name.to_s
    )

    overrides.each do |key, value|
      data[key.to_s] = value unless value.nil?
    end

    new(data)
  end

  # Check if this is a melee attack
  # @return [Boolean]
  def melee?
    attack_type == 'melee'
  end

  # Check if this is a ranged attack
  # @return [Boolean]
  def ranged?
    attack_type == 'ranged'
  end

  # Parse damage dice string into count
  # @return [Integer] Number of dice (e.g., 2 for "2d6")
  def dice_count
    damage_dice.split('d').first.to_i
  end

  # Parse damage dice string into sides
  # @return [Integer] Sides per die (e.g., 6 for "2d6")
  def dice_sides
    damage_dice.split('d').last.to_i
  end

  # Calculate expected damage (average roll)
  # @return [Float]
  def expected_damage
    dice_count * ((dice_sides + 1) / 2.0)
  end

  # Get the hit message, falling back to defaults
  # @param attacker_name [String] Name to substitute for %{attacker}
  # @param target_name [String] Name to substitute for %{target}
  # @return [String]
  def format_hit_message(attacker_name:, target_name:)
    msg = hit_message || default_message(:hit)
    format(msg, attacker: attacker_name, target: target_name)
  end

  # Get the miss message, falling back to defaults
  # @param attacker_name [String] Name to substitute for %{attacker}
  # @param target_name [String] Name to substitute for %{target}
  # @return [String]
  def format_miss_message(attacker_name:, target_name:)
    msg = miss_message || default_message(:miss)
    format(msg, attacker: attacker_name, target: target_name)
  end

  # Get the critical message, falling back to defaults
  # @param attacker_name [String] Name to substitute for %{attacker}
  # @param target_name [String] Name to substitute for %{target}
  # @return [String]
  def format_critical_message(attacker_name:, target_name:)
    msg = critical_message || default_message(:critical)
    format(msg, attacker: attacker_name, target: target_name)
  end

  # Check if attack can reach a target at given distance
  # @param distance [Integer] Distance in hexes
  # @return [Boolean]
  def in_range?(distance)
    distance <= range_hexes
  end

  # Get melee reach value (for consistency with Pattern#melee_reach_value)
  # Returns nil for ranged attacks
  # @return [Integer, nil]
  def melee_reach_value
    return nil unless melee?

    melee_reach
  end

  # Convert to hash for JSONB storage
  # @return [Hash]
  def to_h
    {
      'name' => name,
      'attack_type' => attack_type,
      'damage_dice' => damage_dice,
      'damage_type' => damage_type,
      'attack_speed' => attack_speed,
      'range_hexes' => range_hexes,
      'weapon_template' => weapon_template,
      'hit_message' => hit_message,
      'miss_message' => miss_message,
      'critical_message' => critical_message,
      'melee_reach' => melee_reach
    }.compact
  end

  # Equality check
  def ==(other)
    return false unless other.is_a?(NpcAttack)

    name == other.name &&
      attack_type == other.attack_type &&
      damage_dice == other.damage_dice &&
      damage_type == other.damage_type &&
      attack_speed == other.attack_speed
  end

  private

  # Get default message for a message type
  # @param type [Symbol] :hit, :miss, or :critical
  # @return [String]
  def default_message(type)
    messages = GameConfig::NpcAttacks::DEFAULT_MESSAGES
    template_key = weapon_template || name&.downcase

    template_messages = messages[template_key] || messages['default']
    template_messages[type] || messages['default'][type]
  end
end
