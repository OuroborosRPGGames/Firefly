# frozen_string_literal: true

class StrandedCharacterService
  class << self
    # Check a single character and rescue if stranded in a temporary room.
    # @param character_instance [CharacterInstance]
    # @return [Room, nil] destination room if rescued, nil if not stranded
    def check_and_rescue!(character_instance)
      room = character_instance.current_room
      return nil unless room&.temporary?
      return nil unless stranded_in_room?(room)

      destination = character_instance.safe_fallback_room
      character_instance.teleport_to_room!(destination)
      warn "[StrandedCharacterService] Rescued #{character_instance.character&.name} " \
           "from temporary room #{room.id} to #{destination.name} (#{destination.id})"
      destination
    end

    # Batch check all online characters in temporary rooms.
    # @return [Integer] number of characters rescued
    def rescue_all_stranded!
      count = 0
      CharacterInstance
        .where(online: true)
        .join(:rooms, id: :current_room_id)
        .where(Sequel[:rooms][:is_temporary] => true)
        .select_all(:character_instances)
        .each do |ci|
          count += 1 if check_and_rescue!(ci)
        end
      count
    rescue StandardError => e
      warn "[StrandedCharacterService] Batch rescue failed: #{e.message}"
      0
    end

    private

    # Determine if a character is stranded in the given temporary room.
    def stranded_in_room?(room)
      return true if room.pool_status == 'available'

      if room.temp_delve_id
        delve = Delve[room.temp_delve_id]
        return true if delve.nil? || %w[completed abandoned failed].include?(delve.status)
      end

      if room.temp_journey_id
        journey = WorldJourney[room.temp_journey_id]
        return true if journey.nil? || %w[arrived cancelled].include?(journey.status)
      end

      if room.temp_vehicle_id
        vehicle = Vehicle[room.temp_vehicle_id]
        return true if vehicle.nil? || !room.in_use?
      end

      # Temp room with no entity attached and not in_use
      if room.temp_delve_id.nil? && room.temp_journey_id.nil? && room.temp_vehicle_id.nil?
        return true unless room.in_use?
      end

      false
    end
  end
end
