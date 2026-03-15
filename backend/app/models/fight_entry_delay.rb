# frozen_string_literal: true

class FightEntryDelay < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :fight
  many_to_one :character_instance

  # Distance units per round of delay
  DISTANCE_PER_DELAY_ROUND = 25.0

  def validate
    super
    validates_presence [:fight_id, :character_instance_id]
    validates_unique [:fight_id, :character_instance_id]
  end

  # Check if character can enter the fight room
  # @return [Boolean] true if in fight room at start or enough rounds have passed
  def can_enter?
    in_fight_room || fight.round_number >= entry_allowed_at_round
  end

  # Get number of rounds remaining until entry is allowed
  # @return [Integer] rounds remaining (0 if can enter now)
  def rounds_remaining
    return 0 if can_enter?

    entry_allowed_at_round - fight.round_number
  end

  # Maximum delay rounds for unreachable or very distant locations
  MAX_DELAY_ROUNDS = 100

  # Calculate delay rounds from distance
  # @param distance [Float] coordinate distance
  # @return [Integer] number of rounds of delay
  def self.calculate_delay_rounds(distance)
    return MAX_DELAY_ROUNDS if distance.nil? || !distance.finite?

    (distance / DISTANCE_PER_DELAY_ROUND).floor
  end
end
