# frozen_string_literal: true

module Commands
  module Base
    # Determines the current context for a character instance based on
    # their state (combat, delve, activity) and room properties.
    #
    # Extracted from Registry to separate command registration from
    # runtime context determination.
    module ContextResolver
      # Determine the current context for a character
      def determine_context(character_instance)
        return [] unless character_instance

        contexts = []

        if character_instance.respond_to?(:in_combat?) && character_instance.in_combat?
          contexts << :combat
        end

        if character_instance.respond_to?(:status)
          contexts << character_instance.status.to_sym if character_instance.status
        end

        contexts << :delve if in_active_delve?(character_instance)
        contexts << :activity if in_active_activity?(character_instance)

        if character_instance.current_room
          room = character_instance.current_room
          contexts << room.room_type.to_sym if room.room_type

          %i[underwater dark safe no_magic no_combat].each do |flag|
            contexts << flag if room.respond_to?(flag) && room.send(flag)
          end
        end

        contexts
      end

      private

      def in_active_delve?(character_instance)
        return false unless character_instance
        return false unless defined?(DelveParticipant)

        DelveParticipant.where(
          character_instance_id: character_instance.id,
          status: 'active'
        ).any?
      rescue StandardError => e
        warn "[ContextResolver] Error checking delve status: #{e.message}"
        false
      end

      def in_active_activity?(character_instance)
        return false unless character_instance
        return false unless defined?(ActivityService)

        room = character_instance.current_room
        return false unless room

        instance = ActivityService.running_activity(room)
        return false unless instance

        participant = ActivityService.participant_for(instance, character_instance)
        participant&.active?
      rescue StandardError => e
        warn "[ContextResolver] Error checking activity status: #{e.message}"
        false
      end
    end
  end
end
