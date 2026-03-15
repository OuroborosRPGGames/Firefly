# frozen_string_literal: true

# Shared path reconstruction for A* and similar pathfinding services.
module PathfindingHelper
  # Water travel cost: water is fast, land is very expensive.
  # @param hex [WorldHex] the destination hex
  # @return [Float] movement cost
  def water_movement_cost(hex)
    return 1.0 unless hex

    case hex.terrain_type
    when 'ocean', 'lake', 'rocky_coast', 'sandy_coast'
      1.0 # Water is easy for boats
    else
      GameConfig::WorldTravel::WATER_MODE_LAND_PENALTY.to_f
    end
  end

  # Reconstruct a path by tracing back through the came_from map.
  #
  # @param came_from [Hash] node => previous_node
  # @param current [Object] the destination node
  # @param skip_start [Boolean] if true, omit the first (starting) node
  # @return [Array] ordered path from start to current
  def reconstruct_path(came_from, current, skip_start: false)
    path = [current]
    while came_from.key?(current)
      current = came_from[current]
      path.unshift(current)
    end
    skip_start ? path.drop(1) : path
  end
end
