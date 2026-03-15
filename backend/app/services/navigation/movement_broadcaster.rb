# frozen_string_literal: true

require_relative '../../../config/movement'
require_relative '../../helpers/canvas_helper'

class MovementBroadcaster
  class << self
    def broadcast_departure(character_instance, room, direction, adverb: 'walk')
      verb = MovementConfig.conjugate(adverb, :present)
      manner = manner_for(character_instance)
      name = character_instance.full_name

      message = case direction.to_s
                when 'enter'
                  manner ? "#{name} #{manner} #{verb} inside." : "#{name} #{verb} inside."
                when 'exit'
                  manner ? "#{name} #{manner} #{verb} out." : "#{name} #{verb} out."
                else
                  manner ? "#{name} #{manner} #{verb} #{direction}." : "#{name} #{verb} #{direction}."
                end

      broadcast_to_room(room, message, exclude: character_instance, extra_characters: [character_instance])
      broadcast_to_sightlines(room, message, direction, type: :departure, extra_characters: [character_instance])
    end

    def broadcast_arrival(character_instance, room, from_direction, adverb: 'walk')
      verb = MovementConfig.conjugate(adverb, :present)
      manner = manner_for(character_instance)
      name = character_instance.full_name

      message = case from_direction.to_s
                when 'enter'
                  manner ? "#{name} #{manner} #{verb} in." : "#{name} #{verb} in."
                when 'exit'
                  manner ? "#{name} #{manner} #{verb} in from inside." : "#{name} #{verb} in from inside."
                else
                  opposite = CanvasHelper.arrival_direction(from_direction)
                  manner ? "#{name} #{manner} #{verb} in from the #{opposite}." : "#{name} #{verb} in from the #{opposite}."
                end

      broadcast_to_room(room, message, exclude: character_instance, extra_characters: [character_instance])
      broadcast_to_sightlines(room, message, from_direction, type: :arrival, extra_characters: [character_instance])
    end

    def broadcast_movement_start(character_instance, target_description, adverb: 'walk')
      verb_continuous = MovementConfig.conjugate(adverb, :continuous)
      manner = manner_for(character_instance)
      message = if manner
                  "#{character_instance.full_name} starts #{manner} #{verb_continuous} toward #{target_description}."
                else
                  "#{character_instance.full_name} starts #{verb_continuous} toward #{target_description}."
                end

      broadcast_to_room(character_instance.current_room, message, exclude: character_instance, extra_characters: [character_instance])
    end

    def broadcast_movement_stop(character_instance, reason: nil)
      room = character_instance.current_room
      message = if reason
                  "#{character_instance.full_name} stops moving (#{reason})."
                else
                  "#{character_instance.full_name} stops moving."
                end

      broadcast_to_room(room, message, exclude: character_instance, extra_characters: [character_instance])
    end

    def broadcast_follow_start(follower, leader)
      message = "#{follower.full_name} starts following #{leader.full_name}."
      broadcast_to_room(follower.current_room, message, extra_characters: [follower, leader])
    end

    def broadcast_follow_stop(follower, leader, reason: nil)
      message = if reason
                  "#{follower.full_name} stops following #{leader.full_name} (#{reason})."
                else
                  "#{follower.full_name} stops following #{leader.full_name}."
                end

      broadcast_to_room(follower.current_room, message, extra_characters: [follower, leader])
    end

    private

    def manner_for(character_instance)
      return nil unless character_instance.respond_to?(:movement_manner)

      manner = character_instance.movement_manner
      manner&.strip&.empty? ? nil : manner&.downcase
    end

    def broadcast_to_room(room, message, exclude: nil, extra_characters: [])
      return unless room

      viewers = CharacterInstance
                .where(current_room_id: room.id, online: true)
                .eager(:character)

      viewers = viewers.exclude(id: exclude.id) if exclude
      viewer_list = viewers.all

      # Characters available for name personalization (include extras like departing character)
      all_characters = (viewer_list + Array(extra_characters)).uniq(&:id)

      viewer_list.each do |viewer|
        personalized = MessagePersonalizationService.personalize(
          message: message,
          viewer: viewer,
          room_characters: all_characters
        )
        send_to_character(viewer, personalized)
      end
    end

    def broadcast_to_sightlines(room, message, direction, type:, extra_characters: [])
      return unless room.respond_to?(:room_sightlines)

      room.room_sightlines.each do |sightline|
        next unless sightline_matches_direction?(sightline, direction)

        target_room = sightline.to_room
        distance_note = sightline.distance_description || 'in the distance'
        distant_message = "(#{distance_note}) #{message}"

        broadcast_to_room(target_room, distant_message, extra_characters: extra_characters)
      end
    end

    def sightline_matches_direction?(sightline, direction)
      return true if sightline.bidirectional?

      sightline.direction&.downcase == direction&.downcase
    end

    def send_to_character(character_instance, message)
      BroadcastService.to_character(character_instance, message)
    end

  end
end
