# frozen_string_literal: true

require_relative '../lib/world_terrain_config'

# WorldRegion stores aggregated data for hierarchical zoom levels
# Each region represents a 3x3 grid of sub-regions (or hexes at finest level)
# This allows efficient rendering of the world map without loading millions of hexes

class WorldRegion < Sequel::Model
  TERRAIN_COLORS = WorldTerrainConfig::TERRAIN_COLORS

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :world

  # Zoom levels: 0 = entire world (9 segments), 7 = individual hex level
  ZOOM_LEVELS = {
    0 => 'world',      # 3x3 = 9 segments covering entire world
    1 => 'continent',  # Each segment subdivides to 3x3
    2 => 'region',
    3 => 'subregion',
    4 => 'area',
    5 => 'district',
    6 => 'local',
    7 => 'hex'         # Individual WorldHex level (3 miles)
  }.freeze


  # Valid terrain types (same as WorldHex)
  TERRAIN_TYPES = WorldHex::TERRAIN_TYPES


  def validate
    super
    validates_presence [:world_id, :region_x, :region_y, :zoom_level]
    validates_integer :region_x
    validates_integer :region_y
    validates_integer :zoom_level
    validates_includes TERRAIN_TYPES, :dominant_terrain if dominant_terrain
    # Validate zoom_level is within valid range
    if zoom_level && (zoom_level < GameConfig::WorldMap::MIN_ZOOM_LEVEL || zoom_level > GameConfig::WorldMap::MAX_ZOOM_LEVEL)
      errors.add(:zoom_level, "must be between #{GameConfig::WorldMap::MIN_ZOOM_LEVEL} and #{GameConfig::WorldMap::MAX_ZOOM_LEVEL}")
    end
  end

  # Get the zoom level name
  def zoom_level_name
    ZOOM_LEVELS[zoom_level] || 'unknown'
  end

  # Get the terrain color for rendering
  def terrain_color
    WorldTerrainConfig::TERRAIN_COLORS[dominant_terrain] || '#808080'
  end

  # Get child regions (one level deeper in zoom)
  # Returns 9 regions in a 3x3 grid
  def children
    return [] if zoom_level >= GameConfig::WorldMap::MAX_ZOOM_LEVEL

    child_zoom = zoom_level + 1
    child_base_x = region_x * GameConfig::WorldMap::GRID_SIZE
    child_base_y = region_y * GameConfig::WorldMap::GRID_SIZE

    WorldRegion.where(
      world_id: world_id,
      zoom_level: child_zoom,
      region_x: child_base_x..(child_base_x + GameConfig::WorldMap::GRID_SIZE - 1),
      region_y: child_base_y..(child_base_y + GameConfig::WorldMap::GRID_SIZE - 1)
    ).all
  end

  # Get parent region (one level up in zoom)
  def parent
    return nil if zoom_level <= GameConfig::WorldMap::MIN_ZOOM_LEVEL

    parent_zoom = zoom_level - 1
    parent_x = region_x / GameConfig::WorldMap::GRID_SIZE
    parent_y = region_y / GameConfig::WorldMap::GRID_SIZE

    WorldRegion.first(
      world_id: world_id,
      zoom_level: parent_zoom,
      region_x: parent_x,
      region_y: parent_y
    )
  end

  # Get all hexes in this region (only valid at zoom level 7)
  # For globe hexes, we use latitude/longitude bounds instead of hex_x/hex_y
  def hexes
    return [] unless zoom_level == GameConfig::WorldMap::MAX_ZOOM_LEVEL

    # At zoom level 7, each region corresponds to a specific geographic bounding box
    # World is divided into a 3^7 x 3^7 grid of regions at max zoom
    # Each region covers a portion of the globe's lat/lon space
    regions_per_axis = 3**GameConfig::WorldMap::MAX_ZOOM_LEVEL  # 2187 regions per axis at level 7

    # Latitude ranges from -90 to 90 (180 degrees total)
    lat_per_region = 180.0 / regions_per_axis
    min_lat = -90.0 + (region_y * lat_per_region)
    max_lat = min_lat + lat_per_region

    # Longitude ranges from -180 to 180 (360 degrees total)
    lon_per_region = 360.0 / regions_per_axis
    min_lon = -180.0 + (region_x * lon_per_region)
    max_lon = min_lon + lon_per_region

    WorldHex.where(world_id: world_id)
      .where { (latitude >= min_lat) & (latitude < max_lat) }
      .where { (longitude >= min_lon) & (longitude < max_lon) }
      .all
  end

  # Recalculate aggregated data from children or hexes
  def recalculate_aggregates!
    if zoom_level == GameConfig::WorldMap::MAX_ZOOM_LEVEL
      recalculate_from_hexes!
    else
      recalculate_from_children!
    end
  end

  # API representation for JSON responses
  def to_api_hash
    {
      id: id,
      world_id: world_id,
      region_x: region_x,
      region_y: region_y,
      zoom_level: zoom_level,
      zoom_level_name: zoom_level_name,
      dominant_terrain: dominant_terrain,
      terrain_color: terrain_color,
      avg_altitude: avg_altitude,
      terrain_composition: terrain_composition,
      has_road: has_road,
      has_river: has_river,
      has_railway: has_railway,
      traversable_percentage: traversable_percentage,
      is_generated: is_generated,
      is_modified: is_modified
    }
  end

  class << self
    # Get regions for a specific world and zoom level
    def at_zoom_level(world, zoom_level)
      where(world_id: world.id, zoom_level: zoom_level).all
    end

    # Get 9 regions centered on coordinates for rendering
    def region_view(world, center_x, center_y, zoom_level)
      # For zoom level 0, we just want regions 0-2 in both x and y
      if zoom_level == 0
        where(
          world_id: world.id,
          zoom_level: zoom_level,
          region_x: 0..2,
          region_y: 0..2
        ).all
      else
        # Calculate bounds for the 3x3 grid centered on the given coordinates
        min_x = center_x - 1
        max_x = center_x + 1
        min_y = center_y - 1
        max_y = center_y + 1

        where(
          world_id: world.id,
          zoom_level: zoom_level,
          region_x: min_x..max_x,
          region_y: min_y..max_y
        ).all
      end
    end

    # Create initial world regions at zoom level 0 (9 segments)
    def create_initial_regions(world)
      (0...GameConfig::WorldMap::GRID_SIZE).each do |x|
        (0...GameConfig::WorldMap::GRID_SIZE).each do |y|
          find_or_create(
            world_id: world.id,
            zoom_level: GameConfig::WorldMap::MIN_ZOOM_LEVEL,
            region_x: x,
            region_y: y
          ) do |r|
            r.dominant_terrain = 'ocean'
            r.is_generated = false
            r.is_modified = false
          end
        end
      end
    end
  end

  private

  def recalculate_from_hexes!
    region_hexes = hexes
    return if region_hexes.empty?

    # Calculate terrain composition
    terrain_counts = Hash.new(0)
    total_altitude = 0
    traversable_count = 0
    has_any_road = false
    has_any_river = false
    has_any_railway = false

    region_hexes.each do |hex|
      terrain_counts[hex.terrain_type] += 1
      total_altitude += hex.altitude
      traversable_count += 1 if hex.traversable

      # Check directional features
      WorldHex::DIRECTIONS.each do |dir|
        feature = hex.send("feature_#{dir}")
        next unless feature

        has_any_road = true if %w[road highway street trail].include?(feature)
        has_any_river = true if %w[river canal].include?(feature)
        has_any_railway = true if feature == 'railway'
      end
    end

    total_hexes = region_hexes.size

    # Calculate percentages
    composition = {}
    terrain_counts.each do |terrain, count|
      composition[terrain] = (count.to_f / total_hexes * 100).round(1)
    end

    # Find dominant terrain
    dominant = terrain_counts.max_by { |_, count| count }&.first || 'ocean'

    update(
      dominant_terrain: dominant,
      avg_altitude: (total_altitude.to_f / total_hexes).round,
      terrain_composition: composition,
      has_road: has_any_road,
      has_river: has_any_river,
      has_railway: has_any_railway,
      traversable_percentage: (traversable_count.to_f / total_hexes * 100).round(1)
    )
  end

  def recalculate_from_children!
    child_regions = children
    return if child_regions.empty?

    # Aggregate from children
    terrain_counts = Hash.new(0)
    total_altitude = 0
    total_traversable = 0
    has_any_road = false
    has_any_river = false
    has_any_railway = false

    child_regions.each do |child|
      (child.terrain_composition || {}).each do |terrain, percentage|
        terrain_counts[terrain] += percentage
      end
      total_altitude += child.avg_altitude || 0
      total_traversable += child.traversable_percentage || 0
      has_any_road ||= child.has_road
      has_any_river ||= child.has_river
      has_any_railway ||= child.has_railway
    end

    total_children = child_regions.size

    # Normalize terrain composition
    composition = {}
    total_percentage = terrain_counts.values.sum
    terrain_counts.each do |terrain, pct|
      composition[terrain] = (pct / total_percentage * 100).round(1) if total_percentage.positive?
    end

    # Find dominant terrain
    dominant = terrain_counts.max_by { |_, count| count }&.first || 'ocean'

    update(
      dominant_terrain: dominant,
      avg_altitude: (total_altitude.to_f / total_children).round,
      terrain_composition: composition,
      has_road: has_any_road,
      has_river: has_any_river,
      has_railway: has_any_railway,
      traversable_percentage: (total_traversable / total_children).round(1)
    )
  end
end
