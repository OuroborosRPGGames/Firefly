# frozen_string_literal: true
require_relative '../concerns/pathfinding_helper'

# GlobePathfindingService provides A* pathfinding on the globe hex grid
# for world-scale navigation between cities and points of interest.
#
# Uses great circle distance as the heuristic for finding optimal paths
# across the spherical world map.
#
# Supports multiple travel modes:
# - nil/land: Standard terrain-based pathfinding
# - water: Boats/ships - prefers water, land is very expensive
# - rail: Trains - only follows railway features

class GlobePathfindingService
  MAX_PATH_LENGTH = 500

  class << self
    include PathfindingHelper
    # Find a path between two globe hexes using A*
    # @param world [World] the world to search in
    # @param start_globe_hex_id [Integer] starting hex ID
    # @param end_globe_hex_id [Integer] ending hex ID
    # @param avoid_water [Boolean] whether to avoid ocean/lake hexes (only applies to land mode)
    # @param travel_mode [String, nil] travel mode: nil/'land', 'water', or 'rail'
    # @return [Array<Integer>] array of globe_hex_ids or empty array if no path
    def find_path(world:, start_globe_hex_id:, end_globe_hex_id:, avoid_water: true, travel_mode: nil)
      return [start_globe_hex_id] if start_globe_hex_id == end_globe_hex_id

      start_hex = WorldHex.find_by_globe_hex(world.id, start_globe_hex_id)
      end_hex = WorldHex.find_by_globe_hex(world.id, end_globe_hex_id)

      return [] if start_hex.nil? || end_hex.nil?

      # A* implementation
      open_set = Set.new([start_globe_hex_id])
      came_from = {}

      g_score = Hash.new(Float::INFINITY)
      g_score[start_globe_hex_id] = 0

      f_score = Hash.new(Float::INFINITY)
      f_score[start_globe_hex_id] = heuristic(start_hex, end_hex)

      # Cache hex lookups for performance
      hex_cache = { start_globe_hex_id => start_hex, end_globe_hex_id => end_hex }

      while open_set.any?
        # Get node with lowest f_score
        current_id = open_set.min_by { |id| f_score[id] }

        if current_id == end_globe_hex_id
          return reconstruct_path(came_from, current_id)
        end

        open_set.delete(current_id)

        # Limit path length to prevent infinite loops
        next if g_score[current_id] > MAX_PATH_LENGTH

        # Get current hex from cache or database
        current_hex = hex_cache[current_id] ||= WorldHex.find_by_globe_hex(world.id, current_id)
        next if current_hex.nil?

        # Get neighbors using WorldHex.neighbors_of
        neighbors = WorldHex.neighbors_of(current_hex)

        neighbors.each do |neighbor_hex|
          neighbor_id = neighbor_hex.globe_hex_id

          # Cache the neighbor
          hex_cache[neighbor_id] ||= neighbor_hex

          # Calculate movement cost based on travel mode
          move_cost = movement_cost_for_mode(current_hex, neighbor_hex, travel_mode, avoid_water)

          # Skip impassable terrain
          next if move_cost >= Float::INFINITY

          tentative_g = g_score[current_id] + move_cost

          if tentative_g < g_score[neighbor_id]
            came_from[neighbor_id] = current_id
            g_score[neighbor_id] = tentative_g
            f_score[neighbor_id] = tentative_g + heuristic(neighbor_hex, end_hex)

            open_set.add(neighbor_id) unless open_set.include?(neighbor_id)
          end
        end
      end

      [] # No path found
    end

    # Calculate great circle distance between two hexes in radians
    # @param hex1 [WorldHex] first hex
    # @param hex2 [WorldHex] second hex
    # @return [Float] angular distance in radians (Float::INFINITY if either hex is nil)
    def distance(hex1, hex2)
      return Float::INFINITY if hex1.nil? || hex2.nil?
      return 0.0 if hex1.id == hex2.id

      WorldHex.great_circle_distance_rad(
        hex1.latitude, hex1.longitude,
        hex2.latitude, hex2.longitude
      )
    end

    # Calculate great circle distance between two hexes in degrees
    # @param hex1 [WorldHex] first hex
    # @param hex2 [WorldHex] second hex
    # @return [Float] angular distance in degrees
    def distance_degrees(hex1, hex2)
      rad = distance(hex1, hex2)
      return Float::INFINITY if rad == Float::INFINITY

      rad * 180.0 / Math::PI
    end

    private

    # Heuristic: great circle distance to goal
    # Note: Returns distance in radians (~0.01-0.02 for neighbors) while
    # movement costs are integers (1-10). This intentional mismatch makes
    # the heuristic "weak" - A* explores more nodes but still finds optimal
    # paths. This is acceptable for game use with MAX_PATH_LENGTH=500.
    # @param hex1 [WorldHex] current hex
    # @param hex2 [WorldHex] goal hex
    # @return [Float] estimated cost to reach goal
    def heuristic(hex1, hex2)
      distance(hex1, hex2)
    end

    # Movement cost considering travel mode
    # @param from_hex [WorldHex] source hex
    # @param to_hex [WorldHex] destination hex
    # @param travel_mode [String, nil] travel mode: nil/'land', 'water', or 'rail'
    # @param avoid_water [Boolean] for land mode, whether to avoid water
    # @return [Float] movement cost (Float::INFINITY if impassable)
    def movement_cost_for_mode(from_hex, to_hex, travel_mode, avoid_water)
      case travel_mode
      when 'rail'
        rail_movement_cost(from_hex, to_hex)
      when 'water'
        water_movement_cost(to_hex)
      else
        land_movement_cost(to_hex, avoid_water)
      end
    end

    # Rail travel: must follow railway features
    # Uses directional features to determine connectivity
    # @param from_hex [WorldHex] source hex
    # @param to_hex [WorldHex] destination hex
    # @return [Float] cost (Float::INFINITY if no railway)
    def rail_movement_cost(from_hex, to_hex)
      return Float::INFINITY unless from_hex && to_hex

      # Determine direction from current to neighbor using lat/lon
      direction = direction_between_hexes(from_hex, to_hex)
      return Float::INFINITY if direction.nil?

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

      # Use hex's built-in movement cost
      hex.movement_cost.to_f
    end

    # Determine direction from one hex to another based on lat/lon
    # Returns one of WorldHex::DIRECTIONS ('n', 'ne', 'se', 's', 'sw', 'nw')
    # @param from_hex [WorldHex] source hex
    # @param to_hex [WorldHex] destination hex
    # @return [String, nil] direction from source to destination
    def direction_between_hexes(from_hex, to_hex)
      WorldHex.direction_between_hexes(from_hex, to_hex)
    end
  end
end
