# frozen_string_literal: true

require_relative '../lib/zone_grid'

class World < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :universe
  one_to_many :zones
  one_to_many :world_hexes
  one_to_one :weather_world_state
  
  def validate
    super
    validates_presence [:name, :universe_id]
    validates_unique [:universe_id, :name]
    validates_max_length 100, :name
    validates_numeric :gravity_multiplier, only_numeric: true
    validates_integer :coordinates_x, allow_nil: true
    validates_integer :coordinates_y, allow_nil: true
    validates_integer :coordinates_z, allow_nil: true
    validates_numeric :world_size, only_numeric: true
    validates_operator :>, 0.0, :world_size
  end
  
  def active_zones
    zones.where(active: true)
  end

  # Check if this is a test world (excluded from public directories)
  def test_world?
    is_test == true
  end
  
  # Get the world coordinates as an array
  def coordinates
    [coordinates_x || 0, coordinates_y || 0, coordinates_z || 0]
  end
  
  # Set world coordinates from an array
  def coordinates=(coords)
    if coords.is_a?(Array) && coords.length >= 2
      self.coordinates_x = coords[0]
      self.coordinates_y = coords[1]
      self.coordinates_z = coords[2] if coords.length >= 3
    end
  end
  
  # Calculate 3D distance to another world
  def distance_to(other_world)
    return nil unless coordinates_x && coordinates_y && coordinates_z &&
                     other_world.coordinates_x && other_world.coordinates_y && other_world.coordinates_z
                     
    dx = coordinates_x - other_world.coordinates_x
    dy = coordinates_y - other_world.coordinates_y  
    dz = coordinates_z - other_world.coordinates_z
    
    Math.sqrt(dx*dx + dy*dy + dz*dz)
  end
  
  # Find nearby worlds within a given distance
  def nearby_worlds(max_distance = 100)
    return [] unless coordinates_x && coordinates_y && coordinates_z
    
    universe.worlds.reject { |w| w.id == id }.select do |world|
      distance = distance_to(world)
      distance && distance <= max_distance
    end.sort_by { |world| distance_to(world) }
  end
  
  # === ZONE GRID METHODS ===

  # Convert longitude/latitude to zone grid coordinates
  def lonlat_to_zone_grid(longitude, latitude)
    ZoneGrid.lonlat_to_zone_grid(longitude, latitude, self)
  end

  # Find innermost room at zone grid coordinates
  def innermost_room_at(grid_x, grid_y, grid_z, zone)
    ZoneGrid.innermost_room_at(grid_x, grid_y, grid_z, zone)
  end

  # Convert world hex to zone grid (if hex is within a zone)
  def hex_to_zone_grid(hex_x, hex_y)
    ZoneGrid.world_hex_to_zone_grid(hex_x, hex_y, self)
  end
  
  # === WORLD HEX DETAIL METHODS ===
  
  # Get detailed hex information (terrain, features, etc.)
  # @param globe_hex_id [Integer] the globe hex ID
  # @return [WorldHex] hex details (or default if not found)
  def hex_details(globe_hex_id)
    WorldHex.hex_details(self, globe_hex_id)
  end
  
  # Get terrain type for a hex (with default)
  # @param globe_hex_id [Integer] the globe hex ID
  # @return [String] terrain type
  def hex_terrain(globe_hex_id)
    WorldHex.terrain_at(self, globe_hex_id)
  end
  
  # Get altitude for a hex (with default)
  # @param globe_hex_id [Integer] the globe hex ID
  # @return [Integer] altitude
  def hex_altitude(globe_hex_id)
    WorldHex.altitude_at(self, globe_hex_id)
  end
  
  # Check if hex is traversable
  # @param globe_hex_id [Integer] the globe hex ID
  # @return [Boolean] traversable status
  def hex_traversable?(globe_hex_id)
    WorldHex.traversable_at?(self, globe_hex_id)
  end
  
  # Get linear features for a hex
  # @param globe_hex_id [Integer] the globe hex ID
  # @return [Hash] linear features
  def hex_linear_features(globe_hex_id)
    WorldHex.linear_features_at(self, globe_hex_id)
  end
  
  # Set hex details (creates or updates hex data)
  # @param globe_hex_id [Integer] the globe hex ID
  # @param attributes [Hash] attributes to set
  # @return [WorldHex] the created or updated hex
  def set_hex_details(globe_hex_id, attributes = {})
    WorldHex.set_hex_details(self, globe_hex_id, attributes)
  end
  
  # Get movement cost for a hex
  # @param globe_hex_id [Integer] the globe hex ID
  # @return [Integer] movement cost
  def hex_movement_cost(globe_hex_id)
    hex = hex_details(globe_hex_id)
    hex ? hex.movement_cost : 1
  end
  
  # Check if hex blocks line of sight
  # @param globe_hex_id [Integer] the globe hex ID
  # @return [Boolean] true if hex blocks sight
  def hex_blocks_sight?(globe_hex_id)
    hex = hex_details(globe_hex_id)
    hex ? hex.blocks_sight? : false
  end

  # === WEATHER SETTINGS ===

  # Get effective storm frequency for this world
  # @return [Float] Multiplier (0.5 = calmer, 2.0 = stormier)
  def effective_storm_frequency
    self[:storm_frequency_multiplier] || 1.0
  rescue StandardError => e
    warn "[World] Failed to read storm_frequency_multiplier: #{e.message}"
    1.0
  end

  # Get effective precipitation multiplier
  # @return [Float] Multiplier affecting rain/snow frequency
  def effective_precipitation
    self[:precipitation_multiplier] || 1.0
  rescue StandardError => e
    warn "[World] Failed to read precipitation_multiplier: #{e.message}"
    1.0
  end

  # Get global temperature offset
  # @return [Integer] Celsius offset applied to all areas
  def global_temp_offset
    self[:base_temperature_offset] || 0
  rescue StandardError => e
    warn "[World] Failed to read base_temperature_offset: #{e.message}"
    0
  end

  # Get weather variability (affects how quickly weather changes)
  # @return [Float] Multiplier (0.5 = stable, 2.0 = chaotic)
  def effective_variability
    self[:weather_variability] || 1.0
  rescue StandardError => e
    warn "[World] Failed to read weather_variability: #{e.message}"
    1.0
  end

  # Get current season (can be overridden at world level)
  # @return [Symbol, nil] Season override or nil to use calculated season
  def current_season
    override = begin
      self[:current_season_override]
    rescue StandardError => e
      warn "[World] Failed to read current_season_override: #{e.message}"
      nil
    end
    return override.to_sym if StringHelper.present?(override)

    nil # Let GameTimeService calculate
  end

  # === WEATHER GRID INTEGRATION ===

  # Check if this world uses the grid weather simulation
  # @return [Boolean]
  def grid_weather?
    use_grid_weather == true
  end

  # Get active storms from the grid weather system
  # @return [Array<Hash>] Active storm data
  def active_storms
    return [] unless grid_weather?

    WeatherGrid::StormService.active_storms(self)
  rescue StandardError => e
    warn "[World] Failed to load active storms: #{e.message}"
    []
  end

  # Get grid weather metadata (last tick, tick count, etc.)
  # @return [Hash, nil] Grid metadata
  def weather_grid_meta
    return nil unless grid_weather?

    WeatherGrid::GridService.load(self)&.dig(:meta)
  rescue StandardError => e
    warn "[World] Failed to load weather grid meta: #{e.message}"
    nil
  end
end