# frozen_string_literal: true

module WorldGeneration
  # Generates elevation data for hexes using simplex noise and tectonic influence.
  # Mountains form at convergent plate boundaries, rifts at divergent boundaries.
  # Sea level is calculated to match target ocean coverage.
  #
  # @example
  #   grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 5)
  #   config = WorldGeneration::PresetConfig.for(:earth_like)
  #   rng = Random.new(12345)
  #   noise = WorldGeneration::NoiseGenerator.new(seed: rng.rand(2**32))
  #   tectonics = WorldGeneration::TectonicsGenerator.new(grid, config, rng)
  #   tectonics.generate
  #
  #   elevation_gen = WorldGeneration::ElevationGenerator.new(grid, config, rng, noise, tectonics)
  #   elevation_gen.generate
  #   elevation_gen.sea_level # => 0.15 (example)
  #
  class ElevationGenerator
    # Sea level: elevation below which hexes are ocean
    attr_reader :sea_level

    # Noise frequency scale for base elevation
    NOISE_SCALE = 2.0

    # Gradient falloff per ring from boundary (ring 0 = boundary hex itself)
    BOUNDARY_DECAY = [1.0, 0.6, 0.3, 0.1].freeze

    # Per-hex noise modulation on boundary effects (0.0 = uniform, 1.0 = fully random)
    # Creates peaks/passes in mountain ranges and island chains at ocean boundaries
    BOUNDARY_NOISE_STRENGTH = 0.6
    BOUNDARY_NOISE_SCALE = 8.0 # Higher frequency than base terrain for fine detail

    # Multiple smoothing passes to eliminate sharp discontinuities
    EROSION_PASSES = 3
    EROSION_FACTOR = 0.2

    # @param grid [GlobeHexGrid] The hex grid to generate elevation for
    # @param config [Hash] Preset configuration with :ocean_coverage, :mountain_intensity
    # @param rng [Random] Random number generator for reproducibility
    # @param noise [NoiseGenerator] Simplex noise generator
    # @param tectonics [TectonicsGenerator] Tectonic plate data (must have generate called)
    def initialize(grid, config, rng, noise, tectonics)
      @grid = grid
      @config = config
      @rng = rng
      @noise = noise
      @tectonics = tectonics
      @sea_level = 0.0
    end

    # Generate elevation for all hexes:
    # 1. Base elevation from simplex noise
    # 2. Tectonic plate influence (continental vs oceanic)
    # 3. Boundary effects (mountains, rifts)
    # 4. Simple erosion pass
    # 5. Calculate sea level based on ocean coverage target
    def generate
      generate_base_elevation
      apply_tectonic_influence
      apply_boundary_effects
      apply_erosion
      calculate_sea_level
    end

    private

    # Generate base elevation using octave simplex noise on 3D coordinates
    def generate_base_elevation
      @grid.each_hex do |hex|
        # Use 3D coordinates for seamless spherical noise
        base = @noise.octave_noise3d(
          hex.x * NOISE_SCALE,
          hex.y * NOISE_SCALE,
          hex.z * NOISE_SCALE,
          octaves: 6,
          persistence: 0.5,
          lacunarity: 2.0
        )

        # Store initial elevation (roughly -1 to +1 range from noise)
        hex.elevation = base
      end
    end

    # Number of hex rings over which the tectonic offset ramps from 0 to full.
    # Creates smooth continental shelves instead of sharp elevation cliffs at
    # plate boundaries that show up as visible lines on the globe.
    TECTONIC_RAMP_RINGS = 8

    # Apply tectonic plate type influence on elevation.
    # Continental plates get higher base elevation, oceanic get lower.
    # The offset ramps up with distance from plate boundaries so transitions
    # are gradual (continental shelf) rather than a hard step.
    def apply_tectonic_influence
      # BFS from all plate boundary hexes to compute distance-to-boundary for every hex
      boundary_distances = compute_plate_boundary_distances

      @grid.each_hex do |hex|
        plate_id = hex.plate_id
        next if plate_id.nil?

        plate = @tectonics.plates[plate_id]
        next if plate.nil?

        # Ramp factor: 0.0 at boundary, 1.0 at TECTONIC_RAMP_RINGS+ distance
        dist = boundary_distances[hex.id] || TECTONIC_RAMP_RINGS
        ramp = [dist.to_f / TECTONIC_RAMP_RINGS, 1.0].min

        if plate[:continental]
          hex.elevation += 0.3 * ramp
        else
          hex.elevation -= 0.2 * ramp
        end
      end
    end

    # Multi-source BFS from every plate boundary hex outward, returning
    # { hex_id => distance } where distance 0 = on a plate boundary.
    def compute_plate_boundary_distances
      require 'set'

      distances = {}
      queue = []

      # Seed: all hexes that are adjacent to a hex from a different plate
      @grid.each_hex do |hex|
        next if hex.plate_id.nil?

        @grid.neighbors_of(hex).each do |neighbor|
          next if neighbor.plate_id.nil?
          next if neighbor.plate_id == hex.plate_id

          # This hex borders a different plate — it's a boundary hex
          unless distances.key?(hex.id)
            distances[hex.id] = 0
            queue << hex.id
          end
          break
        end
      end

      # BFS outward up to TECTONIC_RAMP_RINGS
      until queue.empty?
        current_id = queue.shift
        current_dist = distances[current_id]
        next if current_dist >= TECTONIC_RAMP_RINGS

        hex = @grid.hex_by_id(current_id)
        next if hex.nil?

        @grid.neighbors_of(hex).each do |neighbor|
          next if distances.key?(neighbor.id)

          distances[neighbor.id] = current_dist + 1
          queue << neighbor.id
        end
      end

      distances
    end

    # Apply boundary effects: mountains at convergent, rifts at divergent.
    # Effects decay over multiple rings from the boundary to create wide,
    # natural-looking mountain ranges and rift valleys instead of thin lines.
    # Per-hex noise modulation breaks uniform ridges into individual peaks,
    # mountain passes, and island chains.
    def apply_boundary_effects
      boundary_data = categorize_boundary_hexes_with_plate_types
      mountain_intensity = @config[:mountain_intensity] || 1.0

      # Build distance rings for each boundary category
      cc_rings = build_boundary_distance_rings(boundary_data[:convergent_continental])
      co_rings = build_boundary_distance_rings(boundary_data[:convergent_oceanic])
      dv_rings = build_boundary_distance_rings(boundary_data[:divergent])

      @grid.each_hex do |hex|
        # Convergent continental: mountain boost with decay + noise → peaks and passes
        if (dist = cc_rings[hex.id])
          decay = BOUNDARY_DECAY[dist] || 0.0
          hex.elevation += 0.5 * mountain_intensity * decay * boundary_noise(hex)
        end

        # Convergent oceanic: trench with decay + noise → island arcs
        if (dist = co_rings[hex.id])
          decay = BOUNDARY_DECAY[dist] || 0.0
          hex.elevation -= 0.15 * decay * boundary_noise(hex)
        end

        # Divergent: rift depression with decay + noise → segmented rifts
        if (dist = dv_rings[hex.id])
          decay = BOUNDARY_DECAY[dist] || 0.0
          hex.elevation -= 0.2 * decay * boundary_noise(hex)
        end
      end
    end

    # Per-hex noise multiplier for boundary effects.
    # Returns a value in [1 - BOUNDARY_NOISE_STRENGTH, 1 + BOUNDARY_NOISE_STRENGTH]
    # so the average effect is unchanged but individual hexes vary, creating
    # peaks/passes in mountain ranges and island chains at ocean convergence.
    def boundary_noise(hex)
      raw = @noise.noise3d(
        hex.x * BOUNDARY_NOISE_SCALE,
        hex.y * BOUNDARY_NOISE_SCALE,
        hex.z * BOUNDARY_NOISE_SCALE
      )
      # raw is roughly -1..1; scale to modulation range
      1.0 + raw * BOUNDARY_NOISE_STRENGTH
    end

    # Multi-source BFS from a set of boundary hex IDs outward up to
    # BOUNDARY_DECAY.size - 1 rings. Returns { hex_id => distance } where
    # distance 0 = boundary hex itself, 1 = first ring of neighbors, etc.
    def build_boundary_distance_rings(seed_hex_ids)
      return {} if seed_hex_ids.empty?

      max_dist = BOUNDARY_DECAY.size - 1
      distances = {}

      # Seed: all boundary hexes at distance 0
      queue = []
      seed_hex_ids.each do |hex_id|
        distances[hex_id] = 0
        queue << hex_id
      end

      # BFS outward
      until queue.empty?
        current_id = queue.shift
        current_dist = distances[current_id]
        next if current_dist >= max_dist

        hex = @grid.hex_by_id(current_id)
        next if hex.nil?

        @grid.neighbors_of(hex).each do |neighbor|
          next if distances.key?(neighbor.id)

          distances[neighbor.id] = current_dist + 1
          queue << neighbor.id
        end
      end

      distances
    end

    # Categorize hexes by boundary type and plate types for accurate geology
    # Convergent boundaries are split by whether they involve continental plates
    def categorize_boundary_hexes_with_plate_types
      result = {
        convergent_continental: Set.new, # At least one continental plate
        convergent_oceanic: Set.new,     # Both plates oceanic
        divergent: Set.new,
        transform: Set.new
      }

      @tectonics.plate_boundaries.each do |_key, boundary|
        boundary_type = boundary[:type]
        plate_ids = boundary[:plate_ids]

        # Check if any plate in this boundary is continental
        has_continental = plate_ids.any? do |plate_id|
          @tectonics.plates[plate_id]&.dig(:continental)
        end

        boundary[:hexes].each do |hex|
          case boundary_type
          when :convergent
            if has_continental
              result[:convergent_continental].add(hex.id)
            else
              result[:convergent_oceanic].add(hex.id)
            end
          when :divergent
            result[:divergent].add(hex.id)
          when :transform
            result[:transform].add(hex.id)
          end
        end
      end

      result
    end

    # Apply multiple erosion passes to smooth sharp discontinuities.
    # Each pass rebuilds a snapshot so changes don't cascade within a pass.
    # After EROSION_PASSES passes at EROSION_FACTOR, remaining deviation is
    # (1 - EROSION_FACTOR)^EROSION_PASSES ≈ 51% of original, preserving
    # major features while eliminating thin-line artifacts.
    def apply_erosion
      EROSION_PASSES.times do
        # Snapshot current elevations for this pass
        original_elevations = {}
        @grid.each_hex { |hex| original_elevations[hex.id] = hex.elevation }

        @grid.each_hex do |hex|
          neighbors = @grid.neighbors_of(hex)
          next if neighbors.empty?

          neighbor_avg = neighbors.sum { |n| original_elevations[n.id] } / neighbors.size
          hex.elevation = hex.elevation * (1.0 - EROSION_FACTOR) + neighbor_avg * EROSION_FACTOR
        end
      end
    end

    # Calculate sea level such that ocean_coverage % of hexes are below it
    def calculate_sea_level
      ocean_coverage = @config[:ocean_coverage] || 0.70

      # Collect all elevations
      elevations = []
      @grid.each_hex { |hex| elevations << hex.elevation }

      return if elevations.empty?

      # Sort elevations to find percentile
      elevations.sort!

      # Find the index for the ocean coverage percentile
      # e.g., 70% ocean means sea level is at the 70th percentile from the bottom
      index = (elevations.size * ocean_coverage).floor
      index = [index, elevations.size - 1].min # Clamp to valid range

      @sea_level = elevations[index]
    end
  end
end
