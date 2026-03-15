# frozen_string_literal: true

require_relative '../concerns/result_handler'

# Handles treasure generation and looting.
class DelveTreasureService
  extend ResultHandler

  class << self
    # Generate treasure for a room
    # @param room [DelveRoom] the room
    # @param level [Integer] dungeon level
    # @param era [Symbol, String] the current era
    # @return [DelveTreasure] the generated treasure
    def generate!(room, level, era)
      gold = DelveTreasure.calculate_value(level)
      container = DelveTreasure.container_for_era(era)

      DelveTreasure.create(
        delve_room_id: room.id,
        gold_value: gold,
        container_type: container
      )
    end

    # Loot treasure (no time cost)
    # @param participant [DelveParticipant] the participant
    # @param treasure [DelveTreasure] the treasure to loot
    # @return [Result]
    def loot!(participant, treasure)
      if treasure.looted?
        return Result.new(
          success: false,
          message: "The #{treasure.container_type} has already been emptied.",
          data: { looted: false }
        )
      end

      gold = treasure.gold_value
      participant.add_loot!(gold)
      treasure.loot!

      Result.new(
        success: true,
        message: loot_message(treasure, gold, participant.loot_collected),
        data: {
          looted: true,
          gold: gold,
          total_loot: participant.loot_collected
        }
      )
    end

    # Get treasure display info
    # @param treasure [DelveTreasure] the treasure
    # @return [Hash] display data
    def display_text(treasure)
      {
        container: treasure.container_type,
        looted: treasure.looted?,
        description: treasure.description,
        value_hint: treasure.value_hint
      }
    end

    private

    def loot_message(treasure, gold, total)
      container = treasure.container_type || 'container'

      case gold
      when 0..10
        "You pry open the #{container} and find #{gold} gold coins. (Total: #{total}g)"
      when 11..30
        "You open the #{container} and collect #{gold} gold pieces! (Total: #{total}g)"
      when 31..60
        "The #{container} yields a respectable #{gold} gold! (Total: #{total}g)"
      when 61..100
        "You discover #{gold} gold coins in the #{container}! Excellent find! (Total: #{total}g)"
      else
        "A king's ransom! #{gold} gold spills from the #{container}! (Total: #{total}g)"
      end
    end
  end
end
