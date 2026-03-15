# frozen_string_literal: true

# Service for concealment ranged attack penalties
class ConcealmentService
  # Calculate ranged attack penalty based on distance
  # Formula: -(distance / 6).floor, capped at -4
  #
  # @param distance_hexes [Integer] distance in hexes
  # @return [Integer] penalty (0 or negative)
  def self.ranged_penalty(distance_hexes)
    penalty = -(distance_hexes / 6).floor
    [penalty, -4].max # Cap at -4
  end

  # Check if concealment penalty applies to this attack
  #
  # @param target_hex [RoomHex] hex where target is standing
  # @param attack_type [String] 'melee' or 'ranged'
  # @return [Boolean]
  def self.applies_to_attack?(target_hex, attack_type)
    return false unless target_hex
    return false unless attack_type == 'ranged'

    target_hex.hex_type == 'concealed'
  end
end
