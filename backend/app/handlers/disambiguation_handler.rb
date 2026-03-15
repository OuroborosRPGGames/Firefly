# frozen_string_literal: true

class DisambiguationHandler
  extend ResultHandler

  class << self
    def process_response(character_instance, interaction_data, selected_key)
      context = interaction_data[:context] || interaction_data['context']
      type = (context[:type] || context['type']).to_sym
      adverb = context[:adverb] || context['adverb'] || 'walk'

      case type
      when :character
        target_instance = CharacterInstance[selected_key.to_i]
        return error('Character not found') unless target_instance

        MovementService.start_movement(
          character_instance,
          target: target_instance.full_name,
          adverb: adverb
        )

      when :exit
        # Spatial exits are identified by direction (selected_key is the direction)
        MovementService.start_movement(
          character_instance,
          target: selected_key,
          adverb: adverb
        )

      when :room
        room = Room[selected_key.to_i]
        return error('Room not found') unless room

        MovementService.start_movement(
          character_instance,
          target: room.name,
          adverb: adverb
        )

      when :furniture
        furniture = Item[selected_key.to_i]
        return error('Object not found') unless furniture

        MovementService.approach_furniture(character_instance, furniture, adverb)

      when :event
        event = Event[selected_key.to_i]
        return error('Event not found') unless event
        return error("The event '#{event.name}' has no location set.") unless event.room

        MovementService.start_movement(
          character_instance,
          target: event.room.name,
          adverb: adverb
        )

      else
        error("Unknown disambiguation type: #{type}")
      end
    end
  end
end
