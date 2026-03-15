# frozen_string_literal: true

require_relative '../lib/season_calculator'
require_relative '../lib/sun_calculator'

# GameTimeService calculates and manages game time.
# Supports both realtime (1:1) and accelerated time modes.
#
# Season system features:
# - Astronomical boundaries (solstices/equinoxes)
# - Hemisphere awareness (Southern gets inverted seasons)
# - Latitude-based season systems (tropical wet/dry, polar day/night)
# - Gradual transition periods between seasons
#
class GameTimeService
  # Time of day periods
  TIME_PERIODS = %i[dawn day dusk night].freeze

  # Seasons (standard temperate for backward compatibility)
  SEASONS = %i[spring summer fall winter].freeze

  # Extended seasons including climate-specific
  EXTENDED_SEASONS = %i[spring summer fall winter wet dry polar_day polar_night].freeze

  # User-friendly time name mapping (for commands)
  TIME_NAME_MAP = {
    'morning' => :dawn,
    'afternoon' => :day,
    'evening' => :dusk,
    'night' => :night,
    'dawn' => :dawn,
    'day' => :day,
    'dusk' => :dusk
  }.freeze

  class << self
    # Get current game time for a location
    # @param location [Location, nil] the location (uses default config if nil)
    # @return [Time] the current game time
    def current_time(location = nil)
      config = clock_config_for(location)

      if config&.accelerated?
        config.current_game_time
      else
        calculate_realtime(location)
      end
    end

    # Get time of day (dawn, day, dusk, night)
    # @param location [Location, nil] the location
    # @return [Symbol] :dawn, :day, :dusk, :night
    def time_of_day(location = nil)
      game_time = current_time(location)
      current_hour = game_time.hour + (game_time.min / 60.0)

      sun_times = calculate_sun_times(location)

      # Handle polar conditions
      case sun_times[:status]
      when :midnight_sun then return :day
      when :polar_night then return :night
      end

      sunrise = sun_times[:sunrise] || 6.0
      sunset = sun_times[:sunset] || 18.0

      # Define transition periods
      dawn_end = sunrise + 1.5   # Dawn lasts 1.5 hours after sunrise
      dusk_start = sunset - 0.5  # Dusk starts 30 min before sunset
      dusk_end = sunset + 1.0    # Dusk lasts 1 hour after sunset

      if current_hour >= sunrise && current_hour < dawn_end
        :dawn
      elsif current_hour >= dusk_start && current_hour < dusk_end
        :dusk
      elsif current_hour >= dawn_end && current_hour < dusk_start
        :day
      else
        :night
      end
    end

    # Get the current season (backward compatible)
    # Returns mapped temperate seasons for compatibility with existing code
    # @param location [Location, nil] the location
    # @return [Symbol] :spring, :summer, :fall, :winter
    def season(location = nil)
      # Check for world override first
      world = location&.zone&.world
      return world.current_season if world&.current_season

      # Use astronomical calculation with latitude awareness
      season_detail(location)[:season]
    end

    # Get detailed season information including climate-specific data
    # @param location [Location, nil] the location
    # @return [Hash] Season details:
    #   - :season - Mapped temperate season (for backward compat)
    #   - :raw_season - Actual season (:wet/:dry for tropical, :polar_day/:polar_night for polar)
    #   - :system - Season system type (:tropical, :temperate, :polar, etc.)
    #   - :progress - Position within season (0.0-1.0)
    #   - :intensity - :early, :mid, or :late
    #   - :in_transition - Whether in transition period
    def season_detail(location = nil)
      # Check for world override first
      world = location&.zone&.world
      if world&.current_season
        return {
          season: world.current_season,
          raw_season: world.current_season,
          system: :temperate,
          progress: 0.5,
          intensity: :mid,
          in_transition: false
        }
      end

      game_time = current_time(location)
      day_of_year = game_time.yday
      latitude = latitude_for(location)

      SeasonCalculator.season_for(day_of_year: day_of_year, latitude: latitude)
    end

    # Get the raw season (climate-specific, not mapped)
    # @param location [Location, nil] the location
    # @return [Symbol] The raw season (:spring, :summer, :fall, :winter, :wet, :dry, :polar_day, :polar_night)
    def raw_season(location = nil)
      season_detail(location)[:raw_season]
    end

    # Get season progress (0.0 at start, 1.0 at end)
    # @param location [Location, nil] the location
    # @return [Float] Progress through current season
    def season_progress(location = nil)
      season_detail(location)[:progress]
    end

    # Get season intensity (:early, :mid, :late)
    # @param location [Location, nil] the location
    # @return [Symbol] Season intensity
    def season_intensity(location = nil)
      season_detail(location)[:intensity]
    end

    # Get the season system for a location
    # @param location [Location, nil] the location
    # @return [Symbol] :tropical, :subtropical, :temperate, :high_latitude, or :polar
    def season_system(location = nil)
      latitude = latitude_for(location)
      SeasonCalculator.season_system_for(latitude)
    end

    # Check if location is in Southern Hemisphere
    # @param location [Location, nil] the location
    # @return [Boolean]
    def southern_hemisphere?(location = nil)
      latitude = latitude_for(location)
      SeasonCalculator.southern_hemisphere?(latitude)
    end

    # Get combined time+season key for lookups
    # @param location [Location, nil] the location
    # @return [String] e.g., "dawn_spring", "night_winter"
    def time_season_key(location = nil)
      "#{time_of_day(location)}_#{season(location)}"
    end

    # Normalize a user-provided time name to system time symbol
    # @param name [String, Symbol] user input like "morning" or "dawn"
    # @return [Symbol, nil] :dawn, :day, :dusk, :night or nil if invalid
    def normalize_time_name(name)
      return nil if StringHelper.blank?(name) || name.to_s == '-'

      TIME_NAME_MAP[name.to_s.downcase.strip]
    end

    # Normalize a user-provided season name
    # @param name [String, Symbol] user input like "spring"
    # @return [Symbol, nil] :spring, :summer, :fall, :winter or nil if invalid
    def normalize_season_name(name)
      return nil if StringHelper.blank?(name) || name.to_s == '-'

      sym = name.to_s.downcase.strip.to_sym
      SEASONS.include?(sym) ? sym : nil
    end

    # Get a human-readable season description
    # Returns climate-appropriate descriptions based on location's latitude
    # @param location [Location, nil] the location
    # @return [String]
    def season_description(location = nil)
      detail = season_detail(location)
      raw_season = detail[:raw_season]
      system = detail[:system]
      intensity = detail[:intensity]

      # Build intensity prefix
      intensity_prefix = case intensity
                         when :early then 'Early '
                         when :late then 'Late '
                         else ''
                         end

      case system
      when :tropical
        tropical_season_description(raw_season, intensity_prefix)
      when :polar
        polar_season_description(raw_season, intensity_prefix)
      else
        temperate_season_description(raw_season, intensity_prefix)
      end
    end

    # Check if it's nighttime
    # @param location [Location, nil] the location
    # @return [Boolean]
    def night?(location = nil)
      %i[night dusk].include?(time_of_day(location))
    end

    # Check if it's daytime
    # @param location [Location, nil] the location
    # @return [Boolean]
    def day?(location = nil)
      %i[day dawn].include?(time_of_day(location))
    end

    # Get formatted time string
    # @param location [Location, nil] the location
    # @param format [Symbol] :short (HH:MM), :long (H:MM AM/PM), :full (day, date, time)
    # @return [String]
    def formatted_time(location = nil, format: :short)
      game_time = current_time(location)

      case format
      when :short
        game_time.strftime('%H:%M')
      when :long
        game_time.strftime('%l:%M %p').strip
      when :full
        game_time.strftime('%A, %B %d, %Y at %l:%M %p').strip
      when :date_only
        game_time.strftime('%A, %B %d, %Y')
      else
        game_time.strftime('%H:%M')
      end
    end

    # Get formatted date string
    # @param location [Location, nil] the location
    # @return [String]
    def formatted_date(location = nil)
      formatted_time(location, format: :date_only)
    end

    # Get the weekday name
    # @param location [Location, nil] the location
    # @return [String] lowercase weekday name
    def weekday(location = nil)
      current_time(location).strftime('%A').downcase
    end

    # Get the hour (0-23)
    # @param location [Location, nil] the location
    # @return [Integer]
    def hour(location = nil)
      current_time(location).hour
    end

    # Get the minute (0-59)
    # @param location [Location, nil] the location
    # @return [Integer]
    def minute(location = nil)
      current_time(location).min
    end

    # Get sunrise hour for a location
    # @param location [Location, nil] the location
    # @param precise [Boolean] return float for precise time (default: false for backward compat)
    # @return [Integer, Float] hour (0-23 for integer, 0.0-24.0 for float)
    def sunrise_hour(location = nil, precise: false)
      result = calculate_sun_times(location)
      hour = result[:sunrise] || 6.0
      precise ? hour : hour.floor
    end

    # Get sunset hour for a location
    # @param location [Location, nil] the location
    # @param precise [Boolean] return float for precise time (default: false for backward compat)
    # @return [Integer, Float] hour (0-23 for integer, 0.0-24.0 for float)
    def sunset_hour(location = nil, precise: false)
      result = calculate_sun_times(location)
      hour = result[:sunset] || 18.0
      precise ? hour : hour.floor
    end

    # Get detailed sun times for a location
    # @param location [Location, nil] the location
    # @return [Hash] Sun times with :sunrise, :sunset, :status keys
    def sun_times(location = nil)
      calculate_sun_times(location)
    end

    # Get a human-readable time of day description
    # @param location [Location, nil] the location
    # @return [String]
    def time_of_day_description(location = nil)
      case time_of_day(location)
      when :dawn
        'The first light of dawn breaks over the horizon'
      when :day
        'The sun shines overhead'
      when :dusk
        'The sun sinks toward the horizon as dusk settles in'
      when :night
        'Night has fallen'
      end
    end

    private

    # Get latitude for a location using detection chain
    # @param location [Location, nil] the location
    # @return [Float] Latitude in degrees (-90 to 90)
    def latitude_for(location)
      return GameConfig::Season::DEFAULT_LATITUDE unless location

      # 1. Try location's direct latitude (from globe hex system)
      if location.respond_to?(:latitude) && location.latitude
        return location.latitude
      end

      # 2. Try the associated world hex's latitude
      if location.respond_to?(:world_hex)
        world_hex = location.world_hex
        return world_hex.latitude if world_hex&.latitude
      end

      # 3. Try zone center point
      zone = location.zone
      if zone
        if zone.respond_to?(:center_point) && zone.center_point.is_a?(Hash)
          center_y = zone.center_point[:y] || zone.center_point['y']
          return center_y.to_f if center_y
        end

        # 4. Try zone latitude bounds
        if zone.respond_to?(:min_latitude) && zone.respond_to?(:max_latitude) &&
           zone.min_latitude && zone.max_latitude
          return (zone.min_latitude + zone.max_latitude) / 2.0
        end
      end

      # 5. Default to temperate latitude
      GameConfig::Season::DEFAULT_LATITUDE
    end

    # Get temperate season description
    def temperate_season_description(raw_season, intensity_prefix)
      case raw_season
      when :spring
        "#{intensity_prefix}spring has arrived, with new growth everywhere"
      when :summer
        "#{intensity_prefix}summer warmth fills the air"
      when :fall
        "#{intensity_prefix}autumn leaves drift on the breeze"
      when :winter
        "#{intensity_prefix}winter cold settles over the land"
      else
        "The seasons turn"
      end
    end

    # Get tropical season description
    def tropical_season_description(raw_season, intensity_prefix)
      case raw_season
      when :wet
        "The #{intensity_prefix.downcase.strip}#{intensity_prefix.empty? ? '' : ' '}wet season brings heavy rains"
      when :dry
        "The #{intensity_prefix.downcase.strip}#{intensity_prefix.empty? ? '' : ' '}dry season parches the land"
      else
        temperate_season_description(raw_season, intensity_prefix)
      end
    end

    # Get polar season description
    def polar_season_description(raw_season, intensity_prefix)
      case raw_season
      when :polar_day
        "The #{intensity_prefix.downcase.strip}#{intensity_prefix.empty? ? '' : ' '}polar day bathes everything in endless light"
      when :polar_night
        "The #{intensity_prefix.downcase.strip}#{intensity_prefix.empty? ? '' : ' '}polar night cloaks everything in darkness"
      else
        temperate_season_description(raw_season, intensity_prefix)
      end
    end

    # Get clock config for a location
    # @param location [Location, nil] the location
    # @return [GameClockConfig, nil]
    def clock_config_for(location)
      return nil unless location

      universe = location.zone&.world&.universe
      return nil unless universe

      GameClockConfig.first(universe_id: universe.id, is_active: true)
    end

    # Calculate realtime with timezone offset
    # @param location [Location, nil] the location
    # @return [Time]
    def calculate_realtime(location)
      # Try to get timezone offset from weather API
      if location
        weather = Weather.first(location_id: location.id)
        if weather&.timezone_offset
          return Time.now.utc + weather.timezone_offset
        end
      end

      # Fall back to reference timezone from config
      config = clock_config_for(location)
      if config&.reference_timezone && config.reference_timezone != 'UTC'
        # For simplicity, just return UTC time
        # A full implementation would use TZInfo gem
        return Time.now.utc
      end

      Time.now
    end

    # Calculate sun times using coordinate-based astronomical calculation
    # Priority: 1) Weather API data, 2) Coordinate calculation, 3) Defaults
    # @param location [Location, nil] the location
    # @return [Hash] Sun times with :sunrise, :sunset, :status keys
    def calculate_sun_times(location)
      return default_sun_times unless location

      # 1. Weather API data (real-world locations with API source)
      weather = Weather.first(location_id: location.id)
      if weather&.weather_source == 'api' && weather.sunrise_at && weather.sunset_at
        return {
          sunrise: weather.sunrise_at.hour + (weather.sunrise_at.min / 60.0),
          sunset: weather.sunset_at.hour + (weather.sunset_at.min / 60.0),
          status: :api
        }
      end

      # 2. Calculate from coordinates
      coords = coordinates_for_location(location)
      if coords
        day_of_year = current_time(location).yday
        tz_hours = timezone_offset_for(location) / 3600.0

        result = SunCalculator.sunrise_sunset(
          latitude: coords[:latitude],
          longitude: coords[:longitude],
          day_of_year: day_of_year,
          timezone_offset_hours: tz_hours
        )

        case result[:status]
        when :midnight_sun
          return { sunrise: 0.0, sunset: 24.0, status: :midnight_sun }
        when :polar_night
          return { sunrise: 12.0, sunset: 12.0, status: :polar_night }
        else
          return result.merge(status: :calculated)
        end
      end

      # 3. Defaults
      default_sun_times(location)
    end

    # Get coordinates for a location
    # Priority: 1) Explicit lat/lon, 2) Hex-derived coordinates
    # @param location [Location] the location
    # @return [Hash, nil] { latitude:, longitude: } or nil
    def coordinates_for_location(location)
      # Explicit lat/lon on location
      if location.respond_to?(:latitude) && location.respond_to?(:longitude) &&
         location.latitude && location.longitude
        return { latitude: location.latitude, longitude: location.longitude }
      end

      # Hex-derived coordinates
      if location.respond_to?(:hex_x) && location.respond_to?(:hex_y) &&
         location.hex_x && location.hex_y
        world_size = location.world&.world_size || 1.0
        lonlat = WorldHexGrid.hex_to_lonlat(location.hex_x, location.hex_y, world_size)
        return { latitude: lonlat[1], longitude: lonlat[0] } if lonlat
      end

      nil
    end

    # Get timezone offset for a location in seconds
    # @param location [Location] the location
    # @return [Integer] Timezone offset in seconds from UTC
    def timezone_offset_for(location)
      # First try weather API timezone offset
      weather = Weather.first(location_id: location.id)
      return weather.timezone_offset if weather&.timezone_offset

      # Approximate from longitude: 1 hour per 15 degrees
      coords = coordinates_for_location(location)
      return 0 unless coords

      (coords[:longitude] / 15.0 * 3600).round
    end

    # Get default sun times when no location or coordinates available
    # @param location [Location, nil] the location (for clock config)
    # @return [Hash] Default sun times
    def default_sun_times(location = nil)
      config = clock_config_for(location)
      {
        sunrise: config&.fixed_dawn_hour&.to_f || 6.0,
        sunset: config&.fixed_dusk_hour&.to_f || 18.0,
        status: :default
      }
    end
  end
end
