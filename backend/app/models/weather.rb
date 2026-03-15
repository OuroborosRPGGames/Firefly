# frozen_string_literal: true

# Weather tracks current weather conditions for locations.
# Supports internal simulation and real-world API sources.
class Weather < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :location
  many_to_one :zone

  CONDITIONS = %w[clear cloudy overcast rain storm snow fog wind hail
                  thunderstorm blizzard hurricane tornado heat_wave cold_snap].freeze
  INTENSITIES = %w[light moderate heavy severe].freeze
  WEATHER_SOURCES = %w[internal api].freeze

  # Maps grid weather conditions to Weather model conditions/intensities
  GRID_CONDITION_MAP = {
    'clear' => { condition: 'clear', intensity: 'moderate' },
    'partly_cloudy' => { condition: 'cloudy', intensity: 'light' },
    'cloudy' => { condition: 'cloudy', intensity: 'moderate' },
    'overcast' => { condition: 'overcast', intensity: 'moderate' },
    'light_rain' => { condition: 'rain', intensity: 'light' },
    'rain' => { condition: 'rain', intensity: 'moderate' },
    'heavy_rain' => { condition: 'rain', intensity: 'heavy' },
    'light_snow' => { condition: 'snow', intensity: 'light' },
    'snow' => { condition: 'snow', intensity: 'moderate' },
    'blizzard' => { condition: 'blizzard', intensity: 'severe' },
    'fog' => { condition: 'fog', intensity: 'moderate' },
    'thunderstorm' => { condition: 'thunderstorm', intensity: 'heavy' }
  }.freeze

  def validate
    super
    validates_presence [:condition]
    validates_includes CONDITIONS, :condition
    validates_includes INTENSITIES, :intensity if intensity
    validates_includes WEATHER_SOURCES, :weather_source if weather_source
  end

  def before_save
    super
    self.intensity ||= 'moderate'
    self.temperature_c ||= 20
    self.humidity ||= 50
    self.wind_speed_kph ||= 10
    self.weather_source ||= 'internal'
    self.updated_at ||= Time.now
  end

  def temperature_f
    (temperature_c * 9.0 / 5.0) + 32
  end

  def severe?
    %w[storm thunderstorm blizzard hurricane tornado].include?(condition) ||
      intensity == 'severe'
  end

  def outdoor_penalty?
    %w[rain storm snow blizzard thunderstorm hurricane].include?(condition)
  end

  def visibility_reduced?
    %w[fog storm blizzard].include?(condition) || intensity == 'severe'
  end

  def description
    intensity_desc = intensity == 'moderate' ? '' : "#{intensity} "
    "#{intensity_desc}#{condition.tr('_', ' ')}"
  end

  def summary
    "#{description.capitalize}, #{temperature_c}°C (#{temperature_f.round}°F)"
  end

  # Get or create weather for a location
  def self.for_location(location)
    first(location_id: location.id) || create_default_for(location)
  end

  def self.create_default_for(location)
    create(
      location_id: location.id,
      condition: 'clear',
      intensity: 'moderate',
      temperature_c: 20
    )
  end

  # Randomize weather (simple simulation - prefer simulate! for realism)
  def randomize!
    new_condition = CONDITIONS.sample
    new_intensity = INTENSITIES.sample
    new_temp = temperature_c + rand(-5..5)

    update(
      condition: new_condition,
      intensity: new_intensity,
      temperature_c: new_temp.clamp(-40, 50)
    )
  end

  # Simulate realistic weather based on climate, season, and location
  # Uses API for api_source, grid interpolation if world has grid weather,
  # or WeatherSimulatorService for internal fallback
  # @return [Weather] self after update
  def simulate!
    if api_source?
      refresh_from_api! if needs_api_refresh?
      return self
    end

    loc = location
    world = loc&.world

    if world&.grid_weather? && loc&.has_globe_hex?
      simulate_from_grid!(loc) || WeatherSimulatorService.simulate(self, location: loc, zone: zone)
    else
      WeatherSimulatorService.simulate(self, location: loc, zone: zone)
    end

    self
  end

  # Check if weather uses API source
  # @return [Boolean]
  def api_source?
    weather_source == 'api'
  end

  # Check if weather uses internal simulation
  # @return [Boolean]
  def internal_source?
    weather_source == 'internal' || weather_source.nil?
  end

  # Check if API refresh is needed
  # @return [Boolean]
  def needs_api_refresh?
    return false unless api_source?
    return true if last_api_fetch.nil?

    refresh_interval = (api_refresh_minutes || 15) * 60
    (Time.now - last_api_fetch) > refresh_interval
  end

  # Get wind speed in mph
  # @return [Float]
  def wind_speed_mph
    (wind_speed_kph || 0) * 0.621371
  end

  # Configure for API weather source
  # @param provider [String] API provider name
  # @param location_query [String] city name or "lat,lon"
  # @param refresh_minutes [Integer] refresh interval
  def configure_api!(provider:, location_query:, refresh_minutes: 15)
    update(
      weather_source: 'api',
      api_provider: provider,
      api_location_query: location_query,
      api_refresh_minutes: refresh_minutes,
      updated_at: Time.now
    )
  end

  # Configure for API weather with coordinates
  # @param provider [String] API provider name
  # @param latitude [Float] latitude
  # @param longitude [Float] longitude
  # @param refresh_minutes [Integer] refresh interval
  def configure_api_coordinates!(provider:, latitude:, longitude:, refresh_minutes: 15)
    update(
      weather_source: 'api',
      api_provider: provider,
      real_world_latitude: latitude,
      real_world_longitude: longitude,
      api_refresh_minutes: refresh_minutes,
      updated_at: Time.now
    )
  end

  # Switch to internal simulation
  def switch_to_internal!
    update(
      weather_source: 'internal',
      updated_at: Time.now
    )
  end

  # Fetch fresh data from the configured API
  # @return [Boolean] true if update successful
  def refresh_from_api!
    WeatherApiService.update_weather(self)
  end

  # Get a temperature description
  # @return [String]
  def temperature_description
    case temperature_c
    when ..-10 then 'bitterly cold'
    when -10..0 then 'freezing'
    when 0..10 then 'cold'
    when 10..15 then 'cool'
    when 15..20 then 'mild'
    when 20..25 then 'warm'
    when 25..30 then 'hot'
    when 30..35 then 'very hot'
    else 'scorching'
    end
  end

  # Is sky visible (not heavily overcast/stormy)?
  # @return [Boolean]
  def sky_visible?
    (cloud_cover || 0) < 90 && !visibility_reduced?
  end

  # Would stars be visible at night?
  # @return [Boolean]
  def stars_visible?
    (cloud_cover || 0) < 60 && !%w[fog storm blizzard rain snow].include?(condition)
  end

  private

  # Simulate weather from the grid interpolation system
  # @param loc [Location] The location to get grid weather for
  # @return [Boolean] true if successfully updated from grid, false to fall back
  def simulate_from_grid!(loc)
    snapshot = WeatherGrid::InterpolationService.weather_for_location(loc)
    return false unless snapshot

    grid_condition = snapshot['condition'].to_s
    mapped = map_grid_condition(grid_condition)

    update(
      condition: mapped[:condition],
      intensity: mapped[:intensity],
      temperature_c: snapshot['temperature']&.round,
      humidity: snapshot['humidity']&.round,
      wind_speed_kph: snapshot['wind_speed']&.round,
      cloud_cover: snapshot['cloud_cover']&.round,
      updated_at: Time.now
    )
    true
  rescue StandardError => e
    warn "[Weather] Grid interpolation failed for location #{loc&.id}: #{e.message}"
    false
  end

  # Map a grid weather condition string to Weather model condition/intensity
  # @param grid_condition [String] Grid condition (e.g., 'heavy_rain')
  # @return [Hash] { condition:, intensity: }
  def map_grid_condition(grid_condition)
    GRID_CONDITION_MAP[grid_condition] || { condition: grid_condition, intensity: 'moderate' }
  end
end
