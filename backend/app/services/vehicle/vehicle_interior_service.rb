# frozen_string_literal: true

# VehicleInteriorService handles entering and exiting vehicles using
# the temporary room pool system.
#
# When a character enters a vehicle, an interior room is acquired from
# the pool (or created if needed). When all occupants leave, the room
# is scheduled for release back to the pool.
#
# Usage:
#   # Enter a vehicle
#   result = VehicleInteriorService.enter_vehicle(character_instance, vehicle)
#   if result.success?
#     puts "You enter the #{result[:vehicle].name}"
#   end
#
#   # Exit a vehicle
#   result = VehicleInteriorService.exit_vehicle(character_instance)
#
#   # Save interior customizations
#   VehicleInteriorService.save_interior_customizations(vehicle)
#
class VehicleInteriorService
  extend ResultHandler

  class << self
    # Enter a vehicle (board and move to interior room)
    # @param character_instance [CharacterInstance] the character entering
    # @param vehicle [Vehicle] the vehicle to enter
    # @return [Result] success with room and vehicle data, or error
    def enter_vehicle(character_instance, vehicle)
      # Check vehicle capacity
      if vehicle.respond_to?(:full?) && vehicle.full?
        return error("The #{vehicle_name(vehicle)} is full.")
      end

      # Check if vehicle is operational
      if vehicle.respond_to?(:operational?) && !vehicle.operational?
        return error("The #{vehicle_name(vehicle)} is not operational.")
      end

      # Ensure vehicle has an interior room (acquire from pool if needed)
      unless vehicle.interior_room_id
        result = TemporaryRoomPoolService.acquire_for_vehicle(vehicle)
        return error(result.message) unless result.success?

        vehicle.reload
      end

      interior_room = vehicle.interior_room
      return error('Vehicle has no interior.') unless interior_room

      # Move character into vehicle
      DB.transaction do
        character_instance.update(
          current_room_id: interior_room.id,
          current_vehicle_id: vehicle.id
        )

        # Center position in room
        if character_instance.respond_to?(:teleport_to_room!)
          character_instance.teleport_to_room!(interior_room)
        end

        # Update room last used timestamp
        interior_room.update(pool_last_used_at: Time.now)
      end

      success("You enter the #{vehicle_name(vehicle)}.", data: {
                room: interior_room,
                vehicle: vehicle
              })
    end

    # Exit a vehicle (disembark to where vehicle is parked)
    # @param character_instance [CharacterInstance] the character exiting
    # @return [Result] success with exit room, or error
    def exit_vehicle(character_instance)
      vehicle = character_instance.current_vehicle
      return error("You're not in a vehicle.") unless vehicle

      # Get the room where vehicle is parked
      exit_room = vehicle.respond_to?(:current_room) ? vehicle.current_room : nil

      # Fallback: try room_id
      exit_room ||= vehicle.respond_to?(:room_id) ? Room[vehicle.room_id] : nil

      return error('Cannot determine exit location.') unless exit_room

      interior_room = vehicle.interior_room

      DB.transaction do
        # Move character out of vehicle
        character_instance.update(
          current_room_id: exit_room.id,
          current_vehicle_id: nil
        )

        # Position in exit room
        if character_instance.respond_to?(:teleport_to_room!)
          character_instance.teleport_to_room!(exit_room)
        end

        # Schedule interior room for potential release
        schedule_interior_release(vehicle, interior_room)
      end

      success("You exit the #{vehicle_name(vehicle)}.", data: {
                room: exit_room,
                vehicle: vehicle
              })
    end

    # Save current interior customizations to the vehicle
    # This allows owner's decorations to persist across room pool reuse
    # @param vehicle [Vehicle] the vehicle to save customizations for
    # @return [Result] success or error
    def save_interior_customizations(vehicle)
      room = vehicle.interior_room
      return error('Vehicle has no interior room.') unless room

      custom_data = {
        'short_description' => room.short_description,
        'long_description' => room.long_description,
        'decorations' => []
      }

      # Save decorations
      if room.respond_to?(:decorations)
        custom_data['decorations'] = room.decorations.map do |dec|
          {
            'name' => dec.name,
            'description' => dec.description,
            'display_order' => dec.display_order
          }
        end
      end

      vehicle.update(custom_interior_data: Sequel.pg_jsonb_wrap(custom_data))

      success('Interior customizations saved.', data: { vehicle: vehicle })
    end

    # Clear interior customizations from a vehicle
    # @param vehicle [Vehicle] the vehicle to clear
    # @return [Result] success or error
    def clear_interior_customizations(vehicle)
      vehicle.update(custom_interior_data: Sequel.pg_jsonb_wrap({}))
      success('Interior customizations cleared.', data: { vehicle: vehicle })
    end

    # Get characters currently inside a vehicle
    # @param vehicle [Vehicle] the vehicle to check
    # @return [Array<CharacterInstance>] characters inside
    def characters_inside(vehicle)
      return [] unless vehicle.interior_room

      if vehicle.interior_room.respond_to?(:characters_here)
        vehicle.interior_room.characters_here.to_a
      else
        []
      end
    end

    # Check if a vehicle's interior is empty
    # @param vehicle [Vehicle] the vehicle to check
    # @return [Boolean] true if empty or no interior
    def interior_empty?(vehicle)
      return true unless vehicle.interior_room

      characters_inside(vehicle).empty?
    end

    # Force release a vehicle's interior room
    # Use with caution - will teleport any occupants out first
    # @param vehicle [Vehicle] the vehicle
    # @param force_eject [Boolean] if true, eject occupants first
    # @return [Result] success or error
    def release_interior(vehicle, force_eject: false)
      room = vehicle.interior_room
      return success('No interior to release.') unless room

      # Handle occupants
      occupants = characters_inside(vehicle)
      if occupants.any?
        return error('Interior still has occupants.') unless force_eject

        exit_room = vehicle.respond_to?(:current_room) ? vehicle.current_room : nil
        if exit_room
          occupants.each do |ci|
            ci.update(current_room_id: exit_room.id, current_vehicle_id: nil)
            ci.teleport_to_room!(exit_room) if ci.respond_to?(:teleport_to_room!)
          end
        else
          return error('Cannot eject occupants - no exit room.')
        end
      end

      # Clear vehicle's interior reference
      vehicle.update(interior_room_id: nil)

      # Release room to pool
      TemporaryRoomPoolService.release_room(room)

      success('Interior released.', data: { room: room })
    end

    private

    # Get display name for a vehicle
    # @param vehicle [Vehicle] the vehicle
    # @return [String] display name
    def vehicle_name(vehicle)
      name = vehicle.respond_to?(:name) ? vehicle.name : nil
      StringHelper.present?(name) ? name : 'vehicle'
    end

    # Schedule interior room for release if empty
    # @param vehicle [Vehicle] the vehicle
    # @param interior_room [Room] the interior room
    def schedule_interior_release(vehicle, interior_room)
      return unless interior_room&.is_temporary

      # Check if anyone else is still inside
      remaining = if interior_room.respond_to?(:characters_here)
                    interior_room.characters_here.count
                  else
                    0
                  end

      if remaining.zero?
        # Schedule for release after delay
        TemporaryRoomPoolService.schedule_release(interior_room)
      end
    end
  end
end
