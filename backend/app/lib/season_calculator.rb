# frozen_string_literal: true

# SeasonCalculator handles astronomical season calculations with latitude awareness.
#
# Features:
# - Astronomical boundaries using solstices/equinoxes
# - Hemisphere inversion (Southern hemisphere gets opposite seasons)
# - Latitude-based season systems (tropical wet/dry, polar day/night)
# - Gradual transition periods between seasons
# - Season progress tracking (0.0 to 1.0)
#
# @example
#   SeasonCalculator.season_for(day_of_year: 172, latitude: 45.0)
#   # => { season: :summer, raw_season: :summer, system: :temperate, progress: 0.0, intensity: :early }
#
#   SeasonCalculator.season_for(day_of_year: 172, latitude: -45.0)
#   # => { season: :winter, raw_season: :winter, system: :temperate, progress: 0.0, intensity: :early }
#
#   SeasonCalculator.season_for(day_of_year: 172, latitude: 10.0)
#   # => { season: :summer, raw_season: :wet, system: :tropical, progress: 0.5, intensity: :mid }
#
module SeasonCalculator
  # Astronomical boundaries (approximate day of year)
  # These represent the Northern Hemisphere boundaries
  BOUNDARIES = {
    vernal_equinox: 79,    # ~Mar 20
    summer_solstice: 172,  # ~Jun 21
    autumnal_equinox: 265, # ~Sep 22
    winter_solstice: 355   # ~Dec 21
  }.freeze

  # Latitude bands for different season systems
  # Ranges are in degrees from equator (absolute value)
  LATITUDE_BANDS = {
    tropical:      { min: 0,    max: 23.5 },  # Wet/Dry seasons
    subtropical:   { min: 23.5, max: 35.0 },  # Mild 4 seasons
    temperate:     { min: 35.0, max: 55.0 },  # Traditional 4 seasons
    high_latitude: { min: 55.0, max: 66.5 },  # Extended winters
    polar:         { min: 66.5, max: 90.0 }   # Polar day/night
  }.freeze

  # Transition period in days between seasons
  TRANSITION_DAYS = 21

  # Default latitude when none provided
  DEFAULT_LATITUDE = 45.0

  # Standard 4 seasons
  TEMPERATE_SEASONS = %i[spring summer fall winter].freeze

  # Tropical seasons
  TROPICAL_SEASONS = %i[wet dry].freeze

  # Polar seasons
  POLAR_SEASONS = %i[polar_day polar_night].freeze

  class << self
    # Calculate season information for a given day and latitude
    # @param day_of_year [Integer] Day of year (1-366)
    # @param latitude [Float] Latitude in degrees (-90 to 90)
    # @return [Hash] Season details including:
    #   - :season - Mapped temperate season for backward compatibility
    #   - :raw_season - Actual season (:wet/:dry for tropical, :polar_day/:polar_night for polar)
    #   - :system - Season system type (:tropical, :temperate, :polar, etc.)
    #   - :progress - Position within season (0.0-1.0)
    #   - :intensity - :early, :mid, or :late
    #   - :in_transition - Whether in transition period between seasons
    def season_for(day_of_year:, latitude: DEFAULT_LATITUDE)
      # Clamp inputs
      day = day_of_year.to_i.clamp(1, 366)
      lat = latitude.to_f.clamp(-90.0, 90.0)

      # Determine season system based on latitude
      system = season_system_for(lat)

      # Calculate based on season system
      case system
      when :tropical
        tropical_season(day, lat)
      when :polar
        polar_season(day, lat)
      else
        temperate_season(day, lat, system)
      end
    end

    # Get the season system for a latitude
    # @param latitude [Float] Latitude in degrees
    # @return [Symbol] :tropical, :subtropical, :temperate, :high_latitude, or :polar
    def season_system_for(latitude)
      abs_lat = latitude.abs

      LATITUDE_BANDS.each do |system, range|
        return system if abs_lat >= range[:min] && abs_lat < range[:max]
      end

      # Edge case: exactly 90 degrees
      :polar
    end

    # Check if in Southern Hemisphere
    # @param latitude [Float] Latitude in degrees
    # @return [Boolean]
    def southern_hemisphere?(latitude)
      latitude < 0
    end

    # Get astronomical season boundaries adjusted for a given year
    # @param year [Integer] The year
    # @return [Hash] Day of year for each boundary
    def boundaries_for_year(year)
      # Leap year adjustment - boundaries shift slightly
      leap_adjustment = Date.leap?(year) ? 1 : 0

      {
        vernal_equinox: BOUNDARIES[:vernal_equinox] + leap_adjustment,
        summer_solstice: BOUNDARIES[:summer_solstice] + leap_adjustment,
        autumnal_equinox: BOUNDARIES[:autumnal_equinox] + leap_adjustment,
        winter_solstice: BOUNDARIES[:winter_solstice] + leap_adjustment
      }
    end

    # Map a raw season to its temperate equivalent
    # @param raw_season [Symbol] The raw season
    # @return [Symbol] The temperate season equivalent
    def map_to_temperate(raw_season)
      case raw_season
      when :wet, :polar_day then :summer
      when :dry, :polar_night then :winter
      else raw_season
      end
    end

    private

    # Calculate temperate (4-season) season
    def temperate_season(day_of_year, latitude, system)
      # Get base season for Northern Hemisphere
      base_result = calculate_temperate_base(day_of_year)

      # Invert for Southern Hemisphere
      if southern_hemisphere?(latitude)
        base_result = invert_temperate_season(base_result)
      end

      # Adjust for high latitude (extended winter)
      if system == :high_latitude
        base_result = adjust_for_high_latitude(base_result, day_of_year, latitude)
      end

      base_result.merge(
        season: base_result[:raw_season],
        system: system
      )
    end

    # Calculate base temperate season for Northern Hemisphere
    def calculate_temperate_base(day_of_year)
      boundaries = BOUNDARIES

      # Determine which season and calculate progress
      if day_of_year >= boundaries[:vernal_equinox] && day_of_year < boundaries[:summer_solstice]
        # Spring
        season_length = boundaries[:summer_solstice] - boundaries[:vernal_equinox]
        days_into = day_of_year - boundaries[:vernal_equinox]
        build_season_result(:spring, days_into, season_length, boundaries[:vernal_equinox])

      elsif day_of_year >= boundaries[:summer_solstice] && day_of_year < boundaries[:autumnal_equinox]
        # Summer
        season_length = boundaries[:autumnal_equinox] - boundaries[:summer_solstice]
        days_into = day_of_year - boundaries[:summer_solstice]
        build_season_result(:summer, days_into, season_length, boundaries[:summer_solstice])

      elsif day_of_year >= boundaries[:autumnal_equinox] && day_of_year < boundaries[:winter_solstice]
        # Fall
        season_length = boundaries[:winter_solstice] - boundaries[:autumnal_equinox]
        days_into = day_of_year - boundaries[:autumnal_equinox]
        build_season_result(:fall, days_into, season_length, boundaries[:autumnal_equinox])

      else
        # Winter (wraps around year boundary)
        days_after_winter_solstice = if day_of_year >= boundaries[:winter_solstice]
                                       day_of_year - boundaries[:winter_solstice]
                                     else
                                       day_of_year + (366 - boundaries[:winter_solstice])
                                     end
        season_length = boundaries[:vernal_equinox] + (366 - boundaries[:winter_solstice])
        build_season_result(:winter, days_after_winter_solstice, season_length, boundaries[:winter_solstice])
      end
    end

    # Build season result hash
    def build_season_result(season, days_into, season_length, boundary_day)
      progress = (days_into.to_f / season_length).clamp(0.0, 1.0)
      in_transition = days_into < TRANSITION_DAYS || (season_length - days_into) < TRANSITION_DAYS

      {
        raw_season: season,
        progress: progress.round(2),
        intensity: calculate_intensity(progress),
        in_transition: in_transition
      }
    end

    # Calculate intensity from progress
    def calculate_intensity(progress)
      case progress
      when 0.0...0.33 then :early
      when 0.33...0.67 then :mid
      else :late
      end
    end

    # Invert season for Southern Hemisphere
    def invert_temperate_season(result)
      inverted = case result[:raw_season]
                 when :spring then :fall
                 when :summer then :winter
                 when :fall then :spring
                 when :winter then :summer
                 else result[:raw_season]
                 end

      result.merge(raw_season: inverted)
    end

    # Adjust for high latitude (extended winter)
    def adjust_for_high_latitude(result, day_of_year, latitude)
      # High latitudes have shorter summers and longer winters
      # Spring and fall are compressed
      abs_lat = latitude.abs
      latitude_factor = (abs_lat - 55.0) / 11.5 # 0.0 at 55°, 1.0 at 66.5°

      case result[:raw_season]
      when :spring, :fall
        # These seasons are shorter at high latitudes
        # If we're in the first or last 25% of these seasons, it might still be winter
        if result[:progress] < 0.25 * latitude_factor || result[:progress] > (1.0 - 0.25 * latitude_factor)
          result.merge(raw_season: :winter, in_transition: true)
        else
          result
        end
      else
        result
      end
    end

    # Calculate tropical (wet/dry) season
    def tropical_season(day_of_year, latitude)
      # Tropical seasons are roughly:
      # Wet season: around summer solstice (May-Oct in Northern, Nov-Apr in Southern)
      # Dry season: around winter solstice

      # In Northern Hemisphere tropics, wet season peaks around July
      # In Southern Hemisphere tropics, wet season peaks around January

      wet_peak = southern_hemisphere?(latitude) ? 15 : 196 # Jan 15 or Jul 15

      # Wet season lasts roughly 6 months centered on the peak
      days_from_peak = (day_of_year - wet_peak).abs
      days_from_peak = [days_from_peak, 366 - days_from_peak].min

      in_wet_season = days_from_peak < 90 # ~3 months on each side

      if in_wet_season
        progress = 1.0 - (days_from_peak / 90.0)
        {
          season: :summer,
          raw_season: :wet,
          system: :tropical,
          progress: progress.round(2),
          intensity: calculate_intensity(progress),
          in_transition: days_from_peak > 75
        }
      else
        dry_days = days_from_peak - 90
        progress = dry_days / 90.0
        {
          season: :winter,
          raw_season: :dry,
          system: :tropical,
          progress: progress.clamp(0.0, 1.0).round(2),
          intensity: calculate_intensity(progress.clamp(0.0, 1.0)),
          in_transition: days_from_peak < 105
        }
      end
    end

    # Calculate polar (polar day/night) season
    def polar_season(day_of_year, latitude)
      # Polar regions have extended periods of continuous daylight or darkness
      # Above ~66.5°N: polar day around summer solstice, polar night around winter solstice

      summer_solstice = BOUNDARIES[:summer_solstice]
      winter_solstice = BOUNDARIES[:winter_solstice]

      # Determine if in polar day or polar night
      # Duration depends on how far into polar region
      abs_lat = latitude.abs
      polar_intensity = ((abs_lat - 66.5) / 23.5).clamp(0.0, 1.0) # 0 at 66.5°, 1 at 90°

      # Polar day duration: ranges from ~1 day at 66.5° to ~6 months at 90°
      polar_day_half_duration = (polar_intensity * 90).to_i + 1

      days_from_summer = (day_of_year - summer_solstice).abs
      days_from_summer = [days_from_summer, 366 - days_from_summer].min

      days_from_winter = (day_of_year - winter_solstice).abs
      days_from_winter = [days_from_winter, 366 - days_from_winter].min

      # Check for polar day
      in_polar_day = days_from_summer < polar_day_half_duration

      # Invert for Southern Hemisphere
      if southern_hemisphere?(latitude)
        in_polar_day = days_from_winter < polar_day_half_duration
      end

      if in_polar_day
        progress = 1.0 - (days_from_summer.to_f / polar_day_half_duration)
        progress = 1.0 - (days_from_winter.to_f / polar_day_half_duration) if southern_hemisphere?(latitude)
        {
          season: :summer,
          raw_season: :polar_day,
          system: :polar,
          progress: progress.clamp(0.0, 1.0).round(2),
          intensity: calculate_intensity(progress.clamp(0.0, 1.0)),
          in_transition: progress < 0.1 || progress > 0.9
        }
      else
        # Calculate polar night progress
        reference_days = southern_hemisphere?(latitude) ? days_from_summer : days_from_winter
        max_night_days = 183 - polar_day_half_duration
        progress = reference_days.to_f / max_night_days
        {
          season: :winter,
          raw_season: :polar_night,
          system: :polar,
          progress: progress.clamp(0.0, 1.0).round(2),
          intensity: calculate_intensity(progress.clamp(0.0, 1.0)),
          in_transition: reference_days < TRANSITION_DAYS
        }
      end
    end
  end
end
