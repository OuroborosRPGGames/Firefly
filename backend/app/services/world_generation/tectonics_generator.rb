# frozen_string_literal: true

module WorldGeneration
  # Generates tectonic plates via flood-fill from seed points.
  # Classifies plates as continental/oceanic and detects boundary
  # types (convergent, divergent, transform).
  #
  # @example
  #   grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 5)
  #   config = WorldGeneration::PresetConfig.for(:earth_like)
  #   rng = Random.new(12345)
  #   generator = WorldGeneration::TectonicsGenerator.new(grid, config, rng)
  #   generator.generate
  #   generator.plates # => { 0 => { id: 0, center: hex, ... }, ... }
  #   generator.plate_boundaries # => { "0-1" => { plate_ids: [0, 1], ... }, ... }
  #
  class TectonicsGenerator
    # Plates hash: { plate_id => { id:, center:, drift_x:, drift_y:, continental:, hexes: [] } }
    attr_reader :plates

    # Plate boundaries hash: { "id1-id2" => { plate_ids:, type:, hexes: [] } }
    attr_reader :plate_boundaries

    # @param grid [GlobeHexGrid] The hex grid to assign plates to
    # @param config [Hash] Preset configuration with :plate_count and :continental_ratio
    # @param rng [Random] Random number generator for reproducibility
    def initialize(grid, config, rng)
      @grid = grid
      @config = config
      @rng = rng
      @plates = {}
      @plate_boundaries = {}
    end

    # Generate tectonic plates:
    # 1. Seed random hexes as plate centers
    # 2. Flood-fill expand plates until all hexes assigned
    # 3. Classify plates as continental/oceanic
    # 4. Detect and classify plate boundaries
    def generate
      seed_plate_centers
      flood_fill_plates
      classify_plates
      detect_boundaries
      classify_boundaries
    end

    private

    # Seed N random hexes as plate centers
    def seed_plate_centers
      plate_count_range = @config[:plate_count]
      plate_count = @rng.rand(plate_count_range)

      # Scale plate count based on world size - small procedural worlds need fewer plates
      # Only apply scaling for actual world generation (100K+ hexes), not test grids
      hex_count = @grid.hex_count
      if hex_count >= 100_000 && hex_count < 500_000
        # For tiny procedural worlds (100K-500K hexes), limit to 4-8 plates
        plate_count = [plate_count, 4 + @rng.rand(5)].min
      elsif hex_count >= 500_000 && hex_count < 2_000_000
        # For small procedural worlds (500K-2M hexes), limit to 6-10 plates
        plate_count = [plate_count, 6 + @rng.rand(5)].min
      end

      # Get all hex IDs and shuffle them
      all_hex_ids = @grid.hexes.map(&:id)
      shuffled_ids = all_hex_ids.shuffle(random: @rng)

      # Select plate centers that are well-distributed
      selected_centers = select_distributed_centers(shuffled_ids, plate_count)

      selected_centers.each_with_index do |hex_id, index|
        center_hex = @grid.hex_by_id(hex_id)

        # Generate random drift direction (velocity vector on sphere tangent plane)
        drift_angle = @rng.rand * 2.0 * Math::PI
        drift_magnitude = @rng.rand * 0.5 + 0.1 # 0.1 to 0.6 arbitrary units

        @plates[index] = {
          id: index,
          center: center_hex,
          drift_x: Math.cos(drift_angle) * drift_magnitude,
          drift_y: Math.sin(drift_angle) * drift_magnitude,
          continental: nil, # Will be set in classify_plates
          hexes: [center_hex]
        }

        # Mark the hex with plate assignment
        center_hex.plate_id = index
      end
    end

    # Select well-distributed plate centers by avoiding clustering
    # Uses sampling for large candidate sets to avoid O(n*k^2) complexity
    def select_distributed_centers(shuffled_ids, count)
      return shuffled_ids.take(count) if count <= 1

      selected = []
      candidates = shuffled_ids.dup

      # Pick first center randomly
      first_id = candidates.shift
      selected << first_id

      # For large candidate sets, sample instead of checking all
      # Sample size scales with plate count to maintain quality
      max_sample_size = [count * 500, 5000].min

      while selected.size < count && !candidates.empty?
        # Sample candidates if the set is large
        sample = if candidates.size > max_sample_size
                   candidates.sample(max_sample_size, random: @rng)
                 else
                   candidates
                 end

        # Find the candidate that maximizes minimum distance to existing centers
        best_candidate = nil
        best_min_distance = -1.0

        sample.each do |candidate_id|
          candidate_hex = @grid.hex_by_id(candidate_id)
          min_dist = selected.map do |sel_id|
            sel_hex = @grid.hex_by_id(sel_id)
            angular_distance(candidate_hex, sel_hex)
          end.min

          if min_dist > best_min_distance
            best_min_distance = min_dist
            best_candidate = candidate_id
          end
        end

        break unless best_candidate

        selected << best_candidate
        candidates.delete(best_candidate)
      end

      selected
    end

    # Calculate angular distance between two hexes using dot product
    def angular_distance(hex1, hex2)
      dot = hex1.x * hex2.x + hex1.y * hex2.y + hex1.z * hex2.z
      Math.acos(dot.clamp(-1.0, 1.0))
    end

    # Flood-fill expand plates until all hexes are assigned
    # Optimized: Uses Sets for O(1) operations and batch expansion
    def flood_fill_plates
      require 'set'

      # Create frontier Set for each plate (neighbors not yet assigned)
      # Using Sets prevents duplicates and gives O(1) add/delete
      frontiers = {}
      @plates.each do |plate_id, plate|
        frontiers[plate_id] = Set.new(@grid.neighbors_of(plate[:center]).select { |n| n.plate_id.nil? })
      end

      # Track total unassigned for progress reporting
      total_hexes = @grid.hex_count
      assigned_count = @plates.size # Centers are already assigned

      # Batch size: process multiple hexes per plate per iteration
      # This dramatically reduces loop iterations from O(n) to O(n/batch_size)
      batch_size = [total_hexes / 1000, 100].max

      # Keep expanding while any frontier is non-empty
      loop do
        expanded = false

        @plates.keys.shuffle(random: @rng).each do |plate_id|
          frontier = frontiers[plate_id]
          next if frontier.empty?

          # Process a batch of hexes from this plate's frontier
          hexes_to_process = frontier.to_a.sample([batch_size, frontier.size].min, random: @rng)

          hexes_to_process.each do |hex|
            frontier.delete(hex)

            # Skip if already assigned
            next if !hex.plate_id.nil?

            # Assign to plate
            hex.plate_id = plate_id
            @plates[plate_id][:hexes] << hex
            assigned_count += 1
            expanded = true

            # Add unassigned neighbors to frontier (Set prevents duplicates)
            @grid.neighbors_of(hex).each do |neighbor|
              frontier.add(neighbor) if neighbor.plate_id.nil?
            end
          end
        end

        break unless expanded
      end

      # Assign any remaining unassigned hexes to nearest plate
      assign_remaining_hexes
    end

    # Assign any remaining unassigned hexes to the nearest plate
    def assign_remaining_hexes
      @grid.each_hex do |hex|
        next if !hex.plate_id.nil?

        # Find nearest plate center
        nearest_plate_id = nil
        min_distance = Float::INFINITY

        @plates.each do |plate_id, plate|
          dist = angular_distance(hex, plate[:center])
          if dist < min_distance
            min_distance = dist
            nearest_plate_id = plate_id
          end
        end

        if nearest_plate_id
          hex.plate_id = nearest_plate_id
          @plates[nearest_plate_id][:hexes] << hex
        end
      end
    end

    # Classify plates as continental or oceanic based on config ratio.
    # Uses maximin angular distance selection so continental plates are
    # spread apart on the globe, producing multiple separated continents
    # instead of one Pangaea-like supercontinent.
    def classify_plates
      continental_ratio = @config[:continental_ratio] || 0.4
      plate_ids = @plates.keys
      continental_count = (plate_ids.size * continental_ratio).round

      if continental_count <= 0
        plate_ids.each { |pid| @plates[pid][:continental] = false }
        return
      end

      if continental_count >= plate_ids.size
        plate_ids.each { |pid| @plates[pid][:continental] = true }
        return
      end

      # Greedy maximin selection: pick continental plates as far apart as possible
      continental_ids = []

      # First continental plate chosen randomly
      continental_ids << plate_ids.sample(random: @rng)

      while continental_ids.size < continental_count
        best_id = nil
        best_min_dist = -1.0

        (plate_ids - continental_ids).each do |candidate_id|
          candidate_center = @plates[candidate_id][:center]

          # Minimum angular distance from this candidate to any already-chosen continental plate
          min_dist = continental_ids.map do |chosen_id|
            angular_distance(candidate_center, @plates[chosen_id][:center])
          end.min

          if min_dist > best_min_dist
            best_min_dist = min_dist
            best_id = candidate_id
          end
        end

        break unless best_id

        continental_ids << best_id
      end

      # Mark selected plates as continental, rest as oceanic
      plate_ids.each do |pid|
        @plates[pid][:continental] = continental_ids.include?(pid)
      end
    end

    # Detect plate boundaries (hexes adjacent to different plates)
    # Optimized: Uses Sets to avoid O(n) include? checks
    def detect_boundaries
      require 'set'

      # Use Sets to track which hexes are in each boundary (O(1) lookup)
      boundary_hex_sets = {}

      @grid.each_hex do |hex|
        @grid.neighbors_of(hex).each do |neighbor|
          next if neighbor.plate_id == hex.plate_id
          next if hex.plate_id.nil? || neighbor.plate_id.nil?

          # Create canonical boundary key (smaller id first)
          ids = [hex.plate_id, neighbor.plate_id].sort
          boundary_key = "#{ids[0]}-#{ids[1]}"

          @plate_boundaries[boundary_key] ||= {
            plate_ids: ids,
            type: nil, # Will be set in classify_boundaries
            hexes: []
          }

          # Track hexes in a Set for O(1) duplicate checking
          boundary_hex_sets[boundary_key] ||= Set.new

          # Add hex to boundary if not already present
          unless boundary_hex_sets[boundary_key].include?(hex)
            boundary_hex_sets[boundary_key].add(hex)
            @plate_boundaries[boundary_key][:hexes] << hex
          end
        end
      end
    end

    # Classify boundaries as convergent, divergent, or transform
    def classify_boundaries
      @plate_boundaries.each do |key, boundary|
        plate1 = @plates[boundary[:plate_ids][0]]
        plate2 = @plates[boundary[:plate_ids][1]]

        boundary[:type] = classify_boundary_type(plate1, plate2, boundary[:hexes])
      end
    end

    # Determine boundary type based on relative plate motion
    # - convergent: plates moving toward each other
    # - divergent: plates moving apart
    # - transform: plates sliding past each other
    def classify_boundary_type(plate1, plate2, boundary_hexes)
      return :transform if boundary_hexes.empty?

      # Calculate average boundary position
      avg_x = boundary_hexes.sum(&:x) / boundary_hexes.size
      avg_y = boundary_hexes.sum(&:y) / boundary_hexes.size
      avg_z = boundary_hexes.sum(&:z) / boundary_hexes.size

      # Normalize to get direction from plate1 center to boundary
      length = Math.sqrt(avg_x**2 + avg_y**2 + avg_z**2)
      return :transform if length < 0.001

      # Direction from plate1 to plate2 (simplified as tangent plane approximation)
      center1 = plate1[:center]
      center2 = plate2[:center]

      # Vector from center1 to center2 on the sphere surface
      dir_x = center2.x - center1.x
      dir_y = center2.y - center1.y

      # Relative velocity: plate1's drift - plate2's drift
      # If moving toward each other (negative relative velocity along connecting direction) -> convergent
      # If moving apart (positive relative velocity) -> divergent
      # Otherwise -> transform
      rel_drift_x = plate1[:drift_x] - plate2[:drift_x]
      rel_drift_y = plate1[:drift_y] - plate2[:drift_y]

      # Project relative drift onto the direction between plates
      dir_length = Math.sqrt(dir_x**2 + dir_y**2)
      return :transform if dir_length < 0.001

      projection = (rel_drift_x * dir_x + rel_drift_y * dir_y) / dir_length

      # Thresholds for classification
      if projection < -0.1
        :convergent # Plates moving toward each other
      elsif projection > 0.1
        :divergent # Plates moving apart
      else
        :transform # Plates sliding past each other
      end
    end
  end
end
