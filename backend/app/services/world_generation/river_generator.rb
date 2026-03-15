# frozen_string_literal: true

module WorldGeneration
  # Generates rivers by finding high-elevation, high-moisture source points
  # and tracing paths downhill to the ocean using steepest descent.
  #
  # Rivers are stored as:
  # 1. An array of river paths (each path is an array of hex objects)
  # 2. Directional markers on each hex showing river flow directions
  #
  # @example
  #   grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 5)
  #   config = WorldGeneration::PresetConfig.for(:earth_like)
  #   rng = Random.new(12345)
  #   # ... run elevation and climate generators ...
  #
  #   river_gen = WorldGeneration::RiverGenerator.new(grid, config, rng, sea_level)
  #   river_gen.generate
  #
  #   river_gen.rivers # => [[hex1, hex2, hex3, ...], [hexA, hexB, ...], ...]
  #
  class RiverGenerator
    # Direction names for hex grid edges (clockwise from north)
    DIRECTION_NAMES = %w[n ne se s sw nw].freeze

    # Opposite directions for marking inflow on destination hex
    OPPOSITE_DIRECTIONS = {
      'n'  => 's',
      'ne' => 'sw',
      'se' => 'nw',
      's'  => 'n',
      'sw' => 'ne',
      'nw' => 'se'
    }.freeze

    # Minimum moisture threshold for river source (0.0-1.0)
    SOURCE_MOISTURE_THRESHOLD = 0.5

    # Minimum elevation above sea level for river source (as fraction of max elevation)
    SOURCE_ELEVATION_PERCENTILE = 0.7

    # Array of river paths, each path is an array of HexData objects
    attr_reader :rivers

    # @param grid [GlobeHexGrid] The hex grid with elevation and moisture data
    # @param config [Hash] Preset configuration with :river_sources range
    # @param rng [Random] Random number generator for reproducibility
    # @param sea_level [Float] Sea level from ElevationGenerator
    def initialize(grid, config, rng, sea_level)
      @grid = grid
      @config = config
      @rng = rng
      @sea_level = sea_level
      @rivers = []
    end

    # Generate rivers:
    # 1. Find candidate source hexes (high elevation + high moisture)
    # 2. Select random subset based on config[:river_sources]
    # 3. Trace each river downhill until it reaches ocean
    # 4. Mark river directions on hexes
    def generate
      source_candidates = find_source_candidates
      return if source_candidates.empty?

      source_count = determine_source_count(source_candidates.size)
      sources = select_sources(source_candidates, source_count)

      sources.each do |source_hex|
        river_path = trace_river(source_hex)
        next if river_path.size < 2 # Skip trivial rivers

        @rivers << river_path
        mark_river_directions(river_path)
      end

      # Calculate river widths based on flow accumulation
      calculate_river_widths
    end

    private

    # Find hexes suitable for river sources:
    # - Above sea level
    # - High elevation (top 30% of land elevations)
    # - High moisture (above threshold)
    #
    # @return [Array<HexData>] Candidate source hexes
    def find_source_candidates
      # Collect all land hex elevations to determine threshold
      land_hexes = []
      @grid.each_hex do |hex|
        land_hexes << hex if hex.elevation >= @sea_level
      end

      return [] if land_hexes.empty?

      # Find elevation threshold (70th percentile of land elevations)
      sorted_elevations = land_hexes.map(&:elevation).sort
      threshold_index = (sorted_elevations.size * SOURCE_ELEVATION_PERCENTILE).floor
      threshold_index = [threshold_index, sorted_elevations.size - 1].min
      elevation_threshold = sorted_elevations[threshold_index]

      # Filter for high elevation AND high moisture
      land_hexes.select do |hex|
        hex.elevation >= elevation_threshold &&
          (hex.moisture || 0.0) >= SOURCE_MOISTURE_THRESHOLD
      end
    end

    # Determine how many river sources to create based on config and available candidates
    #
    # @param candidate_count [Integer] Number of available candidates
    # @return [Integer] Number of sources to use
    def determine_source_count(candidate_count)
      range = @config[:river_sources] || (30..60)
      target = @rng.rand(range)
      [target, candidate_count].min
    end

    # Select random sources from candidates, preferring higher elevations
    #
    # @param candidates [Array<HexData>] All candidate hexes
    # @param count [Integer] Number to select
    # @return [Array<HexData>] Selected source hexes
    def select_sources(candidates, count)
      return [] if count <= 0 || candidates.empty?

      # Weight by elevation (higher = more likely to be selected)
      weighted = candidates.map do |hex|
        # Weight = elevation above sea level, squared to favor peaks
        weight = [(hex.elevation - @sea_level), 0.01].max ** 2
        [hex, weight]
      end

      # Weighted random selection without replacement
      selected = []
      remaining = weighted.dup

      count.times do
        break if remaining.empty?

        total_weight = remaining.sum { |_, w| w }
        break if total_weight <= 0

        # Random weighted selection
        pick = @rng.rand * total_weight
        cumulative = 0.0
        chosen_index = nil

        remaining.each_with_index do |(_, weight), idx|
          cumulative += weight
          if cumulative >= pick
            chosen_index = idx
            break
          end
        end

        chosen_index ||= remaining.size - 1
        selected << remaining[chosen_index][0]
        remaining.delete_at(chosen_index)
      end

      selected
    end

    # Trace a river from source downhill to ocean using steepest descent
    #
    # @param source [HexData] Starting hex
    # @return [Array<HexData>] Path of hexes from source to ocean (or dead end)
    def trace_river(source)
      path = [source]
      visited = Set.new([source.id])
      current = source

      loop do
        # Check if we've reached ocean
        break if current.elevation < @sea_level

        # Find lowest neighbor not yet in path
        next_hex = find_lowest_neighbor(current, visited)

        # Stop if stuck (no downhill neighbor available)
        break if next_hex.nil?

        # Don't flow uphill
        break if next_hex.elevation > current.elevation

        path << next_hex
        visited.add(next_hex.id)
        current = next_hex

        # Safety limit to prevent infinite loops
        break if path.size > 10_000
      end

      path
    end

    # Find the lowest elevation neighbor not already visited
    #
    # @param hex [HexData] Current hex
    # @param visited [Set] IDs of hexes already in the path
    # @return [HexData, nil] Lowest unvisited neighbor, or nil if none
    def find_lowest_neighbor(hex, visited)
      neighbors = @grid.neighbors_of(hex)
      return nil if neighbors.empty?

      unvisited = neighbors.reject { |n| visited.include?(n.id) }
      return nil if unvisited.empty?

      # Return the neighbor with lowest elevation
      unvisited.min_by(&:elevation)
    end

    # Mark river directions on hexes along a river path
    # Each hex gets outflow direction added, destination gets inflow direction
    #
    # @param path [Array<HexData>] River path from source to end
    def mark_river_directions(path)
      path.each_cons(2) do |from_hex, to_hex|
        direction = direction_between(from_hex, to_hex)
        next if direction.nil?

        # Add outflow direction to source hex
        from_hex.river_directions ||= []
        from_hex.river_directions << direction unless from_hex.river_directions.include?(direction)

        # Add inflow direction to destination hex
        opposite = OPPOSITE_DIRECTIONS[direction]
        if opposite
          to_hex.river_directions ||= []
          to_hex.river_directions << opposite unless to_hex.river_directions.include?(opposite)
        end
      end
    end

    # Calculate river widths based on flow accumulation.
    # Each hex accumulates flow from all upstream hexes. When rivers merge,
    # their flows combine. Width is classified as stream, river, or major river.
    #
    # Width classifications:
    #   1 = stream (1-5 upstream hexes)
    #   2 = river (6-25 upstream hexes)
    #   3 = major river (26+ upstream hexes)
    def calculate_river_widths
      return if @rivers.empty?

      # Count upstream flow for each hex
      # Each hex in a path gets credit for all hexes upstream of it
      flow_count = Hash.new(0)

      @rivers.each do |path|
        path.each_with_index do |hex, idx|
          # idx 0 = source (1 upstream), idx 5 = 6 upstream hexes feeding into it
          # When rivers merge at a hex, this naturally accumulates
          flow_count[hex.id] += (idx + 1)
        end
      end

      # Set river_width on each hex based on accumulated flow
      flow_count.each do |hex_id, flow|
        hex = @grid.hex_by_id(hex_id)
        next unless hex

        hex.river_width = case flow
                          when 1..5   then 1 # stream
                          when 6..25  then 2 # river
                          else             3 # major river
                          end
      end
    end

    # Determine the direction from one hex to an adjacent hex
    # Uses 3D dot product with direction vectors to find closest match
    #
    # @param from [HexData] Source hex
    # @param to [HexData] Destination hex
    # @return [String, nil] Direction name ('n', 'ne', 'se', 's', 'sw', 'nw') or nil
    def direction_between(from, to)
      # Calculate the vector from source to destination
      dx = to.x - from.x
      dy = to.y - from.y
      dz = to.z - from.z

      # Normalize the vector
      length = Math.sqrt(dx * dx + dy * dy + dz * dz)
      return nil if length < 1e-10

      dx /= length
      dy /= length
      dz /= length

      # For each direction, calculate a reference vector on the sphere
      # We use the hex's local coordinate frame
      # This is simplified - using longitude difference as primary indicator
      lon_diff = to.lon - from.lon
      lat_diff = to.lat - from.lat

      # Normalize to -PI..PI range
      lon_diff -= 2 * Math::PI while lon_diff > Math::PI
      lon_diff += 2 * Math::PI while lon_diff < -Math::PI

      # Determine direction based on angle
      # North = +lat, South = -lat
      # East = +lon, West = -lon
      angle = Math.atan2(lon_diff, lat_diff) # Angle from north (0 = north, PI/2 = east)

      # Convert angle to direction index (6 directions, 60 degrees each)
      # Shift by 30 degrees so direction boundaries are at 30, 90, 150, etc.
      angle_deg = angle * 180.0 / Math::PI
      # Normalize to 0..360
      angle_deg += 360.0 if angle_deg < 0

      # Map angle to direction index
      # 0 = n (330-30), 1 = ne (30-90), 2 = se (90-150),
      # 3 = s (150-210), 4 = sw (210-270), 5 = nw (270-330)
      dir_index = ((angle_deg + 30.0) / 60.0).floor % 6

      DIRECTION_NAMES[dir_index]
    end
  end
end
