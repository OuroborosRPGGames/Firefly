# frozen_string_literal: true

# TemporaryRoomPoolService manages a pool of reusable temporary rooms
# for vehicles, taxis, world travel, and other instances that need
# temporary spaces.
#
# When a temporary room becomes empty, it's released back to the pool
# and can be reused for the next request. This avoids constantly
# creating and destroying rooms.
#
# Usage:
#   # Acquire a room for a vehicle
#   result = TemporaryRoomPoolService.acquire_for_vehicle(vehicle)
#   room = result[:room] if result.success?
#
#   # Acquire a room for a world journey
#   result = TemporaryRoomPoolService.acquire_for_journey(journey)
#
#   # Release a room back to pool
#   TemporaryRoomPoolService.release_room(room)
#
class TemporaryRoomPoolService
  extend ResultHandler

  RELEASE_DELAY_SECONDS = GameConfig::Rooms::TEMP_POOL_RELEASE_DELAY_SECONDS


  # Default pool sizes by category
  POOL_SIZES = {
    'sedan' => 5,
    'suv' => 3,
    'bus' => 2,
    'taxi' => 10,
    'train' => 5,
    'shuttle' => 3,
    'carriage' => 5,
    'hansom' => 5,
    'delve' => 20
  }.freeze

  DEFAULT_POOL_SIZE = 3

  class << self
    # Acquire a temporary room for a vehicle
    # @param vehicle [Vehicle] the vehicle needing an interior room
    # @return [Result] with :room key containing the acquired Room
    def acquire_for_vehicle(vehicle)
      template = resolve_template_for_vehicle(vehicle)
      return error("No template found for vehicle type: #{vehicle.vehicle_type || vehicle.vtype}") unless template

      room = acquire_room(template, for_vehicle: vehicle)
      return error('No rooms available in pool') unless room

      # Update vehicle with interior room reference
      vehicle.update(interior_room_id: room.id)

      # Apply any custom interior data from the vehicle
      apply_vehicle_customizations(room, vehicle) if vehicle.custom_interior_data&.any?

      success('Interior room acquired', data: { room: room, vehicle: vehicle })
    end

    # Acquire a temporary room for a delve
    # @param delve [Delve] the delve needing a dungeon room
    # @return [Result] with :room key containing the acquired Room
    def acquire_for_delve(delve)
      template = RoomTemplate.first(template_type: 'delve_room', active: true)
      return error('No delve room template found') unless template

      room = acquire_room(template, for_delve: delve)
      return error('No rooms available in pool') unless room

      success('Delve room acquired', data: { room: room, delve: delve })
    end

    # Release all temporary rooms associated with a delve back to the pool
    # @param delve [Delve] the delve whose rooms should be released
    # @return [Result] with :count key containing the number of rooms released
    def release_delve_rooms(delve)
      rooms = Room.where(temp_delve_id: delve.id, is_temporary: true).all
      count = 0

      rooms.each do |room|
        RoomFeature.where(room_id: room.id).delete
        RoomHex.where(room_id: room.id).delete
        reset_room_for_pool(room)
        count += 1
      end

      success('Delve rooms released', data: { count: count })
    end

    # Acquire a temporary room for a world journey
    # @param journey [WorldJourney] the journey needing a shared compartment
    # @return [Result] with :room key containing the acquired Room
    def acquire_for_journey(journey)
      template = resolve_template_for_journey(journey)
      return error("No template found for journey type: #{journey.vehicle_type}") unless template

      room = acquire_room(template, for_journey: journey)
      return error('No rooms available in pool') unless room

      # Update journey with interior room reference
      journey.update(interior_room_id: room.id)

      # Customize room description for this specific journey
      customize_journey_room(room, journey)

      success('Journey compartment acquired', data: { room: room, journey: journey })
    end

    # Release a temporary room back to the pool
    # @param room [Room] the room to release
    # @return [Result] success or error
    def release_room(room)
      return error('Room is not temporary') unless room.is_temporary
      return error('Room is not in use') unless room.pool_status == 'in_use'

      # Check for occupants
      if room.respond_to?(:characters_here) && room.characters_here.any?
        return error('Room still has occupants')
      end

      # Reset room state for pool
      reset_room_for_pool(room)

      success('Room released to pool', data: { room: room })
    end

    # Schedule a room for release after the delay period
    # @param room [Room] the room to schedule
    def schedule_release(room)
      return unless room&.is_temporary && room.pool_status == 'in_use'

      room.update(
        pool_release_after: Time.now + GameConfig::Rooms::TEMP_POOL_RELEASE_DELAY_SECONDS,
        pool_last_used_at: Time.now
      )
    end

    # Check and release empty temporary rooms that have passed their release time
    # This should be called periodically by a background job
    def check_and_release_empty_rooms
      released_count = 0

      Room.where(is_temporary: true, pool_status: 'in_use')
          .where { pool_release_after < Time.now }
          .each do |room|
        if room.respond_to?(:characters_here) && room.characters_here.count.zero?
          release_room(room)
          released_count += 1
        else
          # Still occupied - extend release time
          room.update(pool_release_after: Time.now + GameConfig::Rooms::TEMP_POOL_RELEASE_DELAY_SECONDS)
        end
      end

      released_count
    end

    # Pre-populate pool rooms for a template in a location
    # @param location [Location] location to create pool rooms in
    # @param template [RoomTemplate] the template to use
    # @param count [Integer, nil] number of rooms to ensure (defaults to pool size)
    def ensure_pool_size(location, template, count: nil)
      target_size = count || (POOL_SIZES[template.category] || DEFAULT_POOL_SIZE)

      current_count = Room.where(
        location_id: location.id,
        room_template_id: template.id,
        is_temporary: true,
        pool_status: 'available'
      ).count

      rooms_created = 0
      (target_size - current_count).times do
        create_pool_room(location, template)
        rooms_created += 1
      end

      rooms_created
    end

    # Get statistics about the room pool
    # @return [Hash] pool statistics
    def pool_stats
      {
        total_temporary: Room.where(is_temporary: true).count,
        available: Room.where(is_temporary: true, pool_status: 'available').count,
        in_use: Room.where(is_temporary: true, pool_status: 'in_use').count,
        by_template: Room.where(is_temporary: true)
                         .exclude(room_template_id: nil)
                         .group_and_count(:room_template_id, :pool_status)
                         .all
      }
    end

    private

    # Get or create a room from the pool
    # @param template [RoomTemplate] the template to use
    # @param for_vehicle [Vehicle, nil] the vehicle requesting the room
    # @param for_journey [WorldJourney, nil] the journey requesting the room
    # @param for_delve [Delve, nil] the delve requesting the room
    # @return [Room, nil] the acquired room or nil
    def acquire_room(template, for_vehicle: nil, for_journey: nil, for_delve: nil)
      location = resolve_pool_location(template)
      return nil unless location

      # First, try to get an available room matching this template
      room = Room.where(
        room_template_id: template.id,
        is_temporary: true,
        pool_status: 'available'
      ).first

      # If none available, create one
      room ||= create_pool_room(location, template)

      return nil unless room

      # Mark as in use and clear any stale battle map from previous use
      spatial_group = for_delve ? "delve:#{for_delve.id}" : nil
      DB.transaction do
        room.room_hexes_dataset.delete if room.has_battle_map
        room.update(
          pool_status: 'in_use',
          pool_acquired_at: Time.now,
          pool_last_used_at: Time.now,
          pool_release_after: Time.now + GameConfig::Rooms::TEMP_POOL_RELEASE_DELAY_SECONDS,
          temp_vehicle_id: for_vehicle&.id,
          temp_journey_id: for_journey&.id,
          temp_delve_id: for_delve&.id,
          spatial_group_id: spatial_group,
          has_battle_map: false,
          battle_map_image_url: nil
        )
      end

      room
    end

    # Create a new room in the pool from a template
    # @param location [Location] location for the room
    # @param template [RoomTemplate] template to use
    # @return [Room] the created room
    def create_pool_room(location, template)
      room = template.instantiate_room(location: location)
      template.setup_default_places(room)
      room
    end

    # Reset a room for reuse in the pool
    # @param room [Room] the room to reset
    def reset_room_for_pool(room)
      template = room.room_template

      DB.transaction do
        # Clear temporary associations
        room.update(
          pool_status: 'available',
          pool_acquired_at: nil,
          pool_release_after: nil,
          temp_vehicle_id: nil,
          temp_journey_id: nil,
          temp_delve_id: nil,
          has_custom_interior: false,
          has_battle_map: false,
          spatial_group_id: nil
        )

        # Clear dynamic content (places, decorations, etc.)
        room.places_dataset.delete if room.respond_to?(:places_dataset)
        room.decorations_dataset.delete if room.respond_to?(:decorations_dataset)
        room.graffiti_dataset.delete if room.respond_to?(:graffiti_dataset)

        # Note: No exits to clear - navigation uses spatial adjacency

        # Restore template defaults
        if template
          room.update(
            short_description: template.short_description,
            long_description: template.long_description
          )
          template.setup_default_places(room)
        end
      end
    end

    # Resolve the appropriate template for a vehicle
    # @param vehicle [Vehicle] the vehicle
    # @return [RoomTemplate, nil]
    def resolve_template_for_vehicle(vehicle)
      # Check for preferred template first
      if vehicle.respond_to?(:preferred_template) && vehicle.preferred_template
        return vehicle.preferred_template
      end

      # Otherwise, resolve by vehicle type
      vehicle_type = vehicle.vehicle_type || vehicle.vtype || 'sedan'
      RoomTemplate.for_vehicle_type(vehicle_type)
    end

    # Resolve the appropriate template for a world journey
    # @param journey [WorldJourney] the journey
    # @return [RoomTemplate, nil]
    def resolve_template_for_journey(journey)
      RoomTemplate.for_journey(
        travel_mode: journey.travel_mode,
        vehicle_type: journey.vehicle_type
      )
    end

    # Get or create a location for storing pool rooms
    # Pool rooms need to belong to a location but are never navigated to directly
    # @param template [RoomTemplate] the template (for universe context)
    # @return [Location, nil]
    def resolve_pool_location(template)
      # Try to find an existing pool location
      pool_location = Location.first(name: 'Room Pool')
      return pool_location if pool_location

      # Need to create one - find or create a zone first
      universe = template&.universe || Universe.first
      return nil unless universe

      world = universe.worlds_dataset.first
      return nil unless world

      # Find or create a pool zone (use first zone if no dedicated pool zone)
      zone = world.zones_dataset.first
      return nil unless zone

      # Create the pool location
      Location.create(
        zone_id: zone.id,
        world_id: world.id,
        name: 'Room Pool',
        location_type: 'building'
      )
    rescue Sequel::ValidationFailed => e
      warn "[TemporaryRoomPoolService] Failed to create pool location: #{e.message}"
      nil
    end

    # Apply vehicle owner's customizations to a room
    # @param room [Room] the room to customize
    # @param vehicle [Vehicle] the vehicle with custom data
    def apply_vehicle_customizations(room, vehicle)
      custom_data = vehicle.custom_interior_data
      return unless custom_data.is_a?(Hash) && custom_data.any?

      updates = {}
      updates[:short_description] = custom_data['short_description'] if custom_data['short_description']
      updates[:long_description] = custom_data['long_description'] if custom_data['long_description']
      updates[:has_custom_interior] = true

      room.update(updates) if updates.any?

      # Restore custom decorations if stored
      if custom_data['decorations'].is_a?(Array)
        custom_data['decorations'].each do |dec_data|
          next unless dec_data.is_a?(Hash)

          Decoration.create(
            room_id: room.id,
            name: dec_data['name'],
            description: dec_data['description'],
            display_order: dec_data['display_order'] || 0
          )
        rescue Sequel::ValidationFailed
          # Skip invalid decorations
        end
      end
    end

    # Customize a room for a specific journey
    # @param room [Room] the room to customize
    # @param journey [WorldJourney] the journey
    def customize_journey_room(room, journey)
      destination_name = journey.respond_to?(:destination_location) &&
                         journey.destination_location&.name || 'Unknown Destination'

      terrain_desc = if journey.respond_to?(:terrain_description)
                       journey.terrain_description
                     else
                       'the passing landscape'
                     end

      vehicle_desc = if journey.respond_to?(:vehicle_description)
                       journey.vehicle_description
                     else
                       "A #{journey.vehicle_type || 'vehicle'}"
                     end

      room.update(
        short_description: "Traveling to #{destination_name}",
        long_description: "#{vehicle_desc}.\n\nOutside, you can see #{terrain_desc}."
      )
    end
  end
end
