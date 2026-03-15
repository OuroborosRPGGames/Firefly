# frozen_string_literal: true

module WeatherGrid
  # InterpolationService - Computes location-level weather on demand
  #
  # The macro grid (64x64) provides regional weather, but players see weather
  # at individual locations. This service interpolates macro grid values
  # to specific latitude/longitude coordinates with:
  #
  # 1. Bilinear interpolation from 4 nearest macro cells
  # 2. Local terrain adjustments (altitude lapse rate)
  # 3. Procedural noise for micro-variation
  # 4. Storm overlay if active storm affects the location
  # 5. Weather condition derivation (clear, rain, snow, etc.)
  #
  # Results are cached in Redis with 15s TTL.
  #
  # Usage:
  #   WeatherGrid::InterpolationService.weather_at(world, latitude: 45.0, longitude: -73.5)
  #   WeatherGrid::InterpolationService.condition_at(world, latitude: 45.0, longitude: -73.5)
  #   WeatherGrid::InterpolationService.weather_for_location(location)
  #   WeatherGrid::InterpolationService.condition_for_location(location)
  #
  module InterpolationService
    extend self

    CACHE_TTL = 15 # seconds

    # Weather conditions derived from values
    CONDITIONS = {
      clear: { cloud_max: 20, precip_max: 0 },
      partly_cloudy: { cloud_min: 20, cloud_max: 50, precip_max: 0 },
      cloudy: { cloud_min: 50, cloud_max: 80, precip_max: 0 },
      overcast: { cloud_min: 80, precip_max: 0.1 },
      light_rain: { precip_min: 0.1, precip_max: 2, temp_min: 2 },
      rain: { precip_min: 2, precip_max: 10, temp_min: 2 },
      heavy_rain: { precip_min: 10, temp_min: 2 },
      light_snow: { precip_min: 0.1, precip_max: 2, temp_max: 2 },
      snow: { precip_min: 2, precip_max: 10, temp_max: 2 },
      blizzard: { precip_min: 10, temp_max: 2 },
      fog: { humidity_min: 95, wind_max: 10 },
      thunderstorm: { precip_min: 5, instability_min: 60, temp_min: 10 }
    }.freeze

    # Get interpolated weather at a latitude/longitude
    #
    # @param world [World] The world
    # @param latitude [Float] Latitude in degrees (-90 to +90)
    # @param longitude [Float] Longitude in degrees (-180 to +180)
    # @return [Hash] Weather data with all fields and derived condition
    def weather_at(world, latitude:, longitude:)
      return nil unless world&.id

      cached = cached_weather(world, latitude, longitude)
      return cached if cached

      weather = compute_weather(world, latitude, longitude)
      return nil unless weather

      cache_weather(world, latitude, longitude, weather)
      weather
    end

    # Convenience: weather for a Location (resolves globe_hex_id -> lat/lon)
    #
    # @param location [Location] A location with globe_hex_id and world_id
    # @return [Hash, nil] Weather data or nil
    def weather_for_location(location)
      return nil unless location&.globe_hex_id && location&.world_id

      world = location.world
      return nil unless world

      world_hex = location.world_hex
      return nil unless world_hex&.latitude && world_hex&.longitude

      weather_at(world, latitude: world_hex.latitude, longitude: world_hex.longitude)
    end

    # Convenience: just the condition string for a location
    #
    # @param location [Location] A location with globe_hex_id and world_id
    # @return [String] Weather condition (clear, rain, snow, etc.)
    def condition_for_location(location)
      weather = weather_for_location(location)
      weather&.dig('condition') || 'clear'
    end

    # Get just the weather condition at a lat/lon
    #
    # @param world [World] The world
    # @param latitude [Float] Latitude in degrees (-90 to +90)
    # @param longitude [Float] Longitude in degrees (-180 to +180)
    # @return [String] Weather condition (clear, rain, snow, etc.)
    def condition_at(world, latitude:, longitude:)
      weather = weather_at(world, latitude: latitude, longitude: longitude)
      weather&.dig('condition') || 'clear'
    end

    # Get weather description at a lat/lon
    #
    # @param world [World] The world
    # @param latitude [Float] Latitude in degrees (-90 to +90)
    # @param longitude [Float] Longitude in degrees (-180 to +180)
    # @return [String] Human-readable weather description
    def description_at(world, latitude:, longitude:)
      weather = weather_at(world, latitude: latitude, longitude: longitude)
      return "Clear skies" unless weather

      build_description(weather)
    end

    # Clear cached weather for a lat/lon (useful when terrain changes)
    #
    # @param world [World] The world
    # @param latitude [Float] Latitude in degrees
    # @param longitude [Float] Longitude in degrees
    def clear_cache(world, latitude, longitude)
      return unless redis_available?

      REDIS_POOL.with do |redis|
        redis.del(cache_key(world.id, latitude, longitude))
      end
    rescue StandardError => e
      warn "[WeatherGrid::InterpolationService] Cache clear failed: #{e.message}"
    end

    # Clear all cached weather for a world
    #
    # @param world [World] The world
    def clear_all_cache(world)
      return unless redis_available?

      REDIS_POOL.with do |redis|
        keys = redis.keys("weather:#{world.id}:ll:*")
        redis.del(*keys) if keys.any?
      end
    rescue StandardError => e
      warn "[WeatherGrid::InterpolationService] Cache clear all failed: #{e.message}"
    end

    private

    # ========================================
    # Core Interpolation
    # ========================================

    def compute_weather(world, latitude, longitude)
      # Map lat/lon to grid coordinates
      grid_x, grid_y = GridService.latlon_to_grid_coords(latitude, longitude)

      # Get interpolation cells from macro grid
      interp_data = GridService.interpolation_cells(world, grid_x, grid_y)
      return nil unless interp_data

      # Bilinear interpolation of all weather fields
      weather = bilinear_interpolate(interp_data)

      # Get local terrain for adjustments
      local_terrain = local_terrain(world, latitude, longitude)

      # Apply local terrain adjustments
      weather = apply_terrain_adjustments(weather, local_terrain)

      # Apply procedural noise for variation
      weather = apply_noise(weather, latitude, longitude)

      # Check for storm overlay
      storm = StormService.storm_at(world, grid_x, grid_y)
      weather = apply_storm_overlay(weather, storm) if storm

      # Derive weather condition
      weather['condition'] = derive_condition(weather)

      # Add metadata
      weather['latitude'] = latitude
      weather['longitude'] = longitude
      weather['computed_at'] = Time.now.iso8601

      weather
    end

    def bilinear_interpolate(interp_data)
      tl = interp_data[:top_left]
      tr = interp_data[:top_right]
      bl = interp_data[:bottom_left]
      br = interp_data[:bottom_right]
      fx = interp_data[:fx]
      fy = interp_data[:fy]

      # Fields to interpolate
      fields = %w[temperature humidity pressure wind_dir wind_speed cloud_cover precip_rate instability]

      result = {}
      fields.each do |field|
        v_tl = (tl&.dig(field) || 0).to_f
        v_tr = (tr&.dig(field) || 0).to_f
        v_bl = (bl&.dig(field) || 0).to_f
        v_br = (br&.dig(field) || 0).to_f

        # Bilinear interpolation
        top = v_tl * (1 - fx) + v_tr * fx
        bottom = v_bl * (1 - fx) + v_br * fx
        result[field] = (top * (1 - fy) + bottom * fy).round(2)
      end

      # Wind direction needs special handling (circular interpolation)
      result['wind_dir'] = circular_interpolate_direction(
        tl&.dig('wind_dir') || 0,
        tr&.dig('wind_dir') || 0,
        bl&.dig('wind_dir') || 0,
        br&.dig('wind_dir') || 0,
        fx, fy
      )

      result
    end

    def circular_interpolate_direction(tl, tr, bl, br, fx, fy)
      # Convert to radians for circular math
      tl_rad = tl * Math::PI / 180
      tr_rad = tr * Math::PI / 180
      bl_rad = bl * Math::PI / 180
      br_rad = br * Math::PI / 180

      # Average using sin/cos to handle wrap-around
      sin_sum = Math.sin(tl_rad) * (1 - fx) * (1 - fy) +
                Math.sin(tr_rad) * fx * (1 - fy) +
                Math.sin(bl_rad) * (1 - fx) * fy +
                Math.sin(br_rad) * fx * fy

      cos_sum = Math.cos(tl_rad) * (1 - fx) * (1 - fy) +
                Math.cos(tr_rad) * fx * (1 - fy) +
                Math.cos(bl_rad) * (1 - fx) * fy +
                Math.cos(br_rad) * fx * fy

      result = Math.atan2(sin_sum, cos_sum) * 180 / Math::PI
      result += 360 if result < 0
      result.round.to_i % 360
    end

    # ========================================
    # Local Adjustments
    # ========================================

    def local_terrain(world, latitude, longitude)
      # Find nearest WorldHex by lat/lon
      hex = WorldHex.find_nearest_by_latlon(world.id, latitude, longitude)
      return nil unless hex

      {
        'terrain_type' => hex.terrain_type,
        'altitude' => hex.altitude || 0
      }
    rescue StandardError => e
      warn "[WeatherGrid::InterpolationService] Local terrain lookup failed: #{e.message}"
      nil
    end

    def apply_terrain_adjustments(weather, terrain)
      return weather unless terrain

      altitude = terrain['altitude'] || 0

      # Altitude lapse rate: -6.5C per 1000m
      if altitude > 100
        lapse = (altitude / 1000.0) * 6.5
        weather['temperature'] = (weather['temperature'] - lapse).round(2)
      end

      # Altitude affects pressure
      pressure_drop = altitude * 0.12 / 100
      weather['pressure'] = (weather['pressure'] - pressure_drop).round(2)

      # Terrain type micro-effects
      case terrain['terrain_type']
      when 'ocean', 'lake'
        # Water bodies moderate temperature
        weather['humidity'] = [weather['humidity'] + 5, 100].min
      when 'dense_forest', 'jungle'
        # Forests increase humidity, reduce wind
        weather['humidity'] = [weather['humidity'] + 3, 100].min
        weather['wind_speed'] = (weather['wind_speed'] * 0.7).round(2)
      when 'desert'
        # Deserts reduce humidity
        weather['humidity'] = [weather['humidity'] - 10, 0].max
      when 'mountain'
        # Mountains increase wind, decrease temperature
        weather['wind_speed'] = (weather['wind_speed'] * 1.3).round(2)
        weather['temperature'] = (weather['temperature'] - 3).round(2)
      end

      weather
    end

    def apply_noise(weather, latitude, longitude)
      # Deterministic noise based on coordinates
      # Using simple hash-based noise for consistency
      seed = (latitude * 73856093).to_i ^ (longitude * 19349663).to_i
      noise_temp = ((seed % 100).abs - 50) / 50.0 * 1.5  # +/-1.5C
      noise_humidity = ((seed % 97).abs - 48) / 48.0 * 3  # +/-3%

      weather['temperature'] = (weather['temperature'] + noise_temp).round(2)
      weather['humidity'] = (weather['humidity'] + noise_humidity).clamp(0, 100).round(2)

      weather
    end

    def apply_storm_overlay(weather, storm)
      return weather unless storm

      intensity = storm['intensity'] || 0.5
      storm_type = storm['type'] || 'thunderstorm'

      # Storm overrides condition
      weather['active_storm'] = {
        'id' => storm['id'],
        'type' => storm_type,
        'name' => storm['name'],
        'intensity' => intensity,
        'phase' => storm['phase']
      }

      # Boost effects based on intensity
      weather['precip_rate'] = [weather['precip_rate'] + intensity * 20, 50].min.round(2)
      weather['cloud_cover'] = [weather['cloud_cover'] + intensity * 50, 100].min.round(2)
      weather['wind_speed'] = [weather['wind_speed'] + intensity * 40, 200].min.round(2)
      weather['humidity'] = [weather['humidity'] + intensity * 20, 100].min.round(2)

      weather
    end

    # ========================================
    # Condition Derivation
    # ========================================

    def derive_condition(weather)
      # Check for active storm first
      if weather['active_storm']
        return weather['active_storm']['type'] || 'storm'
      end

      temp = weather['temperature']
      humidity = weather['humidity']
      clouds = weather['cloud_cover']
      precip = weather['precip_rate']
      instability = weather['instability']
      wind = weather['wind_speed']

      # Check conditions in order of specificity
      if humidity >= 95 && wind < 10 && precip < 0.5
        'fog'
      elsif precip >= 10
        temp > 2 ? 'heavy_rain' : 'blizzard'
      elsif precip >= 5 && instability >= 60 && temp > 10
        'thunderstorm'
      elsif precip >= 2
        temp > 2 ? 'rain' : 'snow'
      elsif precip >= 0.1
        temp > 2 ? 'light_rain' : 'light_snow'
      elsif clouds >= 80
        'overcast'
      elsif clouds >= 50
        'cloudy'
      elsif clouds >= 20
        'partly_cloudy'
      else
        'clear'
      end
    end

    def build_description(weather)
      condition = weather['condition']
      temp = weather['temperature'].round
      wind = weather['wind_speed'].round
      humidity = weather['humidity'].round

      condition_text = condition.tr('_', ' ').capitalize

      # Add storm name if applicable
      if weather['active_storm']&.dig('name')
        condition_text = "#{weather['active_storm']['name']} (#{condition_text})"
      end

      wind_text = case wind
                  when 0..5 then 'calm'
                  when 6..15 then 'light breeze'
                  when 16..30 then 'moderate wind'
                  when 31..60 then 'strong wind'
                  else 'severe wind'
                  end

      "#{condition_text}, #{temp}°C, #{wind_text} (#{wind} kph), #{humidity}% humidity"
    end

    # ========================================
    # Caching
    # ========================================

    def cache_key(world_id, latitude, longitude)
      lat_bucket = (latitude * 10).round
      lon_bucket = (longitude * 10).round
      "weather:#{world_id}:ll:#{lat_bucket}:#{lon_bucket}"
    end

    def cached_weather(world, latitude, longitude)
      return nil unless redis_available?

      REDIS_POOL.with do |redis|
        json = redis.get(cache_key(world.id, latitude, longitude))
        return nil unless json

        JSON.parse(json)
      end
    rescue StandardError => e
      warn "[WeatherGrid::InterpolationService] Cache read failed: #{e.message}"
      nil
    end

    def cache_weather(world, latitude, longitude, weather)
      return unless redis_available?

      REDIS_POOL.with do |redis|
        redis.setex(
          cache_key(world.id, latitude, longitude),
          CACHE_TTL,
          weather.to_json
        )
      end
    rescue StandardError => e
      warn "[WeatherGrid::InterpolationService] Cache write failed: #{e.message}"
    end

    def redis_available?
      defined?(REDIS_POOL) && REDIS_POOL
    end
  end
end
