# frozen_string_literal: true

# Fetches weather data from OpenWeatherMap API and updates Weather records.
# Supports both city name and coordinate-based queries.
class WeatherApiService
  API_BASE_URL = 'https://api.openweathermap.org/data/2.5/weather'

  # Map OpenWeatherMap main conditions to our internal conditions
  CONDITION_MAP = {
    'Clear' => 'clear',
    'Clouds' => 'cloudy',
    'Overcast' => 'overcast',
    'Rain' => 'rain',
    'Drizzle' => 'rain',
    'Thunderstorm' => 'thunderstorm',
    'Snow' => 'snow',
    'Mist' => 'fog',
    'Fog' => 'fog',
    'Haze' => 'fog',
    'Smoke' => 'fog',
    'Dust' => 'wind',
    'Sand' => 'wind',
    'Squall' => 'storm',
    'Tornado' => 'tornado'
  }.freeze

  # Map cloud cover percentage to condition refinement
  def self.refine_cloud_condition(main_condition, cloud_cover)
    return main_condition unless main_condition == 'cloudy'

    case cloud_cover
    when 0..20 then 'clear'
    when 21..50 then 'cloudy'
    else 'overcast'
    end
  end

  # Map wind speed to intensity
  def self.wind_intensity(wind_speed_kph)
    case wind_speed_kph
    when 0..15 then 'light'
    when 16..30 then 'moderate'
    when 31..50 then 'heavy'
    else 'severe'
    end
  end

  # Fetch weather for a location query (city name)
  # @param query [String] city name (e.g., "London,uk" or "New York,us")
  # @return [Hash, nil] weather data or nil on failure
  def self.fetch_by_query(query)
    api_key = GameSetting.get('weather_api_key')
    return { error: 'No API key configured' } if api_key.nil? || api_key.empty?

    url = "#{API_BASE_URL}?q=#{URI.encode_www_form_component(query)}&appid=#{api_key}"
    fetch_and_parse(url)
  end

  # Fetch weather for coordinates
  # @param latitude [Float] latitude
  # @param longitude [Float] longitude
  # @return [Hash, nil] weather data or nil on failure
  def self.fetch_by_coordinates(latitude, longitude)
    api_key = GameSetting.get('weather_api_key')
    return { error: 'No API key configured' } if api_key.nil? || api_key.empty?

    url = "#{API_BASE_URL}?lat=#{latitude}&lon=#{longitude}&appid=#{api_key}"
    fetch_and_parse(url)
  end

  # Fetch and parse weather data from the API
  # @param url [String] full API URL
  # @return [Hash] parsed weather data with our field names
  def self.fetch_and_parse(url)
    response = Faraday.get(url)

    unless response.success?
      return { error: "API request failed: #{response.status}" }
    end

    data = JSON.parse(response.body)
    parse_response(data)
  rescue Faraday::Error => e
    { error: "Network error: #{e.message}" }
  rescue JSON::ParserError => e
    { error: "Invalid JSON response: #{e.message}" }
  end

  # Parse OpenWeatherMap response into our format
  # @param data [Hash] raw API response
  # @return [Hash] parsed weather data
  def self.parse_response(data)
    return { error: data['message'] || 'Unknown API error' } if data['cod'] && data['cod'].to_i != 200

    main_condition = data.dig('weather', 0, 'main') || 'Clear'
    cloud_cover = data.dig('clouds', 'all') || 0

    # Convert Kelvin to Celsius
    temp_kelvin = data.dig('main', 'feels_like') || data.dig('main', 'temp') || 293
    temp_c = (temp_kelvin - 273.15).round(1)

    # Wind speed is in m/s, convert to kph
    wind_speed_ms = data.dig('wind', 'speed') || 0
    wind_speed_kph = (wind_speed_ms * 3.6).round(1)

    # Map to our condition
    condition = CONDITION_MAP[main_condition] || 'cloudy'
    condition = refine_cloud_condition(condition, cloud_cover)

    {
      success: true,
      condition: condition,
      intensity: wind_intensity(wind_speed_kph),
      temperature_c: temp_c,
      humidity: data.dig('main', 'humidity') || 50,
      wind_speed_kph: wind_speed_kph,
      cloud_cover: cloud_cover,
      sunrise: data.dig('sys', 'sunrise') ? Time.at(data.dig('sys', 'sunrise')) : nil,
      sunset: data.dig('sys', 'sunset') ? Time.at(data.dig('sys', 'sunset')) : nil,
      timezone_offset: data['timezone'] || 0,
      api_description: data.dig('weather', 0, 'description'),
      api_icon: data.dig('weather', 0, 'icon'),
      fetched_at: Time.now
    }
  end

  # Update a Weather record with fresh API data
  # @param weather [Weather] the weather record to update
  # @return [Boolean] true if updated successfully
  def self.update_weather(weather)
    return false unless weather.api_source?

    # Fetch based on configured method
    result = if weather.real_world_latitude && weather.real_world_longitude
               fetch_by_coordinates(weather.real_world_latitude, weather.real_world_longitude)
             elsif weather.api_location_query && !weather.api_location_query.empty?
               fetch_by_query(weather.api_location_query)
             else
               { error: 'No location configured for API fetch' }
             end

    if result[:success]
      weather.update(
        condition: result[:condition],
        intensity: result[:intensity],
        temperature_c: result[:temperature_c],
        humidity: result[:humidity],
        wind_speed_kph: result[:wind_speed_kph],
        cloud_cover: result[:cloud_cover],
        last_api_fetch: Time.now,
        updated_at: Time.now
      )
      true
    else
      warn "[WeatherApiService] Failed to update weather ##{weather.id}: #{result[:error]}"
      false
    end
  end

  # Refresh all weather records that need API updates
  # @return [Integer] number of records updated
  def self.refresh_all_stale
    api_key = GameSetting.get('weather_api_key')
    return 0 if api_key.nil? || api_key.empty?

    updated_count = 0

    Weather.where(weather_source: 'api').each do |weather|
      next unless weather.needs_api_refresh?

      if update_weather(weather)
        updated_count += 1
      end

      # Rate limit: OpenWeatherMap free tier is 60 calls/minute
      sleep(1.1) if updated_count > 0
    end

    updated_count
  end

  # Test the API connection with current configuration
  # @return [Hash] status information
  def self.test_connection
    api_key = GameSetting.get('weather_api_key')
    return { success: false, error: 'No API key configured' } if api_key.nil? || api_key.empty?

    # Test with London as a known location
    result = fetch_by_query('London,uk')

    if result[:success]
      {
        success: true,
        message: "API connection successful",
        sample_data: {
          condition: result[:condition],
          temperature_c: result[:temperature_c],
          description: result[:api_description]
        }
      }
    else
      { success: false, error: result[:error] }
    end
  end
end
