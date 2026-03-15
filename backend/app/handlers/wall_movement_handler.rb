# frozen_string_literal: true

require_relative '../../config/movement'

class WallMovementHandler
  extend TimedActionHandler

  class << self
    include PersonalizedBroadcastConcern

    def call(timed_action)
      data = timed_action.parsed_action_data
      character_instance = timed_action.character_instance

      # Move character to wall position
      character_instance.update(
        x: data['target_x'],
        y: data['target_y'],
        z: data['target_z'],
        movement_state: 'idle'
      )

      direction = data['direction']
      wall_name = wall_name_for_direction(direction)
      message = "You arrive at the #{wall_name}."

      # Broadcast to room (personalized per viewer)
      broadcast_personalized_to_room(
        character_instance.current_room_id,
        "#{character_instance.character.full_name} walks to the #{wall_name}.",
        exclude: [character_instance.id],
        extra_characters: [character_instance]
      )

      store_success(timed_action, {
        message: message,
        position: [data['target_x'], data['target_y'], data['target_z']]
      })

      # Continue any pending semote actions after wall movement completes
      SemoteContinuationHandler.call(timed_action)
    end

    private

    def wall_name_for_direction(direction)
      case direction.to_s.downcase
      when 'north', 'south', 'east', 'west'
        "#{direction}ern wall"
      when 'northeast', 'northwest', 'southeast', 'southwest'
        "#{direction} corner"
      when 'up'
        'ceiling'
      when 'down'
        'floor'
      else
        "#{direction} wall"
      end
    end
  end
end
