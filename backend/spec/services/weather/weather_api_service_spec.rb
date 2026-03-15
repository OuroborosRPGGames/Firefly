# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WeatherApiService do
  describe 'constants' do
    it 'defines API_BASE_URL' do
      expect(described_class::API_BASE_URL).to eq('https://api.openweathermap.org/data/2.5/weather')
    end

    it 'defines CONDITION_MAP for weather conditions' do
      expect(described_class::CONDITION_MAP['Clear']).to eq('clear')
      expect(described_class::CONDITION_MAP['Rain']).to eq('rain')
      expect(described_class::CONDITION_MAP['Snow']).to eq('snow')
      expect(described_class::CONDITION_MAP['Thunderstorm']).to eq('thunderstorm')
    end

    it 'maps Mist, Fog, Haze, Smoke to fog' do
      %w[Mist Fog Haze Smoke].each do |condition|
        expect(described_class::CONDITION_MAP[condition]).to eq('fog')
      end
    end

    it 'maps Dust, Sand to wind' do
      %w[Dust Sand].each do |condition|
        expect(described_class::CONDITION_MAP[condition]).to eq('wind')
      end
    end
  end

  describe '.refine_cloud_condition' do
    it 'returns original condition if not cloudy' do
      expect(described_class.refine_cloud_condition('rain', 50)).to eq('rain')
      expect(described_class.refine_cloud_condition('clear', 80)).to eq('clear')
    end

    it 'returns clear for low cloud cover (0-20%)' do
      expect(described_class.refine_cloud_condition('cloudy', 0)).to eq('clear')
      expect(described_class.refine_cloud_condition('cloudy', 15)).to eq('clear')
      expect(described_class.refine_cloud_condition('cloudy', 20)).to eq('clear')
    end

    it 'returns cloudy for medium cloud cover (21-50%)' do
      expect(described_class.refine_cloud_condition('cloudy', 21)).to eq('cloudy')
      expect(described_class.refine_cloud_condition('cloudy', 35)).to eq('cloudy')
      expect(described_class.refine_cloud_condition('cloudy', 50)).to eq('cloudy')
    end

    it 'returns overcast for high cloud cover (51%+)' do
      expect(described_class.refine_cloud_condition('cloudy', 51)).to eq('overcast')
      expect(described_class.refine_cloud_condition('cloudy', 75)).to eq('overcast')
      expect(described_class.refine_cloud_condition('cloudy', 100)).to eq('overcast')
    end
  end

  describe '.wind_intensity' do
    it 'returns light for 0-15 kph' do
      expect(described_class.wind_intensity(0)).to eq('light')
      expect(described_class.wind_intensity(10)).to eq('light')
      expect(described_class.wind_intensity(15)).to eq('light')
    end

    it 'returns moderate for 16-30 kph' do
      expect(described_class.wind_intensity(16)).to eq('moderate')
      expect(described_class.wind_intensity(25)).to eq('moderate')
      expect(described_class.wind_intensity(30)).to eq('moderate')
    end

    it 'returns heavy for 31-50 kph' do
      expect(described_class.wind_intensity(31)).to eq('heavy')
      expect(described_class.wind_intensity(40)).to eq('heavy')
      expect(described_class.wind_intensity(50)).to eq('heavy')
    end

    it 'returns severe for 51+ kph' do
      expect(described_class.wind_intensity(51)).to eq('severe')
      expect(described_class.wind_intensity(100)).to eq('severe')
    end
  end

  describe '.fetch_by_query' do
    before do
      allow(GameSetting).to receive(:get).with('weather_api_key').and_return('test_api_key')
    end

    it 'returns error when API key is not configured' do
      allow(GameSetting).to receive(:get).with('weather_api_key').and_return(nil)

      result = described_class.fetch_by_query('London')

      expect(result[:error]).to eq('No API key configured')
    end

    it 'returns error when API key is empty' do
      allow(GameSetting).to receive(:get).with('weather_api_key').and_return('')

      result = described_class.fetch_by_query('London')

      expect(result[:error]).to eq('No API key configured')
    end

    it 'calls fetch_and_parse with correct URL' do
      expect(described_class).to receive(:fetch_and_parse).with(
        a_string_matching(%r{api\.openweathermap\.org.+q=London.+appid=test_api_key})
      )

      described_class.fetch_by_query('London')
    end

    it 'URL-encodes the query' do
      # URI.encode_www_form_component uses + for spaces (form encoding)
      expect(described_class).to receive(:fetch_and_parse).with(
        a_string_matching(/q=New\+York/)
      )

      described_class.fetch_by_query('New York')
    end
  end

  describe '.fetch_by_coordinates' do
    before do
      allow(GameSetting).to receive(:get).with('weather_api_key').and_return('test_api_key')
    end

    it 'returns error when API key is not configured' do
      allow(GameSetting).to receive(:get).with('weather_api_key').and_return(nil)

      result = described_class.fetch_by_coordinates(51.5074, -0.1278)

      expect(result[:error]).to eq('No API key configured')
    end

    it 'calls fetch_and_parse with correct URL including coordinates' do
      expect(described_class).to receive(:fetch_and_parse).with(
        a_string_matching(/lat=51\.5074.+lon=-0\.1278.+appid=test_api_key/)
      )

      described_class.fetch_by_coordinates(51.5074, -0.1278)
    end
  end

  describe '.fetch_and_parse' do
    let(:api_response) do
      {
        'cod' => 200,
        'weather' => [{ 'main' => 'Clear', 'description' => 'clear sky', 'icon' => '01d' }],
        'main' => { 'temp' => 293.15, 'feels_like' => 292.15, 'humidity' => 60 },
        'wind' => { 'speed' => 5.5 },
        'clouds' => { 'all' => 10 },
        'sys' => { 'sunrise' => 1609459200, 'sunset' => 1609491600 },
        'timezone' => 0
      }
    end

    before do
      response = double('Response', success?: true, body: api_response.to_json)
      allow(Faraday).to receive(:get).and_return(response)
    end

    it 'returns success when API call succeeds' do
      result = described_class.fetch_and_parse('http://example.com/weather')

      expect(result[:success]).to be true
    end

    it 'returns error when HTTP request fails' do
      response = double('Response', success?: false, status: 500)
      allow(Faraday).to receive(:get).and_return(response)

      result = described_class.fetch_and_parse('http://example.com/weather')

      expect(result[:error]).to include('API request failed: 500')
    end

    it 'handles Faraday network errors' do
      allow(Faraday).to receive(:get).and_raise(Faraday::ConnectionFailed, 'Connection refused')

      result = described_class.fetch_and_parse('http://example.com/weather')

      expect(result[:error]).to include('Network error')
    end

    it 'handles invalid JSON responses' do
      response = double('Response', success?: true, body: 'not json')
      allow(Faraday).to receive(:get).and_return(response)

      result = described_class.fetch_and_parse('http://example.com/weather')

      expect(result[:error]).to include('Invalid JSON response')
    end
  end

  describe '.parse_response' do
    let(:valid_response) do
      {
        'cod' => 200,
        'weather' => [{ 'main' => 'Clear', 'description' => 'clear sky', 'icon' => '01d' }],
        'main' => { 'temp' => 293.15, 'feels_like' => 292.15, 'humidity' => 60 },
        'wind' => { 'speed' => 5.5 },
        'clouds' => { 'all' => 10 },
        'sys' => { 'sunrise' => 1609459200, 'sunset' => 1609491600 },
        'timezone' => 3600
      }
    end

    it 'returns success with valid data' do
      result = described_class.parse_response(valid_response)

      expect(result[:success]).to be true
    end

    it 'converts temperature from Kelvin to Celsius' do
      result = described_class.parse_response(valid_response)

      # 292.15 K - 273.15 = 19.0 C (uses feels_like)
      expect(result[:temperature_c]).to eq(19.0)
    end

    it 'uses temp if feels_like not available' do
      response = valid_response.dup
      response['main'] = { 'temp' => 293.15, 'humidity' => 60 }

      result = described_class.parse_response(response)

      # 293.15 K - 273.15 = 20.0 C
      expect(result[:temperature_c]).to eq(20.0)
    end

    it 'converts wind speed from m/s to kph' do
      result = described_class.parse_response(valid_response)

      # 5.5 m/s * 3.6 = 19.8 kph
      expect(result[:wind_speed_kph]).to eq(19.8)
    end

    it 'maps weather condition' do
      result = described_class.parse_response(valid_response)

      expect(result[:condition]).to eq('clear')
    end

    it 'refines cloudy condition based on cloud cover' do
      response = valid_response.dup
      response['weather'] = [{ 'main' => 'Clouds' }]
      response['clouds'] = { 'all' => 80 }

      result = described_class.parse_response(response)

      expect(result[:condition]).to eq('overcast')
    end

    it 'includes humidity' do
      result = described_class.parse_response(valid_response)

      expect(result[:humidity]).to eq(60)
    end

    it 'includes cloud cover' do
      result = described_class.parse_response(valid_response)

      expect(result[:cloud_cover]).to eq(10)
    end

    it 'parses sunrise and sunset times' do
      result = described_class.parse_response(valid_response)

      expect(result[:sunrise]).to eq(Time.at(1609459200))
      expect(result[:sunset]).to eq(Time.at(1609491600))
    end

    it 'includes timezone offset' do
      result = described_class.parse_response(valid_response)

      expect(result[:timezone_offset]).to eq(3600)
    end

    it 'includes API description and icon' do
      result = described_class.parse_response(valid_response)

      expect(result[:api_description]).to eq('clear sky')
      expect(result[:api_icon]).to eq('01d')
    end

    it 'includes fetched_at timestamp' do
      result = described_class.parse_response(valid_response)

      expect(result[:fetched_at]).to be_within(1).of(Time.now)
    end

    it 'calculates wind intensity' do
      result = described_class.parse_response(valid_response)

      expect(result[:intensity]).to eq('moderate') # 19.8 kph is moderate
    end

    it 'returns error for API error response' do
      error_response = { 'cod' => 401, 'message' => 'Invalid API key' }

      result = described_class.parse_response(error_response)

      expect(result[:error]).to eq('Invalid API key')
    end

    it 'uses default values for missing data' do
      minimal_response = { 'cod' => 200 }

      result = described_class.parse_response(minimal_response)

      expect(result[:success]).to be true
      expect(result[:condition]).to eq('clear') # default when missing
      expect(result[:humidity]).to eq(50) # default
    end

    it 'defaults to cloudy for unknown conditions (refined based on cloud cover)' do
      response = valid_response.dup
      response['weather'] = [{ 'main' => 'UnknownCondition' }]
      # Set cloud cover high so it stays as 'overcast' after refinement
      response['clouds'] = { 'all' => 80 }

      result = described_class.parse_response(response)

      # Unknown maps to 'cloudy', then refined to 'overcast' at 80% cloud cover
      expect(result[:condition]).to eq('overcast')
    end
  end

  describe '.update_weather' do
    let(:weather) do
      double('Weather',
             id: 1,
             api_source?: true,
             real_world_latitude: 51.5074,
             real_world_longitude: -0.1278,
             api_location_query: nil)
    end

    before do
      allow(described_class).to receive(:fetch_by_coordinates).and_return({
        success: true,
        condition: 'clear',
        intensity: 'light',
        temperature_c: 20.0,
        humidity: 50,
        wind_speed_kph: 10.0,
        cloud_cover: 20
      })
      allow(weather).to receive(:update)
    end

    it 'returns false if weather is not API source' do
      non_api_weather = double('Weather', api_source?: false)

      result = described_class.update_weather(non_api_weather)

      expect(result).to be false
    end

    it 'fetches by coordinates when available' do
      expect(described_class).to receive(:fetch_by_coordinates).with(51.5074, -0.1278)

      described_class.update_weather(weather)
    end

    it 'fetches by query when coordinates not available' do
      weather_with_query = double('Weather',
                                  id: 2,
                                  api_source?: true,
                                  real_world_latitude: nil,
                                  real_world_longitude: nil,
                                  api_location_query: 'London,uk')

      allow(described_class).to receive(:fetch_by_query).and_return({ success: true, condition: 'rain' })
      allow(weather_with_query).to receive(:update)

      expect(described_class).to receive(:fetch_by_query).with('London,uk')

      described_class.update_weather(weather_with_query)
    end

    it 'returns error when no location configured' do
      weather_no_location = double('Weather',
                                   id: 3,
                                   api_source?: true,
                                   real_world_latitude: nil,
                                   real_world_longitude: nil,
                                   api_location_query: '')

      result = described_class.update_weather(weather_no_location)

      expect(result).to be false
    end

    it 'updates weather record on success' do
      expect(weather).to receive(:update).with(
        hash_including(
          condition: 'clear',
          intensity: 'light',
          temperature_c: 20.0
        )
      )

      described_class.update_weather(weather)
    end

    it 'returns true on success' do
      result = described_class.update_weather(weather)

      expect(result).to be true
    end

    it 'returns false on fetch failure' do
      allow(described_class).to receive(:fetch_by_coordinates).and_return({
        error: 'API error'
      })

      result = described_class.update_weather(weather)

      expect(result).to be false
    end
  end

  describe '.refresh_all_stale' do
    before do
      allow(GameSetting).to receive(:get).with('weather_api_key').and_return('test_key')
    end

    it 'returns 0 when API key not configured' do
      allow(GameSetting).to receive(:get).with('weather_api_key').and_return(nil)

      result = described_class.refresh_all_stale

      expect(result).to eq(0)
    end

    it 'queries weather records with api source' do
      expect(Weather).to receive(:where).with(weather_source: 'api').and_return([])

      described_class.refresh_all_stale
    end

    it 'updates stale weather records' do
      stale_weather = double('Weather', needs_api_refresh?: true)
      fresh_weather = double('Weather', needs_api_refresh?: false)

      allow(Weather).to receive(:where).and_return([stale_weather, fresh_weather])
      allow(described_class).to receive(:update_weather).and_return(true)
      allow(described_class).to receive(:sleep)

      expect(described_class).to receive(:update_weather).with(stale_weather)
      expect(described_class).not_to receive(:update_weather).with(fresh_weather)

      described_class.refresh_all_stale
    end

    it 'returns count of updated records' do
      weather1 = double('Weather', needs_api_refresh?: true)
      weather2 = double('Weather', needs_api_refresh?: true)

      allow(Weather).to receive(:where).and_return([weather1, weather2])
      allow(described_class).to receive(:update_weather).and_return(true)
      allow(described_class).to receive(:sleep)

      result = described_class.refresh_all_stale

      expect(result).to eq(2)
    end

    it 'rate limits API calls' do
      weather = double('Weather', needs_api_refresh?: true)

      allow(Weather).to receive(:where).and_return([weather])
      allow(described_class).to receive(:update_weather).and_return(true)

      expect(described_class).to receive(:sleep).with(1.1)

      described_class.refresh_all_stale
    end
  end

  describe '.test_connection' do
    before do
      allow(GameSetting).to receive(:get).with('weather_api_key').and_return('test_key')
    end

    it 'returns failure when API key not configured' do
      allow(GameSetting).to receive(:get).with('weather_api_key').and_return(nil)

      result = described_class.test_connection

      expect(result[:success]).to be false
      expect(result[:error]).to eq('No API key configured')
    end

    it 'tests with London as known location' do
      expect(described_class).to receive(:fetch_by_query).with('London,uk').and_return({
        success: true,
        condition: 'cloudy',
        temperature_c: 15.0,
        api_description: 'overcast clouds'
      })

      described_class.test_connection
    end

    it 'returns success with sample data' do
      allow(described_class).to receive(:fetch_by_query).and_return({
        success: true,
        condition: 'rain',
        temperature_c: 12.5,
        api_description: 'light rain'
      })

      result = described_class.test_connection

      expect(result[:success]).to be true
      expect(result[:message]).to eq('API connection successful')
      expect(result[:sample_data][:condition]).to eq('rain')
      expect(result[:sample_data][:temperature_c]).to eq(12.5)
    end

    it 'returns error on fetch failure' do
      allow(described_class).to receive(:fetch_by_query).and_return({
        error: 'Invalid API key'
      })

      result = described_class.test_connection

      expect(result[:success]).to be false
      expect(result[:error]).to eq('Invalid API key')
    end
  end
end
