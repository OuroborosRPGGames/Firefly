# frozen_string_literal: true
require_relative '../concerns/pathfinding_helper'

# HexPathfindingService provides A* pathfinding on the hex grid
# for connecting cities with roads/railways through intervening hexes
#
# Supports multiple travel modes:
# - nil/land: Standard terrain-based pathfinding
# - water: Boats/ships - prefers water, land is very expensive
# - rail: Trains - only follows railway features
#
# NOTE: For globe-based world pathfinding, prefer GlobePathfindingService.
# This service uses flat hex grid coordinates and encodes (x, y) pairs
# into globe_hex_ids for WorldHex lookups.

class HexPathfindingService
  MAX_PATH_LENGTH = 500

  # Encode (x, y) hex grid coordinates into a unique globe_hex_id for WorldHex lookups.
  # Provides backward compatibility for flat hex grid pathfinding with the
  # globe_hex_id-based WorldHex model.
  # @param x [Integer] hex X coordinate
  # @param y [Integer] hex Y coordinate
  # @return [Integer] unique globe_hex_id
  def self.coords_to_globe_hex_id(x, y)
    (x + 10000) * 100000 + (y + 10000)
  end

  class << self
    include PathfindingHelper
    # Find a path between two hex coordinates using A*
    # @param world [World] the world to search in
    # @param start_x [Integer] starting hex X
    # @param start_y [Integer] starting hex Y
    # @param end_x [Integer] ending hex X
    # @param end_y [Integer] ending hex Y
    # @param avoid_water [Boolean] whether to avoid ocean/lake hexes (only applies to land mode)
    # @param travel_mode [String, nil] travel mode: nil/'land', 'water', or 'rail'
    # @return [Array<Array<Integer>>] array of [x, y] coordinates or empty array
    def find_path(world:, start_x:, start_y:, end_x:, end_y:, avoid_water: true, travel_mode: nil)
      return [] unless HexGrid.valid_hex_coords?(start_x, start_y)
      return [] unless HexGrid.valid_hex_coords?(end_x, end_y)
      return [[start_x, start_y]] if start_x == end_x && start_y == end_y

      # A* implementation
      open_set = Set.new([[start_x, start_y]])
      came_from = {}

      g_score = Hash.new(Float::INFINITY)
      g_score[[start_x, start_y]] = 0

      f_score = Hash.new(Float::INFINITY)
      f_score[[start_x, start_y]] = heuristic(start_x, start_y, end_x, end_y)

      while open_set.any?
        # Get node with lowest f_score
        current = open_set.min_by { |node| f_score[node] }

        if current == [end_x, end_y]
          return reconstruct_path(came_from, current)
        end

        open_set.delete(current)

        # Limit path length to prevent infinite loops
        next if g_score[current] > MAX_PATH_LENGTH

        # Check all neighbors
        neighbors = HexGrid.hex_neighbors(current[0], current[1])
        neighbors.each do |neighbor|
          # Calculate movement cost based on travel mode
          move_cost = movement_cost_for_mode(world, current, neighbor, travel_mode, avoid_water)

          # Skip impassable terrain
          next if move_cost >= Float::INFINITY

          tentative_g = g_score[current] + move_cost

          if tentative_g < g_score[neighbor]
            came_from[neighbor] = current
            g_score[neighbor] = tentative_g
            f_score[neighbor] = tentative_g + heuristic(neighbor[0], neighbor[1], end_x, end_y)

            open_set.add(neighbor) unless open_set.include?(neighbor)
          end
        end
      end

      [] # No path found
    end

    # Calculate distance between two hex coordinates
    # @param x1 [Integer] first hex X
    # @param y1 [Integer] first hex Y
    # @param x2 [Integer] second hex X
    # @param y2 [Integer] second hex Y
    # @return [Integer] distance in hexes
    def distance(x1, y1, x2, y2)
      HexGrid.hex_distance(x1, y1, x2, y2)
    end

    # Get neighbors of a hex coordinate
    # @param x [Integer] hex X
    # @param y [Integer] hex Y
    # @return [Array<Array<Integer>>] array of [x, y] neighbor coordinates
    def neighbors(x, y)
      HexGrid.hex_neighbors(x, y)
    end

    # Check line of sight between two hexes
    # Uses hex line algorithm to check each hex along the path
    # @param world_or_room [World, Room] the world or room to check in
    # @param x1 [Integer] first hex X
    # @param y1 [Integer] first hex Y
    # @param x2 [Integer] second hex X
    # @param y2 [Integer] second hex Y
    # @param viewer_elevation [Integer] elevation of viewer (for room hexes)
    # @return [Boolean] true if line of sight is clear
    def line_of_sight?(world_or_room:, x1:, y1:, x2:, y2:, viewer_elevation: 0)
      return true if x1 == x2 && y1 == y2

      # Get hexes along the line using lerp algorithm
      line_hexes = hex_line(x1, y1, x2, y2)

      # Check each hex along the line (excluding start and end)
      line_hexes[1..-2].each do |hex_coords|
        hx, hy = hex_coords

        if world_or_room.is_a?(World)
          # World-level LoS (terrain blocks sight)
          globe_id = HexPathfindingService.coords_to_globe_hex_id(hx, hy)
          hex = WorldHex.hex_details(world_or_room, globe_id)
          return false if hex&.blocks_sight?
        elsif world_or_room.is_a?(Room)
          # Room-level LoS (cover/walls block sight)
          room_hex = RoomHex.hex_details(world_or_room, hx, hy)
          return false if room_hex&.blocks_los_at_elevation?(viewer_elevation)
        end
      end

      true
    end

    # Determine direction from one hex to an adjacent hex
    # Returns one of WorldHex::DIRECTIONS ('n', 'ne', 'se', 's', 'sw', 'nw')
    # @param from_x [Integer] source hex X
    # @param from_y [Integer] source hex Y
    # @param to_x [Integer] destination hex X
    # @param to_y [Integer] destination hex Y
    # @return [String] direction from source to destination
    def direction_between(from_x, from_y, to_x, to_y)
      dx = to_x - from_x
      dy = to_y - from_y

      if dy > 0
        # Moving north (y increasing)
        return 'n' if dx == 0

        dx > 0 ? 'ne' : 'nw'
      elsif dy < 0
        # Moving south (y decreasing)
        return 's' if dx == 0

        dx > 0 ? 'se' : 'sw'
      else
        # Horizontal movement (same y row)
        # Map to closest diagonal direction
        dx > 0 ? 'se' : 'sw'
      end
    end

    # Build a path of features between two hexes
    # Sets directional features on each hex along the path
    # @param world [World] the world to modify
    # @param start_x [Integer] starting hex X
    # @param start_y [Integer] starting hex Y
    # @param end_x [Integer] ending hex X
    # @param end_y [Integer] ending hex Y
    # @param feature_type [String] type of feature (road, highway, railway, trail)
    # @return [Hash] result with :success, :path_length, :hexes_updated
    def build_feature_path(world:, start_x:, start_y:, end_x:, end_y:, feature_type:)
      unless WorldHex::FEATURE_TYPES.include?(feature_type)
        return { success: false, error: 'Invalid feature type' }
      end

      path = find_path(
        world: world,
        start_x: start_x,
        start_y: start_y,
        end_x: end_x,
        end_y: end_y,
        avoid_water: !%w[river canal].include?(feature_type)
      )

      if path.length < 2
        return { success: false, error: 'Could not find path between points' }
      end

      hexes_updated = 0

      # Set directional features along the path
      path.each_cons(2) do |current, next_hex|
        # Determine direction from current to next
        direction = direction_between(current[0], current[1], next_hex[0], next_hex[1])
        opposite = WorldHex::DIRECTION_OPPOSITES[direction]

        # Set feature on current hex pointing to next
        current_globe_id = HexPathfindingService.coords_to_globe_hex_id(current[0], current[1])
        current_hex = WorldHex.set_hex_details(world, current_globe_id)
        if current_hex
          current_hex.set_directional_feature(direction, feature_type)
          hexes_updated += 1
        end

        # Set feature on next hex pointing back (bidirectional)
        next_globe_id = HexPathfindingService.coords_to_globe_hex_id(next_hex[0], next_hex[1])
        next_hex_obj = WorldHex.set_hex_details(world, next_globe_id)
        next_hex_obj&.set_directional_feature(opposite, feature_type)
      end

      {
        success: true,
        path_length: path.length,
        hexes_updated: hexes_updated,
        path: path
      }
    end

    private

    # Heuristic: hex distance to goal
    def heuristic(x1, y1, x2, y2)
      HexGrid.hex_distance(x1, y1, x2, y2)
    end

    # Movement cost considering travel mode
    # @param world [World] the world
    # @param from_coords [Array<Integer>] [x, y] source hex
    # @param to_coords [Array<Integer>] [x, y] destination hex
    # @param travel_mode [String, nil] travel mode: nil/'land', 'water', or 'rail'
    # @param avoid_water [Boolean] for land mode, whether to avoid water
    # @return [Float] movement cost (Float::INFINITY if impassable)
    def movement_cost_for_mode(world, from_coords, to_coords, travel_mode, avoid_water)
      to_globe_id = HexPathfindingService.coords_to_globe_hex_id(to_coords[0], to_coords[1])
      to_hex = WorldHex.hex_details(world, to_globe_id)

      case travel_mode
      when 'rail'
        rail_movement_cost(world, from_coords, to_coords)
      when 'water'
        water_movement_cost(to_hex)
      else
        land_movement_cost(to_hex, avoid_water)
      end
    end

    # Rail travel: must follow railway features
    # @param world [World] the world
    # @param from_coords [Array<Integer>] source hex coordinates
    # @param to_coords [Array<Integer>] destination hex coordinates
    # @return [Float] cost (Float::INFINITY if no railway)
    def rail_movement_cost(world, from_coords, to_coords)
      from_globe_id = HexPathfindingService.coords_to_globe_hex_id(from_coords[0], from_coords[1])
      from_hex = WorldHex.hex_details(world, from_globe_id)
      return Float::INFINITY unless from_hex

      # Determine direction from current to neighbor
      direction = direction_between(from_coords[0], from_coords[1], to_coords[0], to_coords[1])
      return Float::INFINITY unless WorldHex::DIRECTIONS.include?(direction)

      # Check if there's a railway feature in that direction
      feature = from_hex.directional_feature(direction)
      return Float::INFINITY unless feature == 'railway'

      # Railway is very fast (low cost)
      1.0 / GameConfig::WorldTravel::RAILWAY_SPEED_BONUS
    end

    # Land travel: standard terrain costs
    # @param hex [WorldHex] the destination hex
    # @param avoid_water [Boolean] whether to avoid water completely
    # @return [Float] movement cost
    def land_movement_cost(hex, avoid_water)
      return 1.0 unless hex

      # Check for water avoidance
      if avoid_water && %w[ocean lake].include?(hex.terrain_type)
        return Float::INFINITY
      end

      # Check traversability
      return Float::INFINITY unless hex.traversable

      # Standard terrain cost
      movement_cost_for_terrain(hex)
    end

    # Extract terrain-only cost (used by land mode)
    # @param hex [WorldHex] the hex to get cost for
    # @return [Float] terrain-based movement cost
    def movement_cost_for_terrain(hex)
      case hex.terrain_type
      when 'ocean', 'lake'
        GameConfig::WorldTravel::LAND_MODE_WATER_PENALTY.to_f
      when 'mountain'
        4.0
      when 'swamp', 'tundra', 'jungle'
        3.0
      when 'dense_forest', 'grassy_hills', 'rocky_hills', 'rocky_coast'
        2.0
      when 'urban', 'light_urban'
        1.0 # Prefer going through cities
      else
        1.0 # Default (grassy_plains, light_forest, sandy_coast, desert, rocky_plains)
      end
    end

    # Legacy movement cost (for backward compatibility with build_feature_path)
    def movement_cost(world, hex_x, hex_y)
      globe_id = HexPathfindingService.coords_to_globe_hex_id(hex_x, hex_y)
      hex = WorldHex.hex_details(world, globe_id)
      return 1 unless hex

      movement_cost_for_terrain(hex).to_i
    end

    # Get all hexes along a line between two points using linear interpolation
    # Uses the hex grid lerp algorithm to ensure we hit every hex along the line
    # @param x1 [Integer] start hex X
    # @param y1 [Integer] start hex Y
    # @param x2 [Integer] end hex X
    # @param y2 [Integer] end hex Y
    # @return [Array<Array<Integer>>] array of [x, y] hex coordinates
    def hex_line(x1, y1, x2, y2)
      distance = HexGrid.hex_distance(x1, y1, x2, y2)
      return [[x1, y1]] if distance == 0

      results = []
      (0..distance).each do |i|
        t = distance == 0 ? 0.0 : i.to_f / distance
        # Linear interpolation between start and end
        lerp_x = x1 + (x2 - x1) * t
        lerp_y = y1 + (y2 - y1) * t
        # Snap to valid hex coordinates
        hex_coords = HexGrid.to_hex_coords(lerp_x.round, lerp_y.round)
        results << hex_coords unless results.last == hex_coords
      end

      results
    end
  end
end
