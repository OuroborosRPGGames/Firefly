# frozen_string_literal: true

require_relative '../../config/movement'

class ApproachHandler
  extend TimedActionHandler

  class << self
    include PersonalizedBroadcastConcern

    def call(timed_action)
      data = timed_action.parsed_action_data
      character_instance = timed_action.character_instance

      # Move character to target position
      character_instance.update(
        x: data['target_x'],
        y: data['target_y'],
        z: data['target_z'],
        movement_state: 'idle'
      )

      adverb = data['adverb'] || 'walk'
      verb_past = MovementConfig.conjugate(adverb, :past)

      # Get target name for message
      target_name = data['target_name'] || resolve_target_name(data)

      message = "You #{verb_past} over to #{target_name}."

      # Broadcast to room (personalized per viewer)
      broadcast_personalized_to_room(
        character_instance.current_room_id,
        "#{character_instance.character.full_name} #{verb_past} over to #{target_name}.",
        exclude: [character_instance.id],
        extra_characters: [character_instance]
      )

      store_success(timed_action, {
        message: message,
        position: [data['target_x'], data['target_y'], data['target_z']]
      })

      # Continue any pending semote actions after approach completes
      SemoteContinuationHandler.call(timed_action)
    end

    private

    def resolve_target_name(data)
      case data['target_type']
      when 'furniture'
        Item[data['target_id']]&.name || 'the object'
      when 'character'
        target_instance = CharacterInstance[data['target_id']]
        target_instance&.character&.full_name || 'them'
      else
        'there'
      end
    end
  end
end
