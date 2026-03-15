# frozen_string_literal: true

# Provides seasonal description and background management for models.
#
# Requirements:
#   - Model must have `seasonal_descriptions` JSONB column
#   - Model must have `seasonal_backgrounds` JSONB column (optional)
#   - Model must have `description` column for fallback
#   - Model must have `default_background_url` column for fallback (optional)
#
# Usage:
#   class Room < Sequel::Model
#     include SeasonalContent
#   end
#
#   room.set_seasonal_description!(:dawn, :spring, "Morning dew...")
#   room.resolve_description(:dawn, :spring)  # => "Morning dew..."
#   room.current_description(location)  # => Uses GameTimeService for time/season
#
# Climate-aware resolution:
#   For non-temperate locations (tropical, polar), the resolution chain is:
#   1. "dawn_wet" (climate-specific time+season)
#   2. "dawn_summer" (mapped temperate time+season)
#   3. "dawn" (time-only)
#   4. "wet" / "dry" (raw season)
#   5. "summer" / "winter" (mapped temperate season)
#   6. "default"
#
module SeasonalContent
  def self.included(base)
    base.extend(ClassMethods)
    base.include(SeasonalContentCore)
  end

  module ClassMethods
    # No class methods needed currently
  end

  # ========================================
  # Seasonal Description Methods
  # ========================================

  # Set a seasonal description
  # @param time [Symbol, String, nil] :dawn, :day, :dusk, :night or nil/'-' for any time
  # @param season [Symbol, String, nil] :spring, :summer, :fall, :winter or nil/'-' for any season
  # @param desc [String] the description text
  def set_seasonal_description!(time, season, desc)
    key = build_seasonal_key(time, season)
    descs = (seasonal_descriptions || {}).dup
    descs[key] = desc
    update(seasonal_descriptions: Sequel.pg_jsonb_wrap(descs))
  end

  # Clear a seasonal description
  # @param time [Symbol, String, nil] time of day or nil for any
  # @param season [Symbol, String, nil] season or nil for any
  def clear_seasonal_description!(time, season)
    key = build_seasonal_key(time, season)
    descs = (seasonal_descriptions || {}).dup
    descs.delete(key)
    update(seasonal_descriptions: Sequel.pg_jsonb_wrap(descs))
  end

  # List all set seasonal descriptions
  # @return [Hash] the seasonal_descriptions hash
  def list_seasonal_descriptions
    seasonal_descriptions || {}
  end

  # Resolve a description for a specific time/season combination
  # @param time [Symbol] :dawn, :day, :dusk, :night
  # @param season [Symbol] :spring, :summer, :fall, :winter (or climate-specific like :wet, :dry)
  # @param mapped_season [Symbol, nil] Optional mapped temperate season for fallback
  # @return [String, nil] the resolved description or nil
  def resolve_description(time, season, mapped_season: nil)
    resolve_seasonal_content(seasonal_descriptions, time, season, mapped_season: mapped_season) ||
      (respond_to?(:description) ? description : nil)
  end

  # Get description for current time and season using GameTimeService
  # Automatically handles climate-specific seasons with proper fallback
  # @param location [Location, nil] the location for time/season calculation
  # @return [String, nil] the resolved description
  def current_description(location = nil)
    time = GameTimeService.time_of_day(location)
    detail = GameTimeService.season_detail(location)

    resolve_description(
      time,
      detail[:raw_season],
      mapped_season: detail[:season]
    )
  end

  # ========================================
  # Seasonal Background Methods
  # ========================================

  # Set a seasonal background URL
  # @param time [Symbol, String, nil] :dawn, :day, :dusk, :night or nil/'-' for any time
  # @param season [Symbol, String, nil] :spring, :summer, :fall, :winter or nil/'-' for any season
  # @param url [String] the background URL
  def set_seasonal_background!(time, season, url)
    return unless respond_to?(:seasonal_backgrounds)

    key = build_seasonal_key(time, season)
    bgs = (seasonal_backgrounds || {}).dup
    bgs[key] = url
    update(seasonal_backgrounds: Sequel.pg_jsonb_wrap(bgs))
  end

  # Clear a seasonal background
  # @param time [Symbol, String, nil] time of day or nil for any
  # @param season [Symbol, String, nil] season or nil for any
  def clear_seasonal_background!(time, season)
    return unless respond_to?(:seasonal_backgrounds)

    key = build_seasonal_key(time, season)
    bgs = (seasonal_backgrounds || {}).dup
    bgs.delete(key)
    update(seasonal_backgrounds: Sequel.pg_jsonb_wrap(bgs))
  end

  # List all set seasonal backgrounds
  # @return [Hash] the seasonal_backgrounds hash
  def list_seasonal_backgrounds
    return {} unless respond_to?(:seasonal_backgrounds)

    seasonal_backgrounds || {}
  end

  # Resolve a background URL for a specific time/season combination
  # @param time [Symbol] :dawn, :day, :dusk, :night
  # @param season [Symbol] :spring, :summer, :fall, :winter (or climate-specific like :wet, :dry)
  # @param mapped_season [Symbol, nil] Optional mapped temperate season for fallback
  # @return [String, nil] the resolved background URL or nil
  def resolve_background(time, season, mapped_season: nil)
    return nil unless respond_to?(:seasonal_backgrounds)

    resolve_seasonal_content(seasonal_backgrounds, time, season, mapped_season: mapped_season) ||
      (respond_to?(:default_background_url) ? default_background_url : nil)
  end

  # Get background URL for current time and season using GameTimeService
  # Automatically handles climate-specific seasons with proper fallback
  # @param location [Location, nil] the location for time/season calculation
  # @return [String, nil] the resolved background URL
  def current_background(location = nil)
    return nil unless respond_to?(:seasonal_backgrounds)

    time = GameTimeService.time_of_day(location)
    detail = GameTimeService.season_detail(location)

    resolve_background(
      time,
      detail[:raw_season],
      mapped_season: detail[:season]
    )
  end

  private

  # (resolve_seasonal_content, build_seasonal_key, normalize_extended_season
  #  are provided by SeasonalContentCore)
end
