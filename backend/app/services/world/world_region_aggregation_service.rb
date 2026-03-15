# frozen_string_literal: true

# Aggregates terrain data from WorldHex records into WorldRegion hierarchy.
#
# The WorldRegion hierarchy allows fast texture generation and map rendering
# without querying millions of individual hexes. Each level aggregates a 3×3
# grid from the level below.
#
# Hierarchy (3×3 at each level, 8 levels total):
#   Level 0: 3×3 = 9 world segments
#   Level 1: 9×9 = 81 continental regions
#   Level 2: 27×27 = 729 large regions
#   Level 3: 81×81 = 6,561 subregions (optimal for 4096×2048 texture)
#   Level 4: 243×243 = 59,049 areas
#   Level 5: 729×729 = 531,441 districts
#   Level 6: 2,187×2,187 = 4,782,969 local areas
#   Level 7: 6,561×6,561 = 43,046,721 hex-level regions
#
# Usage:
#   WorldRegionAggregationService.aggregate_for_world(world)
#
class WorldRegionAggregationService
  # Number of sub-divisions per axis at each level
  GRID_SIZE = 3

  # Maximum zoom level (hex level)
  MAX_LEVEL = GameConfig::WorldMap::MAX_ZOOM_LEVEL

  # Minimum zoom level (world view)
  MIN_LEVEL = GameConfig::WorldMap::MIN_ZOOM_LEVEL

  # Batch size for region creation
  BATCH_SIZE = 1000

  class << self
    # Aggregate all regions for a world from hexes up to world level.
    #
    # @param world [World] The world to aggregate
    # @return [Hash] Statistics about the aggregation
    def aggregate_for_world(world)
      warn "[WorldRegionAggregation] Starting aggregation for world #{world.id}..."

      stats = {
        world_id: world.id,
        levels_processed: 0,
        regions_created: 0,
        hexes_counted: 0,
        started_at: Time.now
      }

      # Clear existing regions
      WorldRegion.where(world_id: world.id).delete

      # Start from the finest level and work up
      # Level 7: Aggregate directly from hexes
      stats[:hexes_counted] = WorldHex.where(world_id: world.id).count

      if stats[:hexes_counted].zero?
        warn '[WorldRegionAggregation] No hexes to aggregate'
        return stats
      end

      # For large worlds, use the fast path that aggregates from hex data
      if stats[:hexes_counted] > 100_000
        aggregate_large_world(world, stats)
      else
        aggregate_small_world(world, stats)
      end

      stats[:completed_at] = Time.now
      stats[:duration_seconds] = (stats[:completed_at] - stats[:started_at]).round(1)

      warn "[WorldRegionAggregation] Complete: #{stats[:regions_created]} regions in #{stats[:duration_seconds]}s"
      stats
    end

    private

    # Aggregate a large world using hex sampling.
    # For globe hexes, we sample based on lat/lon positions.
    #
    # @param world [World] The world to aggregate
    # @param stats [Hash] Statistics hash to update
    def aggregate_large_world(world, stats)
      # For large worlds, we go straight to a reasonable level (3-4)
      # and sample hexes at those positions
      target_level = 3  # 81×81 = 6,561 regions

      regions_per_axis = GRID_SIZE**(target_level + 1)

      warn "[WorldRegionAggregation] Creating #{regions_per_axis}×#{regions_per_axis} regions at level #{target_level}"

      # Create regions at target level by sampling lat/lon positions
      records = []
      regions_per_axis.times do |rx|
        regions_per_axis.times do |ry|
          # Calculate center lat/lon for this region
          # Latitude: -90 to 90 (180 degrees), Longitude: -180 to 180 (360 degrees)
          center_lat = -90.0 + ((ry + 0.5) / regions_per_axis * 180.0)
          center_lon = -180.0 + ((rx + 0.5) / regions_per_axis * 360.0)

          # Sample nearby hexes for terrain composition
          terrain = sample_terrain_at(world, center_lat, center_lon)

          records << {
            world_id: world.id,
            region_x: rx,
            region_y: ry,
            zoom_level: target_level,
            dominant_terrain: terrain[:dominant],
            avg_altitude: terrain[:avg_altitude],
            terrain_composition: Sequel.pg_json(terrain[:composition]),
            has_road: terrain[:has_road],
            has_river: terrain[:has_river],
            has_railway: terrain[:has_railway],
            traversable_percentage: terrain[:traversable_pct],
            is_generated: true,
            is_modified: false
          }

          if records.size >= BATCH_SIZE
            WorldRegion.multi_insert(records)
            stats[:regions_created] += records.size
            records.clear
          end
        end
      end

      WorldRegion.multi_insert(records) unless records.empty?
      stats[:regions_created] += records.size
      stats[:levels_processed] = 1

      # Now aggregate upward from target level to level 0
      (target_level - 1).downto(MIN_LEVEL) do |level|
        aggregate_level_from_children(world, level, stats)
      end
    end

    # Aggregate a small world using the standard bottom-up approach.
    #
    # @param world [World] The world to aggregate
    # @param stats [Hash] Statistics hash to update
    def aggregate_small_world(world, stats)
      # For small worlds, aggregate from level 7 (hex level) down to 0
      MAX_LEVEL.downto(MIN_LEVEL) do |level|
        if level == MAX_LEVEL
          aggregate_from_hexes(world, level, stats)
        else
          aggregate_level_from_children(world, level, stats)
        end
        stats[:levels_processed] += 1
      end
    end

    # Aggregate a single level from WorldHex records.
    # For globe hexes, we group by lat/lon into geographic regions.
    #
    # @param world [World] The world to aggregate
    # @param level [Integer] Zoom level to create
    # @param stats [Hash] Statistics hash to update
    def aggregate_from_hexes(world, level, stats)
      hexes = WorldHex.where(world_id: world.id).all
      return if hexes.empty?

      # Calculate regions per axis at this level
      regions_per_axis = GRID_SIZE**(level + 1)

      # Latitude: -90 to 90 (180 degrees), Longitude: -180 to 180 (360 degrees)
      lat_per_region = 180.0 / regions_per_axis
      lon_per_region = 360.0 / regions_per_axis

      # Group hexes by their region at this level based on lat/lon
      regions_data = Hash.new { |h, k| h[k] = { terrains: Hash.new(0), altitudes: [], features: {} } }

      hexes.each do |hex|
        next unless hex.latitude && hex.longitude

        # Calculate which region this hex belongs to at this level
        # Latitude maps to region_y, Longitude maps to region_x
        rx = ((hex.longitude + 180.0) / lon_per_region).to_i
        ry = ((hex.latitude + 90.0) / lat_per_region).to_i

        # Clamp to valid range
        rx = [[rx, 0].max, regions_per_axis - 1].min
        ry = [[ry, 0].max, regions_per_axis - 1].min

        key = [rx, ry]
        regions_data[key][:terrains][hex.terrain_type] += 1
        regions_data[key][:altitudes] << (hex.altitude || 0)
        regions_data[key][:features][:road] = true if hex.has_road?
        regions_data[key][:features][:river] = true if hex.has_river?
        regions_data[key][:features][:railway] = true if hex.has_railway?
      end

      # Create region records
      records = regions_data.map do |(rx, ry), data|
        total = data[:terrains].values.sum
        dominant = data[:terrains].max_by { |_, v| v }&.first || 'ocean'
        composition = data[:terrains].transform_values { |v| (v.to_f / total * 100).round(1) }
        traversable_count = data[:terrains].reject { |t, _| %w[ocean lake].include?(t) }.values.sum

        {
          world_id: world.id,
          region_x: rx,
          region_y: ry,
          zoom_level: level,
          dominant_terrain: dominant,
          avg_altitude: data[:altitudes].empty? ? 0 : (data[:altitudes].sum / data[:altitudes].size),
          terrain_composition: Sequel.pg_json(composition),
          has_road: data[:features][:road] || false,
          has_river: data[:features][:river] || false,
          has_railway: data[:features][:railway] || false,
          traversable_percentage: total.positive? ? (traversable_count.to_f / total * 100).round(1) : 0,
          is_generated: true,
          is_modified: false
        }
      end

      records.each_slice(BATCH_SIZE) do |batch|
        WorldRegion.multi_insert(batch)
        stats[:regions_created] += batch.size
      end
    end

    # Aggregate a level from child regions.
    #
    # @param world [World] The world to aggregate
    # @param level [Integer] Zoom level to create
    # @param stats [Hash] Statistics hash to update
    def aggregate_level_from_children(world, level, stats)
      child_level = level + 1
      children = WorldRegion.where(world_id: world.id, zoom_level: child_level).all

      return if children.empty?

      # Group children by their parent region
      parents_data = Hash.new { |h, k| h[k] = { terrains: Hash.new(0.0), altitudes: [], features: {} } }

      children.each do |child|
        px = child.region_x / GRID_SIZE
        py = child.region_y / GRID_SIZE

        key = [px, py]

        # Aggregate terrain composition
        (child.terrain_composition || {}).each do |terrain, pct|
          parents_data[key][:terrains][terrain] += pct.to_f
        end

        parents_data[key][:altitudes] << (child.avg_altitude || 0)
        parents_data[key][:features][:road] ||= child.has_road
        parents_data[key][:features][:river] ||= child.has_river
        parents_data[key][:features][:railway] ||= child.has_railway
        parents_data[key][:traversable_sum] ||= 0
        parents_data[key][:traversable_sum] += (child.traversable_percentage || 0)
        parents_data[key][:child_count] ||= 0
        parents_data[key][:child_count] += 1
      end

      # Create parent region records
      records = parents_data.map do |(px, py), data|
        total_pct = data[:terrains].values.sum
        dominant = data[:terrains].max_by { |_, v| v }&.first || 'ocean'
        composition = total_pct.positive? ? data[:terrains].transform_values { |v| (v / total_pct * 100).round(1) } : {}
        child_count = data[:child_count] || 1

        {
          world_id: world.id,
          region_x: px,
          region_y: py,
          zoom_level: level,
          dominant_terrain: dominant,
          avg_altitude: data[:altitudes].empty? ? 0 : (data[:altitudes].sum / data[:altitudes].size),
          terrain_composition: Sequel.pg_json(composition),
          has_road: data[:features][:road] || false,
          has_river: data[:features][:river] || false,
          has_railway: data[:features][:railway] || false,
          traversable_percentage: (data[:traversable_sum].to_f / child_count).round(1),
          is_generated: true,
          is_modified: false
        }
      end

      records.each_slice(BATCH_SIZE) do |batch|
        WorldRegion.multi_insert(batch)
        stats[:regions_created] += batch.size
      end

      warn "[WorldRegionAggregation] Level #{level}: #{records.size} regions"
    end

    # Sample terrain composition near a geographic coordinate.
    #
    # @param world [World] The world to sample
    # @param center_lat [Float] Center latitude in degrees
    # @param center_lon [Float] Center longitude in degrees
    # @return [Hash] Terrain data
    def sample_terrain_at(world, center_lat, center_lon)
      # Sample a small area around the center (in degrees)
      sample_radius = 5.0  # degrees
      min_lat = center_lat - sample_radius
      max_lat = center_lat + sample_radius
      min_lon = center_lon - sample_radius
      max_lon = center_lon + sample_radius

      # Use Sequel[:column] to explicitly reference columns (avoid collision with local vars)
      hexes = WorldHex.where(world_id: world.id)
                      .where { (latitude >= min_lat) & (latitude <= max_lat) }
                      .where { (longitude >= min_lon) & (longitude <= max_lon) }
                      .limit(100)
                      .all

      if hexes.empty?
        # No hexes found - likely ocean
        return {
          dominant: 'ocean',
          composition: { 'ocean' => 100.0 },
          avg_altitude: 0,
          has_road: false,
          has_river: false,
          has_railway: false,
          traversable_pct: 0.0
        }
      end

      terrains = Hash.new(0)
      altitudes = []
      has_road = false
      has_river = false
      has_railway = false
      traversable = 0

      hexes.each do |hex|
        terrains[hex.terrain_type] += 1
        altitudes << (hex.altitude || 0)
        has_road ||= hex.has_road?
        has_river ||= hex.has_river?
        has_railway ||= hex.has_railway?
        traversable += 1 unless %w[ocean lake].include?(hex.terrain_type)
      end

      total = hexes.size
      dominant = terrains.max_by { |_, v| v }&.first || 'ocean'
      composition = terrains.transform_values { |v| (v.to_f / total * 100).round(1) }

      {
        dominant: dominant,
        composition: composition,
        avg_altitude: altitudes.empty? ? 0 : (altitudes.sum / altitudes.size),
        has_road: has_road,
        has_river: has_river,
        has_railway: has_railway,
        traversable_pct: (traversable.to_f / total * 100).round(1)
      }
    end
  end
end
