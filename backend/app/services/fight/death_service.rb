# frozen_string_literal: true

# DeathService - Handles character death and resurrection mechanics
#
# When a character dies, they are moved to the death room where they cannot
# communicate IC (in-character). They must either be resurrected by another
# player or use REROLL to create a new character.
#
# Usage:
#   DeathService.kill(character_instance)
#   DeathService.resurrect(character_instance, destination_room)
#   DeathService.death_room  # Get the global death room
#
module DeathService
  class DeathRoomNotConfigured < StandardError; end
  class AlreadyDead < StandardError; end
  class NotDead < StandardError; end
  class TimelineRestriction < StandardError; end

  class << self
    include PersonalizedBroadcastConcern
    # Kill a character and move them to the death room
    #
    # @param character_instance [CharacterInstance] The character to kill
    # @param cause [String] Optional description of what killed them
    # @return [Boolean] true if successful
    # @raise [DeathRoomNotConfigured] if no death room exists
    # @raise [AlreadyDead] if character is already dead
    def kill(character_instance, cause: nil)
      # Timeline restriction - characters cannot die in past timelines
      if character_instance.in_past_timeline? && !character_instance.can_die?
        raise TimelineRestriction, 'Characters cannot die in past timelines'
      end

      raise AlreadyDead, 'Character is already dead' if character_instance.status == 'dead'

      death_room = self.death_room
      raise DeathRoomNotConfigured, 'No death room configured! Create a room with room_type=death.' unless death_room

      original_room = character_instance.current_room

      DB.transaction do
        # Store previous location for possible resurrection
        character_instance.update(
          current_room_id: death_room.id,
          status: 'dead',
          x: 0.0,
          y: 0.0,
          z: 0.0
        )

        # Broadcast death to original room
        death_message = if cause
                          "#{character_instance.character.full_name} #{cause}."
                        else
                          "#{character_instance.character.full_name} has died."
                        end

        broadcast_personalized_to_room(
          original_room.id,
          death_message,
          exclude: [character_instance.id],
          extra_characters: [character_instance]
        )

        # Send arrival message to death room (if others are there)
        broadcast_personalized_to_room(
          death_room.id,
          "#{character_instance.character.full_name} has arrived in the void.",
          exclude: [character_instance.id],
          extra_characters: [character_instance]
        )

        # Message to the dead character
        BroadcastService.to_character(
          character_instance,
          "You have died. Type REROLL to create a new character, or wait for resurrection.",
          type: :system
        )
      end

      true
    end

    # Resurrect a dead character and move them to a destination room
    #
    # @param character_instance [CharacterInstance] The character to resurrect
    # @param destination_room [Room] Optional room to resurrect to (defaults to spawn room)
    # @return [Boolean] true if successful
    # @raise [NotDead] if character is not dead
    def resurrect(character_instance, destination_room = nil)
      raise NotDead, 'Character is not dead' unless character_instance.status == 'dead'

      destination = destination_room || spawn_room
      raise 'No spawn room configured!' unless destination

      DB.transaction do
        character_instance.update(
          current_room_id: destination.id,
          status: 'alive',
          x: 0.0,
          y: 0.0,
          z: 0.0
        )

        # Broadcast resurrection to death room
        broadcast_personalized_to_room(
          death_room&.id,
          "#{character_instance.character.full_name} fades from the void.",
          extra_characters: [character_instance]
        )

        # Broadcast arrival to destination room
        broadcast_personalized_to_room(
          destination.id,
          "#{character_instance.character.full_name} has been resurrected!",
          exclude: [character_instance.id],
          extra_characters: [character_instance]
        )

        # Message to the resurrected character
        BroadcastService.to_character(
          character_instance,
          "You have been resurrected! You find yourself in #{destination.name}.",
          type: :system
        )
      end

      true
    end

    # Get the global death room
    #
    # @return [Room, nil] The death room or nil if not configured
    def death_room
      Room.first(room_type: 'death')
    end

    # Check if a character is dead
    #
    # @param character_instance [CharacterInstance] The character to check
    # @return [Boolean] true if dead
    def dead?(character_instance)
      character_instance.status == 'dead'
    end

    # Check if a character can communicate IC
    # Dead characters in the death room cannot communicate IC
    #
    # @param character_instance [CharacterInstance] The character to check
    # @return [Boolean] true if can communicate IC
    def can_communicate_ic?(character_instance)
      return false if dead?(character_instance)
      return false if character_instance.current_room&.blocks_ic_communication?

      true
    end

    private

    # Get the spawn room for resurrections
    def spawn_room
      Room.tutorial_spawn_room
    end
  end
end
