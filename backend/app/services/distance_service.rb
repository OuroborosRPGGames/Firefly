# frozen_string_literal: true

require_relative '../helpers/canvas_helper'

class DistanceService
  # Milliseconds per coordinate unit of distance
  BASE_MS_PER_UNIT = 175

  class << self
    # Calculate Manhattan-style distance with weighted diagonals
    # Uses the same algorithm as Ravencroft for consistency
    def calculate_distance(from_x, from_y, from_z, to_x, to_y, to_z)
      xdiff = (from_x - to_x).abs
      ydiff = (from_y - to_y).abs
      zdiff = (from_z - to_z).abs

      z_threshold = GameConfig::Distance::LIMITS[:z_diff_threshold]
      z_multiplier = GameConfig::Distance::LIMITS[:z_diff_multiplier]
      diagonal_divisor = GameConfig::Distance::LIMITS[:diagonal_divisor]

      # Weighted diagonal movement - z changes are expensive
      if zdiff > 0 && xdiff < z_threshold && ydiff < z_threshold
        zdiff * z_multiplier + xdiff + ydiff
      elsif xdiff > ydiff
        xdiff + ydiff / diagonal_divisor + zdiff / diagonal_divisor
      else
        ydiff + xdiff / diagonal_divisor + zdiff / diagonal_divisor
      end
    end

    # Calculate time to traverse distance in milliseconds
    def time_for_distance(distance, speed_multiplier = 1.0)
      (distance * BASE_MS_PER_UNIT * speed_multiplier).to_i
    end

    # Calculate time for a character to reach a room exit
    def time_to_exit(character_instance, room_exit, speed_multiplier = 1.0)
      char_pos = character_instance.position
      exit_pos = exit_position_in_room(room_exit)

      distance = calculate_distance(
        char_pos[0], char_pos[1], char_pos[2],
        exit_pos[0], exit_pos[1], exit_pos[2]
      )

      time_for_distance(distance, speed_multiplier)
    end

    # Get the position of an exit in its source room
    def exit_position_in_room(room_exit)
      # Check if exit has explicit position (new column may not exist in all envs)
      if room_exit.respond_to?(:from_x) && room_exit.from_x && room_exit.from_y && room_exit.from_z
        [room_exit.from_x, room_exit.from_y, room_exit.from_z]
      else
        # Default: derive position from direction and room bounds
        default_exit_position(room_exit)
      end
    end

    # Get arrival position in destination room
    def arrival_position(room_exit)
      # Check if exit has explicit position (new column may not exist in all envs)
      if room_exit.respond_to?(:to_x) && room_exit.to_x && room_exit.to_y && room_exit.to_z
        [room_exit.to_x, room_exit.to_y, room_exit.to_z]
      else
        # Default: opposite wall from exit direction
        default_arrival_position(room_exit)
      end
    end

    # Calculate wall position for cardinal direction
    def wall_position(room, direction)
      # Use defaults if room doesn't have coordinate bounds
      min_x = room.respond_to?(:min_x) && room.min_x || 0.0
      max_x = room.respond_to?(:max_x) && room.max_x || 100.0
      min_y = room.respond_to?(:min_y) && room.min_y || 0.0
      max_y = room.respond_to?(:max_y) && room.max_y || 100.0
      min_z = room.respond_to?(:min_z) && room.min_z || 0.0
      max_z = room.respond_to?(:max_z) && room.max_z || 10.0

      center_x = (min_x + max_x) / 2.0
      center_y = (min_y + max_y) / 2.0
      center_z = (min_z + max_z) / 2.0

      case direction.to_s.downcase
      when 'north'
        [center_x, max_y, center_z]
      when 'south'
        [center_x, min_y, center_z]
      when 'east'
        [max_x, center_y, center_z]
      when 'west'
        [min_x, center_y, center_z]
      when 'up'
        [center_x, center_y, max_z]
      when 'down'
        [center_x, center_y, min_z]
      when 'northeast'
        [max_x, max_y, center_z]
      when 'northwest'
        [min_x, max_y, center_z]
      when 'southeast'
        [max_x, min_y, center_z]
      when 'southwest'
        [min_x, min_y, center_z]
      else
        [center_x, center_y, center_z]
      end
    end

    # Calculate distance from character position to wall
    def distance_to_wall(character_instance, direction)
      room = character_instance.current_room
      char_pos = character_instance.position
      wall_pos = wall_position(room, direction)

      calculate_distance(
        char_pos[0], char_pos[1], char_pos[2],
        wall_pos[0], wall_pos[1], wall_pos[2]
      )
    end

    # Get a randomized arrival position within a cone from entrance toward room center.
    # Produces natural "stepping into the room" placement instead of exact boundary points.
    def randomized_arrival_position(room_exit)
      base = arrival_position(room_exit)
      to_room = room_exit.to_room

      # Calculate vector from entrance toward room center
      cx = to_room.center_x
      cy = to_room.center_y
      dx = cx - base[0]
      dy = cy - base[1]
      dist = Math.sqrt(dx * dx + dy * dy)

      # If entrance is already at center (or very close), just return base
      return base if dist < 1.0

      # Random distance: 0–40% of the way toward center
      r = rand * 0.4
      # Random angle offset: ±15 degrees
      angle_offset = (rand * 30.0 - 15.0) * Math::PI / 180.0

      # Base angle from entrance to center
      base_angle = Math.atan2(dy, dx)
      final_angle = base_angle + angle_offset

      new_x = base[0] + Math.cos(final_angle) * dist * r
      new_y = base[1] + Math.sin(final_angle) * dist * r

      # Validate position, fallback gracefully
      if to_room.position_valid?(new_x, new_y)
        [new_x, new_y, base[2]]
      else
        nearest = to_room.nearest_valid_position(new_x, new_y)
        if nearest
          [nearest[:x], nearest[:y], base[2]]
        else
          base
        end
      end
    end

    private

    def default_exit_position(room_exit)
      from_room = safe_room_lookup(room_exit, :from_room)
      to_room = safe_room_lookup(room_exit, :to_room)

      # Use shared boundary midpoint if both rooms have geometry
      if from_room && to_room
        boundary_crossing_point(from_room, to_room)
      else
        wall_position(from_room, room_exit.direction)
      end
    end

    def default_arrival_position(room_exit)
      from_room = safe_room_lookup(room_exit, :from_room)
      to_room = safe_room_lookup(room_exit, :to_room)

      # Use shared boundary midpoint if both rooms have geometry
      if from_room && to_room
        boundary_crossing_point(from_room, to_room)
      else
        opposite = opposite_direction(room_exit.direction)
        wall_position(to_room, opposite)
      end
    end

    # Compute the crossing point between two rooms based on their shared boundary.
    # For overlapping rooms (intersections within streets), returns the overlap center.
    # For adjacent rooms (sharing an edge), returns the shared edge midpoint.
    # For separated rooms, returns the nearest point on destination from source center.
    def boundary_crossing_point(from_room, to_room)
      from_min_x = from_room.min_x.to_f
      from_max_x = from_room.max_x.to_f
      from_min_y = from_room.min_y.to_f
      from_max_y = from_room.max_y.to_f

      to_min_x = to_room.min_x.to_f
      to_max_x = to_room.max_x.to_f
      to_min_y = to_room.min_y.to_f
      to_max_y = to_room.max_y.to_f

      # Find the overlap region between the two rooms' bounding boxes
      overlap_min_x = [from_min_x, to_min_x].max
      overlap_max_x = [from_max_x, to_max_x].min
      overlap_min_y = [from_min_y, to_min_y].max
      overlap_max_y = [from_max_y, to_max_y].min

      center_z = ((to_room.min_z || 0.0).to_f + (to_room.max_z || 10.0).to_f) / 2.0

      if overlap_min_x <= overlap_max_x && overlap_min_y <= overlap_max_y
        # Rooms overlap or share an edge - use midpoint of overlap region
        mid_x = (overlap_min_x + overlap_max_x) / 2.0
        mid_y = (overlap_min_y + overlap_max_y) / 2.0
        [mid_x, mid_y, center_z]
      else
        # No overlap - project source center onto destination boundary
        from_cx = (from_min_x + from_max_x) / 2.0
        from_cy = (from_min_y + from_max_y) / 2.0
        x = from_cx.clamp(to_min_x, to_max_x)
        y = from_cy.clamp(to_min_y, to_max_y)
        [x, y, center_z]
      end
    end

    def opposite_direction(direction)
      CanvasHelper.opposite_direction(direction, fallback: 'center')
    end

    def safe_room_lookup(room_exit, association)
      room_exit.public_send(association)
    rescue StandardError => e
      warn "[DistanceService] Failed to read #{association} for room_exit #{room_exit&.id}: #{e.message}"
      nil
    end
  end
end
