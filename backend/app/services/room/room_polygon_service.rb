# frozen_string_literal: true

# Service for calculating and managing room polygon boundaries.
# Zone polygons act as physical walls - rooms wholly outside are deleted,
# rooms straddling the boundary have their usable area clipped.
class RoomPolygonService
  class << self
    # Recalculate all rooms in a location when zone polygon changes
    # - Deletes rooms wholly outside the polygon (relocating contents first)
    # - Updates effective_polygon for rooms straddling the boundary
    # - Clears effective_polygon for rooms fully inside
    # @param location [Location] the location to process
    # @return [Hash] { kept:, deleted:, relocated_characters:, relocated_items: }
    def recalculate_location(location)
      return { kept: 0, deleted: 0, relocated_characters: 0, relocated_items: 0 } unless location.zone&.has_polygon?

      kept = 0
      deleted = 0
      relocated_chars = 0
      relocated_items = 0

      # Process rooms - collect rooms to delete first to find relocation targets
      rooms_to_delete = []
      rooms_to_update = []

      # Query rooms fresh from database to avoid Sequel association caching
      Room.where(location_id: location.id).each do |room|
        result = PolygonClippingService.clip_room_to_zone(room)

        if result.nil?
          # Room wholly outside - mark for deletion
          rooms_to_delete << room
        else
          # Room has usable area - mark for update
          rooms_to_update << { room: room, result: result }
        end
      end

      # First update rooms that have usable area (so they can be relocation targets)
      rooms_to_update.each do |update_data|
        room = update_data[:room]
        result = update_data[:result]

        room.update(
          effective_polygon: result[:polygon] ? Sequel.pg_jsonb_wrap(result[:polygon]) : nil,
          effective_area: result[:area],
          usable_percentage: result[:percentage],
          outside_polygon: false
        )
        kept += 1
      end

      # Now delete rooms that are wholly outside (after valid rooms exist for relocation)
      rooms_to_delete.each do |room|
        # Skip if room was already deleted (e.g., by cascade)
        next unless Room.where(id: room.id).count > 0

        relocated = relocate_room_contents(room, location)
        relocated_chars += relocated[:characters]
        relocated_items += relocated[:items]

        room.cleanup_contents!
        Room.where(id: room.id).delete
        deleted += 1
      end

      { kept: kept, deleted: deleted,
        relocated_characters: relocated_chars,
        relocated_items: relocated_items }
    end

    # Batch mark all rooms in location based on polygon
    # Alias for recalculate_location for backward compatibility
    # @param location [Location] the location to process
    # @return [Hash] { inside: count, outside: count } (backward compatible format)
    def mark_rooms_for_location(location)
      result = recalculate_location(location)

      # Return backward-compatible format
      { inside: result[:kept], outside: result[:deleted] }
    end

    # Recalculate all rooms in a zone (when zone polygon changes)
    # Processes all city locations in the zone
    # @param zone [Zone] the zone to process
    # @return [Hash] { locations:, kept:, deleted:, relocated_characters:, relocated_items: }
    def recalculate_zone(zone)
      return { locations: 0, kept: 0, deleted: 0, relocated_characters: 0, relocated_items: 0 } unless zone.has_polygon?

      totals = { locations: 0, kept: 0, deleted: 0, relocated_characters: 0, relocated_items: 0 }

      zone.locations.each do |location|
        result = recalculate_location(location)
        totals[:locations] += 1
        totals[:kept] += result[:kept]
        totals[:deleted] += result[:deleted]
        totals[:relocated_characters] += result[:relocated_characters]
        totals[:relocated_items] += result[:relocated_items]
      end

      # Backward compatibility aliases
      totals[:inside] = totals[:kept]
      totals[:outside] = totals[:deleted]

      totals
    end

    # Relocate characters and items from a room being deleted
    # @param room [Room] the room being deleted
    # @param location [Location] the location to find target room in
    # @return [Hash] { characters:, items: }
    def relocate_room_contents(room, location)
      target_room = find_nearest_valid_room(room, location)

      unless target_room
        warn "[RoomPolygonService] No valid relocation target for room #{room.id} - contents will be orphaned"
        return { characters: 0, items: 0 }
      end

      char_count = room.character_instances_dataset.count
      item_count = room.objects_dataset.count

      # Move characters to center of target room's usable area
      target_x, target_y = valid_center_position(target_room)

      room.character_instances_dataset.each do |ci|
        ci.update(
          current_room_id: target_room.id,
          x: target_x,
          y: target_y
        )
      end

      # Move items to target room
      room.objects_dataset.update(room_id: target_room.id)

      { characters: char_count, items: item_count }
    end

    # Find nearest room with usable area to relocate contents
    # @param source_room [Room] the room being deleted
    # @param location [Location] the location to search in
    # @return [Room, nil]
    def find_nearest_valid_room(source_room, location)
      # Find rooms with usable area, ordered by distance from source room center
      # Use Room dataset directly since location.rooms returns array
      Room.where(location_id: location.id)
        .exclude(id: source_room.id)
        .where { usable_percentage > 0 }
        .all
        .min_by do |room|
          # Calculate distance between room centers
          dx = room.center_x - source_room.center_x
          dy = room.center_y - source_room.center_y
          Math.sqrt(dx * dx + dy * dy)
        end
    end

    # Validate room creation against zone polygon
    # @param location [Location] the location where room would be created
    # @param min_x [Float] room bounds
    # @param max_x [Float] room bounds
    # @param min_y [Float] room bounds
    # @param max_y [Float] room bounds
    # @return [Boolean] true if room would have any usable area
    def can_create_room?(location, min_x:, max_x:, min_y:, max_y:)
      zone_polygon = location.zone_polygon_in_feet
      return true unless zone_polygon&.any?

      room_rect = [
        { x: min_x.to_f, y: min_y.to_f },
        { x: max_x.to_f, y: min_y.to_f },
        { x: max_x.to_f, y: max_y.to_f },
        { x: min_x.to_f, y: max_y.to_f }
      ]

      intersection = PolygonClippingService.sutherland_hodgman_clip(room_rect, zone_polygon)
      intersection.any? # True if any usable area would exist
    end

    # Check if a grid position is inside the polygon
    # @param location [Location] the location containing the grid
    # @param grid_x [Integer] grid X coordinate
    # @param grid_y [Integer] grid Y coordinate
    # @return [Boolean]
    def grid_position_accessible?(location, grid_x, grid_y)
      return true unless location.zone&.has_polygon?

      cell_size = defined?(GridCalculationService::GRID_CELL_SIZE) ? GridCalculationService::GRID_CELL_SIZE : 175

      # Convert grid position to feet coordinates (center of cell)
      center_x = grid_x * cell_size + (cell_size / 2.0)
      center_y = grid_y * cell_size + (cell_size / 2.0)

      location.city_point_in_zone?(center_x, center_y)
    end

    # Get all grid positions inside the polygon
    # @param location [Location] the city location
    # @return [Array<Hash>] array of { grid_x:, grid_y: } for accessible positions
    def accessible_grid_positions(location)
      return [] unless location.is_city?

      positions = []
      v_streets = location.vertical_streets || 1
      h_streets = location.horizontal_streets || 1

      (0...v_streets).each do |x|
        (0...h_streets).each do |y|
          if grid_position_accessible?(location, x, y)
            positions << { grid_x: x, grid_y: y }
          end
        end
      end

      positions
    end

    # Get count of accessible vs inaccessible grid positions
    # Useful for previewing how much of a city will be accessible
    # @param location [Location] the city location
    # @return [Hash] { total:, accessible:, inaccessible:, percentage: }
    def grid_accessibility_stats(location)
      return { total: 0, accessible: 0, inaccessible: 0, percentage: 100 } unless location.is_city?

      v_streets = location.vertical_streets || 1
      h_streets = location.horizontal_streets || 1
      total = v_streets * h_streets

      accessible = accessible_grid_positions(location).count
      inaccessible = total - accessible
      percentage = total > 0 ? (accessible.to_f / total * 100).round(1) : 100

      { total: total, accessible: accessible, inaccessible: inaccessible, percentage: percentage }
    end

    # Reset all rooms in a location (clear effective polygons)
    # Use when zone polygon is removed
    # @param location [Location] the location to reset
    # @return [Integer] count of rooms updated
    def reset_location_polygon_status(location)
      Room.where(location_id: location.id).update(
        outside_polygon: false,
        effective_polygon: nil,
        effective_area: nil,
        usable_percentage: 1.0
      )
    end

    # Check if a room would be inside the polygon (without modifying the room)
    # @param room [Room] the room to check
    # @return [Boolean]
    def room_inside_polygon?(room)
      room.inside_zone_polygon?
    end

    # Check if a room would have any usable area with current zone polygon
    # @param room [Room] the room to check
    # @return [Boolean]
    def room_has_usable_area?(room)
      result = PolygonClippingService.clip_room_to_zone(room)
      !result.nil?
    end

    private

    # Get a valid center position in a room (accounting for effective polygon)
    # @param room [Room] the target room
    # @return [Array<Float>] [x, y] coordinates
    def valid_center_position(room)
      # Start with room center
      center_x = room.center_x
      center_y = room.center_y

      # If room has effective polygon, ensure position is inside it
      if room.is_clipped?
        unless room.position_valid?(center_x, center_y)
          # Find nearest valid position
          valid_pos = room.nearest_valid_position(center_x, center_y)
          return [valid_pos[:x], valid_pos[:y]] if valid_pos
        end
      end

      [center_x, center_y]
    end
  end
end
