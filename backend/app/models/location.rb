# frozen_string_literal: true

class Location < Sequel::Model
  include SeasonalContentCore

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :zone
  alias_method :area, :zone  # Backward compatibility alias

  many_to_one :world
  one_to_many :rooms
  one_to_one :weather
  one_to_many :delves
  one_to_many :news_articles
  one_to_many :metaplot_events

  SUBTYPES = %w[
    misc landmark placeholder major_bridge foot_bridge
    rail_bridge rail_station ocean_harbor river_dock
  ].freeze

  def validate
    super
    validates_presence [:name, :zone_id]
    validates_unique [:zone_id, :name]
    validates_max_length 100, :name
    validates_includes ['building', 'outdoor', 'underground', 'water', 'sky'], :location_type
    validates_includes SUBTYPES, :subtype if subtype

    # Validate world_id when globe_hex_id is present
    if globe_hex_id && !world_id
      errors.add(:world_id, 'is required when globe_hex_id is set')
    end
  end

  # Display name for player-facing text (prefers city_name over internal name)
  # @return [String] the display name
  def display_name
    cn = city_name.to_s.strip
    cn.empty? ? name : cn
  end

  # Check if this location has a globe hex ID
  # @return [Boolean] true if globe_hex_id is set
  def has_globe_hex?
    !globe_hex_id.nil?
  end

  alias globe_hex? has_globe_hex?
  alias has_hex_coords? has_globe_hex?

  # Get the associated WorldHex for this location
  # @return [WorldHex, nil] the world hex or nil if not found
  def world_hex
    return nil unless globe_hex_id && world_id

    WorldHex.find_by_globe_hex(world_id, globe_hex_id)
  end

  # Check if this is a city location
  def is_city?
    city_name && !city_name.to_s.empty?
  end

  def active_rooms
    rooms.where(active: true)
  end

  # ========================================
  # Seasonal Description and Background Methods (Inheritance)
  # ========================================

  # Resolve description for a given time/season from this location's defaults
  # @param time [Symbol] :dawn, :day, :dusk, :night
  # @param season [Symbol] :spring, :summer, :fall, :winter
  # @return [String, nil]
  def resolve_description(time, season)
    resolve_seasonal_content(default_descriptions, time, season) ||
      default_description
  end

  # Resolve background URL for a given time/season from this location's defaults
  # @param time [Symbol] :dawn, :day, :dusk, :night
  # @param season [Symbol] :spring, :summer, :fall, :winter
  # @return [String, nil]
  def resolve_background(time, season)
    resolve_seasonal_content(default_backgrounds, time, season) ||
      default_background_url
  end

  # Set a default seasonal description for this location
  # @param time [Symbol, String, nil] time of day or nil/'-' for any
  # @param season [Symbol, String, nil] season or nil/'-' for any
  # @param desc [String] the description text
  def set_default_description!(time, season, desc)
    key = build_seasonal_key(time, season)
    descs = (default_descriptions || {}).to_h.dup
    descs[key] = desc
    update(default_descriptions: Sequel.pg_jsonb_wrap(descs))
  end

  # Set a default seasonal background for this location
  # @param time [Symbol, String, nil] time of day or nil/'-' for any
  # @param season [Symbol, String, nil] season or nil/'-' for any
  # @param url [String] the background URL
  def set_default_background!(time, season, url)
    key = build_seasonal_key(time, season)
    bgs = (default_backgrounds || {}).to_h.dup
    bgs[key] = url
    update(default_backgrounds: Sequel.pg_jsonb_wrap(bgs))
  end

  # ===== Activation System =====

  def active?
    is_active == true || is_active.nil?
  end

  def activate!
    update(is_active: true)
  end

  def deactivate!
    update(is_active: false)
  end

  # Get recently created inactive locations
  def self.inactive_recent
    where(is_active: false)
      .where { created_at > Time.now - (30 * 24 * 60 * 60) } # Created within last 30 days
  end

  # Get all inactive locations
  def self.inactive
    where(is_active: false)
  end

  # ===== Transport Infrastructure =====

  def has_port?
    has_port == true
  end
  alias port? has_port?

  def has_train_station?
    has_train_station == true
  end
  alias train_station? has_train_station?

  def has_ferry_terminal?
    has_ferry_terminal == true
  end
  alias ferry_terminal? has_ferry_terminal?

  def has_stable?
    has_stable == true
  end
  alias stable? has_stable?

  def has_bus_depot?
    has_bus_depot == true
  end
  alias bus_depot? has_bus_depot?

  # ===== City Polygon Methods =====

  # City origin in world coordinates (defaults to location's lat/lon position)
  # For globe hex system, we use lat/lon as the city origin. The city_origin_x/y
  # fields can still override if specifically set.
  # @return [Hash] {x:, y:} coordinates where city is anchored (lat/lon based)
  def city_origin_world
    # If city_origin coordinates are explicitly set, use them
    return { x: city_origin_x, y: city_origin_y } if city_origin_x && city_origin_y

    # Otherwise, derive from the location's lat/lon (which the globe system uses)
    # This provides approximate world coordinates for polygon calculations
    {
      x: longitude || 0,
      y: latitude || 0
    }
  end

  # Check if a city-local point (feet) is inside the zone polygon
  # @param local_x [Numeric] X coordinate in feet (city-local)
  # @param local_y [Numeric] Y coordinate in feet (city-local)
  # @return [Boolean] true if point is inside zone polygon (or no polygon defined)
  def city_point_in_zone?(local_x, local_y)
    return true unless zone&.has_polygon?

    origin = city_origin_world
    zone.contains_local_point?(local_x, local_y, origin_x: origin[:x], origin_y: origin[:y])
  end

  # City bounds in feet based on street grid configuration
  # @return [Hash, nil] {min_x:, max_x:, min_y:, max_y:} or nil if not a city
  def city_bounds
    return nil unless is_city?

    cell_size = defined?(GridCalculationService::GRID_CELL_SIZE) ? GridCalculationService::GRID_CELL_SIZE : 175
    {
      min_x: 0,
      max_x: (vertical_streets || 1) * cell_size,
      min_y: 0,
      max_y: (horizontal_streets || 1) * cell_size
    }
  end

  # Zone polygon transformed to city-local feet coordinates
  # Useful for rendering the zone boundary in the city builder UI
  # @return [Array<Hash>, nil] Array of {x:, y:} points in feet, or nil if no polygon
  def zone_polygon_in_feet
    return nil unless zone&.has_polygon?

    # For local-scale polygons, convert to plain Ruby array with consistent keys
    if zone.local_scale?
      return zone.polygon_points.map do |p|
        { x: (p['x'] || p[:x]).to_f, y: (p['y'] || p[:y]).to_f }
      end
    end

    # For world-scale polygons, transform from hex to feet coordinates
    origin = city_origin_world
    # World hex size is ~3 miles = 15,840 feet
    hex_size = 15_840.0

    zone.polygon_points.map do |p|
      zx = (p['x'] || p[:x]).to_f
      zy = (p['y'] || p[:y]).to_f
      {
        x: (zx - origin[:x]) * hex_size,
        y: (zy - origin[:y]) * hex_size
      }
    end
  end

  private

  # (resolve_seasonal_content, build_seasonal_key provided by SeasonalContentCore)
end
