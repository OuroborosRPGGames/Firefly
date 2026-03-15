# frozen_string_literal: true

# WeatherProseCache stores AI-generated weather prose descriptions.
# Caches are keyed by location + weather context and expire after 45 minutes.
class WeatherProseCache < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :location
  many_to_one :zone

  CACHE_DURATION_MINUTES = 45

  def validate
    super
    validates_presence [:prose_text, :condition, :expires_at]
  end

  # Check if cache entry has expired
  # @return [Boolean]
  def expired?
    return true if expires_at.nil?

    expires_at < Time.now
  end

  # Check if cache entry is still valid (not expired)
  # Note: Named cache_valid? to avoid overriding Sequel's valid? validation method
  # @return [Boolean]
  def cache_valid?
    !expired?
  end

  # Time remaining until expiration
  # @return [Integer] seconds until expiration (0 if expired)
  def seconds_until_expiry
    remaining = (expires_at - Time.now).to_i
    remaining.positive? ? remaining : 0
  end

  class << self
    # Find cached prose for a location with matching context
    # @param location [Location] the location
    # @param condition [String] weather condition
    # @param intensity [String] weather intensity
    # @param time_of_day [Symbol, String] dawn/day/dusk/night
    # @param moon_phase [String] moon phase name
    # @return [WeatherProseCache, nil]
    def find_valid(location:, condition:, intensity: nil, time_of_day: nil, moon_phase: nil)
      where(location_id: location.id)
        .where(condition: condition)
        .where { expires_at > Time.now }
        .where(intensity: intensity)
        .where(time_of_day: time_of_day.to_s)
        .where(moon_phase: moon_phase)
        .first
    end

    # Cache prose for a location
    # @param location [Location] the location
    # @param prose [String] the prose text
    # @param context [Hash] weather context (condition, intensity, time_of_day, moon_phase, temperature_c)
    # @return [WeatherProseCache]
    def cache_for(location:, prose:, context:)
      # Remove old cache entries for this location
      where(location_id: location.id).delete

      create(
        location_id: location.id,
        zone_id: location.zone_id,
        prose_text: prose,
        condition: context[:condition],
        intensity: context[:intensity],
        time_of_day: context[:time_of_day].to_s,
        moon_phase: context[:moon_phase],
        temperature_c: context[:temperature_c],
        expires_at: Time.now + (CACHE_DURATION_MINUTES * 60),
        created_at: Time.now,
        updated_at: Time.now
      )
    end

    # Clear all expired cache entries
    # @return [Integer] number of entries deleted
    def clear_expired!
      where { expires_at < Time.now }.delete
    end

    # Clear all cache entries for a location
    # @param location [Location] the location
    # @return [Integer] number of entries deleted
    def clear_for_location!(location)
      where(location_id: location.id).delete
    end
  end
end
