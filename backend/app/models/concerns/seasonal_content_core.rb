# frozen_string_literal: true

# Shared private helpers for seasonal key building and content resolution.
#
# Used by Location, Zone, and the SeasonalContent concern to avoid duplicate
# implementations of the same fallback logic.
#
# Include this module in the private section of any model that needs to
# resolve seasonal content from a JSONB hash.
module SeasonalContentCore
  private

  # Resolve content from a seasonal JSONB hash with climate-aware fallback.
  # @param jsonb_hash [Hash, nil] the JSONB data
  # @param time [Symbol] :dawn, :day, :dusk, :night
  # @param season [Symbol] :spring, :summer, :fall, :winter (or climate-specific like :wet, :dry)
  # @param mapped_season [Symbol, nil] Optional mapped temperate season for additional fallback
  # @return [String, nil]
  #
  # Fallback chain (non-temperate locations with mapped_season set):
  #   1. "dawn_wet"    (climate-specific time+season)
  #   2. "dawn_summer" (mapped temperate time+season)
  #   3. "dawn"        (time-only)
  #   4. "wet"         (raw season)
  #   5. "summer"      (mapped temperate season)
  #   6. "default"
  def resolve_seasonal_content(jsonb_hash, time, season, mapped_season: nil)
    return nil if jsonb_hash.nil? || jsonb_hash.empty?

    result = jsonb_hash["#{time}_#{season}"]
    return result if result

    if mapped_season && mapped_season != season
      result = jsonb_hash["#{time}_#{mapped_season}"]
      return result if result
    end

    result = jsonb_hash[time.to_s]
    return result if result

    result = jsonb_hash[season.to_s]
    return result if result

    if mapped_season && mapped_season != season
      result = jsonb_hash[mapped_season.to_s]
      return result if result
    end

    jsonb_hash['default']
  end

  # Build a storage key for seasonal content.
  # @param time [Symbol, String, nil] time of day or nil/'-' for any
  # @param season [Symbol, String, nil] season or nil/'-' for any (including extended seasons)
  # @return [String] e.g. "dawn_spring", "dawn", "spring", or "default"
  def build_seasonal_key(time, season)
    norm_time = GameTimeService.normalize_time_name(time)
    norm_season = normalize_extended_season(season)

    if norm_time && norm_season
      "#{norm_time}_#{norm_season}"
    elsif norm_time
      norm_time.to_s
    elsif norm_season
      norm_season.to_s
    else
      'default'
    end
  end

  # Normalize a season name, including climate-specific seasons.
  # @param name [Symbol, String, nil] season name
  # @return [Symbol, nil] normalized season symbol
  def normalize_extended_season(name)
    return nil if StringHelper.blank?(name) || name.to_s == '-'

    sym = name.to_s.downcase.strip.to_sym
    return sym if GameTimeService::SEASONS.include?(sym)
    return sym if GameTimeService::EXTENDED_SEASONS.include?(sym)

    nil
  end
end
