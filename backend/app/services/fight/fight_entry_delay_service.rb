# frozen_string_literal: true

# Service to manage distance-based entry delays for fight rooms.
# When a fight starts, snapshots all character distances.
# Characters outside the fight room must wait before entering.
class FightEntryDelayService
  extend CharacterLookupHelper

  # Average room size for distance estimation (coordinate units)
  ESTIMATED_ROOM_SIZE = 50.0

  class << self
    # Snapshot distances for all online characters when a fight starts
    # @param fight [Fight] the newly started fight
    def snapshot_distances(fight)
      fight_room = fight.room
      all_online_characters = find_all_online_characters

      all_online_characters.each do |char_instance|
        in_fight_room = char_instance.current_room_id == fight_room.id

        distance = if in_fight_room
                     0.0
                   else
                     calculate_distance_to_room(char_instance, fight_room)
                   end

        delay_rounds = FightEntryDelay.calculate_delay_rounds(distance)
        entry_round = fight.round_number + delay_rounds

        FightEntryDelay.create(
          fight_id: fight.id,
          character_instance_id: char_instance.id,
          distance_at_start: distance,
          delay_rounds: delay_rounds,
          entry_allowed_at_round: entry_round,
          in_fight_room: in_fight_room
        )
      end
    end

    # Check if a character can enter the fight room
    # @param character_instance [CharacterInstance] the character trying to enter
    # @param fight [Fight] the active fight in the room
    # @return [Boolean] true if entry is allowed
    def can_enter?(character_instance, fight)
      delay = find_or_create_delay(character_instance, fight)
      delay.can_enter?
    end

    # Get remaining rounds until entry is allowed
    # @param character_instance [CharacterInstance] the character
    # @param fight [Fight] the active fight
    # @return [Integer] rounds remaining (0 if can enter now)
    def rounds_until_entry(character_instance, fight)
      delay = find_or_create_delay(character_instance, fight)
      delay.rounds_remaining
    end

    # Create delay records for all active fights when a character logs in
    # Called from CharacterInstance after_save when online changes to true
    # @param character_instance [CharacterInstance] the newly online character
    def create_delays_for_character(character_instance)
      active_fights = Fight.where(status: %w[input resolving narrative]).all
      return if active_fights.empty?

      active_fights.each do |fight|
        # Skip if delay record already exists
        next if FightEntryDelay.where(
          fight_id: fight.id,
          character_instance_id: character_instance.id
        ).any?

        create_delayed_entry(character_instance, fight)
      end
    end

    private

    # Find existing delay record or create one for late-joining characters
    def find_or_create_delay(character_instance, fight)
      delay = FightEntryDelay.where(
        fight_id: fight.id,
        character_instance_id: character_instance.id
      ).first

      # If no delay record exists (character logged in after fight started),
      # create one based on their current position
      delay || create_delayed_entry(character_instance, fight)
    end

    # Create a delay record for a character who wasn't online when fight started
    def create_delayed_entry(character_instance, fight)
      fight_room = fight.room
      in_fight_room = character_instance.current_room_id == fight_room.id

      distance = if in_fight_room
                   0.0
                 else
                   calculate_distance_to_room(character_instance, fight_room)
                 end

      delay_rounds = FightEntryDelay.calculate_delay_rounds(distance)
      # Use current round as base for late-joining characters
      entry_round = fight.round_number + delay_rounds

      FightEntryDelay.create(
        fight_id: fight.id,
        character_instance_id: character_instance.id,
        distance_at_start: distance,
        delay_rounds: delay_rounds,
        entry_allowed_at_round: entry_round,
        in_fight_room: in_fight_room
      )
    end

    # Calculate coordinate distance from character to fight room entrance
    def calculate_distance_to_room(char_instance, target_room)
      return Float::INFINITY unless char_instance.current_room

      # Get character's current position
      char_pos = char_instance.position

      # Find path to fight room
      path = PathfindingService.find_path(char_instance.current_room, target_room)
      return Float::INFINITY if path.empty?

      # Calculate distance to first exit in path
      first_exit = path.first
      exit_pos = DistanceService.exit_position_in_room(first_exit)

      # Distance from character to first exit
      first_leg_distance = DistanceService.calculate_distance(
        char_pos[0], char_pos[1], char_pos[2],
        exit_pos[0], exit_pos[1], exit_pos[2]
      )

      # Add estimated distance for each room traversal
      remaining_rooms_distance = (path.length - 1) * ESTIMATED_ROOM_SIZE

      first_leg_distance + remaining_rooms_distance
    end
  end
end
