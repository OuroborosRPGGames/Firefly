# frozen_string_literal: true

class MovementHandler
  extend TimedActionHandler

  class << self
    def call(timed_action)
      data = timed_action.parsed_action_data
      character_instance = timed_action.character_instance

      # Spatial exits are stored by direction and destination room ID
      direction = data[:direction]
      destination_room_id = data[:destination_room_id]

      from_room = character_instance.current_room
      destination = Room[destination_room_id]

      unless destination
        store_error(timed_action, 'Destination room no longer exists')
        character_instance.update(movement_state: 'idle')
        return
      end

      # Re-check passability (walls/doors may have changed)
      unless RoomPassabilityService.can_pass?(from_room, destination, direction)
        store_error(timed_action, 'The way is blocked')
        character_instance.update(movement_state: 'idle')
        return
      end

      # Check for active fight in destination room with entry delay
      active_fight = Fight.where(room_id: destination.id)
                          .where(status: %w[input resolving narrative])
                          .first

      if active_fight && !FightEntryDelayService.can_enter?(character_instance, active_fight)
        rounds_left = FightEntryDelayService.rounds_until_entry(character_instance, active_fight)
        store_error(timed_action, "Fight in progress. You can enter in #{rounds_left} round(s).")
        character_instance.update(movement_state: 'idle')

        # Broadcast explanation to character
        BroadcastService.to_character(
          character_instance,
          "A fight has broken out in #{destination.name}. You can enter in #{rounds_left} more combat round(s)."
        )
        return
      end

      # Create a spatial exit struct for the transition
      spatial_exit = MovementService::SpatialExit.new(
        to_room: destination,
        direction: direction,
        from_room: from_room
      )

      result = MovementService.complete_room_transition(character_instance, spatial_exit)

      if result.success
        # Reload to check if directional walking continues
        character_instance.refresh

        result_data = { moved_from: result.data[:from].id }

        # Only set moved_to if the character has stopped (not continuing directional walk).
        # Setting moved_to triggers a full room look on the webclient, which we skip during transit.
        if character_instance.movement_direction.nil?
          result_data[:moved_to] = result.data[:room].id
        end

        store_success(timed_action, result_data)
      else
        store_error(timed_action, result.message)
      end

      # Continue any pending semote actions after movement completes
      SemoteContinuationHandler.call(timed_action)
    end
  end
end
