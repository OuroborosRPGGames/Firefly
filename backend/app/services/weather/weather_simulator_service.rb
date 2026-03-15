# frozen_string_literal: true

# Realistic weather simulation for fictional worlds.
# Considers latitude, season, climate zone, and world/zone modifiers.
# Produces gradual weather transitions instead of random jumps.
class WeatherSimulatorService
  # Seasonal weather condition pools
  # cold_regions: arctic, subarctic, temperate in winter
  # warm_regions: tropical, subtropical, temperate in summer
  SEASONAL_CONDITIONS = {
    'winter' => {
      cold_regions: %w[snow blizzard clear cloudy fog cold_snap],
      warm_regions: %w[rain cloudy overcast clear fog]
    },
    'summer' => {
      cold_regions: %w[clear cloudy rain fog wind],
      warm_regions: %w[clear cloudy thunderstorm heat_wave rain]
    },
    'spring' => {
      cold_regions: %w[rain cloudy clear snow fog wind],
      warm_regions: %w[rain cloudy clear thunderstorm fog]
    },
    'fall' => {
      cold_regions: %w[cloudy rain fog clear snow wind],
      warm_regions: %w[cloudy rain clear fog wind overcast]
    }
  }.freeze

  class << self
    # Simulate weather for a location
    # @param weather [Weather] Weather record to update
    # @param location [Location, nil] Optional location for context
    # @param zone [Zone, nil] Optional zone for context
    # @return [Weather] Updated weather record
    def simulate(weather, location: nil, zone: nil)
      zone ||= location&.zone
      world = zone&.world

      climate = zone&.climate || 'temperate'
      season = determine_season(world, location)
      time_of_day = GameTimeService.time_of_day(location)

      # Build context with world + zone settings
      context = build_context(world, zone, location)

      # Calculate target weather based on climate/season
      target = calculate_target_weather(climate, season, time_of_day, context)

      # Gradually transition toward target
      transition_weather(weather, target, context)

      weather
    end

    private

    # Safely access zone hash data with logging for malformed data
    def safe_zone_access(zone, key)
      zone&.[](key)
    rescue StandardError => e
      warn "[WeatherSimulator] Invalid zone data for #{key}: #{e.message}"
      nil
    end

    # Determine season for weather simulation
    # Uses raw season (wet/dry for tropical) when available for better climate accuracy
    def determine_season(world, location)
      # World can override season
      world_season = world&.current_season
      return world_season if world_season

      # Get detailed season info for climate-aware weather
      detail = GameTimeService.season_detail(location)

      # For tropical climates, map wet->summer (rainy), dry->winter (dry) for condition pools
      # For other climates, use the mapped temperate season
      case detail[:system]
      when :tropical
        # Wet season = more precipitation, dry season = less
        detail[:raw_season] == :wet ? :summer : :winter
      when :polar
        # Polar day/night map to summer/winter
        detail[:raw_season] == :polar_day ? :summer : :winter
      else
        detail[:season]
      end
    end

    # Get the season system for climate-specific adjustments
    def season_system_for(location)
      GameTimeService.season_system(location)
    end

    def build_context(world, zone, location = nil)
      {
        # World-level globals
        global_temp_offset: world&.global_temp_offset || 0,
        storm_multiplier: world&.effective_storm_frequency || 1.0,
        precipitation_multiplier: world&.effective_precipitation || 1.0,
        variability: world&.effective_variability || 1.0,

        # Zone-level modifiers (use defensive hash access)
        zone_temp_modifier: safe_zone_access(zone, :temperature_modifier) || 0,
        zone_humidity_modifier: safe_zone_access(zone, :humidity_modifier) || 0,
        zone_precipitation_modifier: safe_zone_access(zone, :precipitation_modifier) || 0,
        zone_storm_modifier: safe_zone_access(zone, :storm_modifier), # nil = use world default

        # Season system for climate-specific adjustments
        season_system: season_system_for(location)
      }
    end

    def calculate_target_weather(climate, season, time_of_day, context)
      {
        temperature: calculate_temperature(climate, season, time_of_day, context),
        condition: select_condition(climate, season, context),
        intensity: select_intensity(climate, context),
        humidity: calculate_humidity(climate, season, context),
        wind_speed: calculate_wind(climate, season, context),
        cloud_cover: calculate_clouds(season, context)
      }
    end

    def calculate_temperature(climate, season, time_of_day, context)
      ws = GameConfig::WeatherSimulator
      config = ws::CLIMATE_TEMPS[climate] || ws::CLIMATE_TEMPS['temperate']
      seasonal_mult = ws::SEASONAL_MULTIPLIERS
      time_variations = ws::TIME_OF_DAY_VARIATIONS

      # Base temperature from climate
      temp = config[:base]

      # Seasonal adjustment
      temp += case season.to_s
              when 'summer' then config[:summer_delta]
              when 'winter' then config[:winter_delta]
              when 'spring' then config[:summer_delta] * seasonal_mult[:spring]
              when 'fall'   then config[:winter_delta] * seasonal_mult[:fall]
              else 0
              end

      # Day/night variation - reduced for polar regions during polar day/night
      day_night_variation = time_variations[time_of_day.to_sym] || 0

      # Polar regions have minimal day/night temperature variation during polar day/night
      if context[:season_system] == :polar
        day_night_variation *= ws::POLAR_VARIATION_MULTIPLIER
      end

      temp += day_night_variation

      # Apply world global offset
      temp += context[:global_temp_offset]

      # Apply area modifier
      temp += context[:zone_temp_modifier]

      # Random daily variation scaled by variability
      variation = (rand(ws::DAILY_VARIATION_RANGE) * context[:variability]).to_i
      temp += variation

      temp.clamp(ws::TEMPERATURE_BOUNDS.min, ws::TEMPERATURE_BOUNDS.max)
    end

    def select_condition(climate, season, context)
      ws = GameConfig::WeatherSimulator
      clamp_range = ws::CONDITION_WEIGHT_CLAMP

      # Determine if this is a "cold" or "warm" region for this season
      is_cold_region = %w[arctic subarctic].include?(climate)
      is_cold_region ||= climate == 'temperate' && %w[winter fall].include?(season.to_s)

      region_type = is_cold_region ? :cold_regions : :warm_regions
      pool = SEASONAL_CONDITIONS.dig(season.to_s, region_type) ||
             SEASONAL_CONDITIONS.dig('spring', region_type) ||
             %w[clear cloudy rain]

      # Adjust for precipitation and storm multipliers
      effective_storm = context[:zone_storm_modifier] || context[:storm_multiplier]
      effective_precip = context[:precipitation_multiplier] *
                         (1 + (context[:zone_precipitation_modifier] / 100.0))

      # Higher storm multiplier = more chance of storm conditions
      storm_conditions = %w[storm thunderstorm blizzard]
      precip_conditions = %w[rain snow fog]

      # Weight the pool based on multipliers
      weighted_pool = pool.flat_map do |condition|
        if storm_conditions.include?(condition)
          Array.new((effective_storm * 2).to_i.clamp(clamp_range.min, clamp_range.max), condition)
        elsif precip_conditions.include?(condition)
          Array.new((effective_precip * 2).to_i.clamp(clamp_range.min, clamp_range.max), condition)
        else
          [condition]
        end
      end

      # Use seasonal pool weight vs any valid condition
      if rand < ws::SEASONAL_POOL_WEIGHT
        weighted_pool.sample
      else
        Weather::CONDITIONS.sample
      end
    end

    def select_intensity(climate, context)
      ws = GameConfig::WeatherSimulator
      weights = ws::INTENSITY_WEIGHTS[climate] || ws::INTENSITY_WEIGHTS['temperate']

      # Storm multiplier affects severe weather probability
      effective_storm = context[:zone_storm_modifier] || context[:storm_multiplier]
      adjusted_weights = weights.dup

      if effective_storm > 1.0
        # More severe weather when stormy
        adjusted_weights[:severe] = (adjusted_weights[:severe] * effective_storm).to_i
        adjusted_weights[:heavy] = (adjusted_weights[:heavy] * effective_storm).to_i
      elsif effective_storm < 1.0
        # Less severe weather when calm
        adjusted_weights[:severe] = (adjusted_weights[:severe] * effective_storm).to_i.clamp(1, 100)
        adjusted_weights[:light] = (adjusted_weights[:light] / effective_storm).to_i
      end

      weighted_sample(adjusted_weights)
    end

    def calculate_humidity(climate, season, context)
      ws = GameConfig::WeatherSimulator
      base = ws::HUMIDITY_BASES[climate] || ws::HUMIDITY_BASES['temperate']

      # Seasonal adjustment - tropical wet season has higher humidity
      seasonal_adjustment = case season.to_s
                            when 'summer' then -10
                            when 'winter' then 10
                            else 0
                            end

      # Tropical regions: wet season (mapped to summer) means MORE humidity, not less
      if context[:season_system] == :tropical
        tropical_config = ws::TROPICAL_HUMIDITY
        seasonal_adjustment = case season.to_s
                              when 'summer' then tropical_config[:wet_season]
                              when 'winter' then tropical_config[:dry_season]
                              else 0
                              end
      end

      base += seasonal_adjustment

      # Area modifier
      base += context[:zone_humidity_modifier]

      # Random variation
      bounds = ws::HUMIDITY_BOUNDS
      (base + rand(ws::HUMIDITY_VARIATION_RANGE)).clamp(bounds.min, bounds.max)
    end

    def calculate_wind(climate, season, context)
      ws = GameConfig::WeatherSimulator
      base = ws::WIND_BASES[climate] || ws::WIND_BASES['temperate']

      # Storm multiplier increases wind
      effective_storm = context[:zone_storm_modifier] || context[:storm_multiplier]
      base = (base * effective_storm).to_i

      bounds = ws::WIND_BOUNDS
      (base + rand(ws::WIND_VARIATION_RANGE)).clamp(bounds.min, bounds.max)
    end

    def calculate_clouds(season, context)
      ws = GameConfig::WeatherSimulator
      base = ws::CLOUD_BASES[season.to_s] || ws::CLOUD_BASES['spring']

      # Precipitation multiplier affects cloud cover
      effective_precip = context[:precipitation_multiplier]
      base = (base * effective_precip).to_i

      bounds = ws::CLOUD_BOUNDS
      (base + rand(ws::CLOUD_VARIATION_RANGE)).clamp(bounds.min, bounds.max)
    end

    def transition_weather(weather, target, context)
      # Scale max change by variability - uses existing GameConfig::Weather::MAX_CHANGE
      max_change = GameConfig::Weather::MAX_CHANGE
      variability = context[:variability]
      max_temp_change = (max_change[:temperature][:multiplier] * variability).to_i.clamp(
        max_change[:temperature][:min], max_change[:temperature][:max]
      )
      max_humidity_change = (max_change[:humidity][:multiplier] * variability).to_i.clamp(
        max_change[:humidity][:min], max_change[:humidity][:max]
      )
      max_wind_change = (max_change[:wind][:multiplier] * variability).to_i.clamp(
        max_change[:wind][:min], max_change[:wind][:max]
      )
      max_cloud_change = (max_change[:cloud][:multiplier] * variability).to_i.clamp(
        max_change[:cloud][:min], max_change[:cloud][:max]
      )

      # Temperature changes gradually
      new_temp = move_toward(weather.temperature_c || 20, target[:temperature], max_temp_change)

      # Humidity changes gradually
      new_humidity = move_toward(weather.humidity || 50, target[:humidity], max_humidity_change)

      # Wind can change more quickly
      new_wind = move_toward(weather.wind_speed_kph || 10, target[:wind_speed], max_wind_change)

      # Cloud cover transitions
      new_clouds = move_toward(weather.cloud_cover || 50, target[:cloud_cover], max_cloud_change)

      weather.update(
        condition: target[:condition],
        intensity: target[:intensity],
        temperature_c: new_temp,
        humidity: new_humidity,
        wind_speed_kph: new_wind,
        cloud_cover: new_clouds,
        updated_at: Time.now
      )
    end

    def move_toward(current, target, max_change)
      return target if (current - target).abs <= max_change

      current + (target > current ? max_change : -max_change)
    end

    def weighted_sample(weights)
      total = weights.values.sum
      r = rand(total)
      cumulative = 0

      weights.each do |key, weight|
        cumulative += weight
        return key.to_s if r < cumulative
      end

      weights.keys.first.to_s
    end
  end
end
