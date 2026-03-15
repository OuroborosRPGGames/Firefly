# frozen_string_literal: true

# SunCalculator provides astronomically-accurate sunrise/sunset calculations
# based on NOAA Solar Calculator formulas.
#
# Features:
# - Accurate sunrise/sunset times for any latitude/longitude
# - Handles polar regions (midnight sun and polar night)
# - Accounts for atmospheric refraction
# - Supports any day of the year
#
# @example Basic usage
#   SunCalculator.sunrise_sunset(
#     latitude: 45.0,
#     longitude: -93.0,
#     day_of_year: 172,
#     timezone_offset_hours: -5
#   )
#   # => { sunrise: 5.28, sunset: 21.03, status: :normal }
#
# @example Polar regions
#   SunCalculator.sunrise_sunset(latitude: 80.0, longitude: 0, day_of_year: 172)
#   # => { sunrise: nil, sunset: nil, status: :midnight_sun }
#
# @see https://gml.noaa.gov/grad/solcalc/solareqns.PDF
#
module SunCalculator
  DEGREES_TO_RADIANS = Math::PI / 180.0
  RADIANS_TO_DEGREES = 180.0 / Math::PI

  # Solar zenith angle for civil twilight (accounts for atmospheric refraction)
  # 90.833° = 90° + 50' (sun center below horizon + refraction correction)
  SOLAR_ZENITH = 90.833

  class << self
    # Calculate sunrise and sunset times for a given location and day
    #
    # @param latitude [Float] Latitude in degrees (-90 to 90)
    # @param longitude [Float] Longitude in degrees (-180 to 180)
    # @param day_of_year [Integer] Day of year (1-366)
    # @param timezone_offset_hours [Float] Hours offset from UTC (e.g., -5 for EST)
    # @return [Hash] Result containing:
    #   - :sunrise [Float, nil] Sunrise hour in local time (0.0-24.0)
    #   - :sunset [Float, nil] Sunset hour in local time (0.0-24.0)
    #   - :status [Symbol] :normal, :midnight_sun, or :polar_night
    def sunrise_sunset(latitude:, longitude:, day_of_year:, timezone_offset_hours: 0)
      # Clamp inputs
      lat = latitude.to_f.clamp(-90.0, 90.0)
      lon = longitude.to_f.clamp(-180.0, 180.0)
      day = day_of_year.to_i.clamp(1, 366)
      tz_offset = timezone_offset_hours.to_f

      # 1. Calculate gamma (fractional year in radians)
      # gamma = 2π/365 * (day_of_year - 1)
      gamma = 2.0 * Math::PI * (day - 1) / 365.0

      # 2. Solar declination (sun's angle relative to equator)
      # Uses NOAA formula for better accuracy
      declination_rad = 0.006918 -
                        0.399912 * Math.cos(gamma) +
                        0.070257 * Math.sin(gamma) -
                        0.006758 * Math.cos(2.0 * gamma) +
                        0.000907 * Math.sin(2.0 * gamma) -
                        0.002697 * Math.cos(3.0 * gamma) +
                        0.00148 * Math.sin(3.0 * gamma)

      # 3. Equation of time (correction for elliptical orbit and axial tilt)
      # Returns minutes difference between solar noon and clock noon
      eot_minutes = 229.18 * (0.000075 +
                              0.001868 * Math.cos(gamma) -
                              0.032077 * Math.sin(gamma) -
                              0.014615 * Math.cos(2.0 * gamma) -
                              0.040849 * Math.sin(2.0 * gamma))

      # 4. Hour angle (how far the sun travels from solar noon to sunrise/sunset)
      lat_rad = lat * DEGREES_TO_RADIANS
      zenith_rad = SOLAR_ZENITH * DEGREES_TO_RADIANS

      # cos(ω) = cos(zenith) / (cos(lat) * cos(declination)) - tan(lat) * tan(declination)
      cos_hour_angle = (Math.cos(zenith_rad) / (Math.cos(lat_rad) * Math.cos(declination_rad))) -
                       (Math.tan(lat_rad) * Math.tan(declination_rad))

      # Handle polar regions where sun doesn't rise or set
      if cos_hour_angle > 1.0
        # Sun never rises (polar night)
        return { sunrise: nil, sunset: nil, status: :polar_night }
      elsif cos_hour_angle < -1.0
        # Sun never sets (midnight sun)
        return { sunrise: nil, sunset: nil, status: :midnight_sun }
      end

      # Convert hour angle to degrees
      hour_angle_deg = Math.acos(cos_hour_angle) * RADIANS_TO_DEGREES

      # 5. Calculate solar noon in UTC minutes from midnight
      # Solar noon = 720 - 4 * longitude - equation_of_time
      # (720 = minutes in 12 hours)
      solar_noon_utc = 720.0 - (4.0 * lon) - eot_minutes

      # 6. Calculate sunrise and sunset in UTC minutes from midnight
      sunrise_utc_minutes = solar_noon_utc - (hour_angle_deg * 4.0)
      sunset_utc_minutes = solar_noon_utc + (hour_angle_deg * 4.0)

      # 7. Convert to local hours
      sunrise_local = ((sunrise_utc_minutes / 60.0) + tz_offset) % 24.0
      sunset_local = ((sunset_utc_minutes / 60.0) + tz_offset) % 24.0

      # Handle edge case where sunset might wrap to next day
      # (shouldn't normally happen except in extreme cases)
      sunrise_local = sunrise_local.round(2)
      sunset_local = sunset_local.round(2)

      { sunrise: sunrise_local, sunset: sunset_local, status: :normal }
    end

    # Calculate day length in hours for a given location and day
    #
    # @param latitude [Float] Latitude in degrees
    # @param longitude [Float] Longitude in degrees
    # @param day_of_year [Integer] Day of year
    # @return [Float, nil] Day length in hours, or nil for polar conditions
    def day_length(latitude:, longitude:, day_of_year:)
      result = sunrise_sunset(
        latitude: latitude,
        longitude: longitude,
        day_of_year: day_of_year
      )

      case result[:status]
      when :midnight_sun then 24.0
      when :polar_night then 0.0
      when :normal
        sunset = result[:sunset]
        sunrise = result[:sunrise]

        # Handle wrap-around (sunset before sunrise means it crossed midnight)
        if sunset < sunrise
          (24.0 - sunrise) + sunset
        else
          sunset - sunrise
        end
      end
    end

    # Get solar noon time for a given location
    #
    # @param longitude [Float] Longitude in degrees
    # @param day_of_year [Integer] Day of year
    # @param timezone_offset_hours [Float] Hours offset from UTC
    # @return [Float] Solar noon in local hours (0.0-24.0)
    def solar_noon(longitude:, day_of_year:, timezone_offset_hours: 0)
      lon = longitude.to_f.clamp(-180.0, 180.0)
      day = day_of_year.to_i.clamp(1, 366)
      tz_offset = timezone_offset_hours.to_f

      gamma = 2.0 * Math::PI * (day - 1) / 365.0

      eot_minutes = 229.18 * (0.000075 +
                              0.001868 * Math.cos(gamma) -
                              0.032077 * Math.sin(gamma) -
                              0.014615 * Math.cos(2.0 * gamma) -
                              0.040849 * Math.sin(2.0 * gamma))

      solar_noon_utc = 720.0 - (4.0 * lon) - eot_minutes
      ((solar_noon_utc / 60.0) + tz_offset) % 24.0
    end
  end
end
