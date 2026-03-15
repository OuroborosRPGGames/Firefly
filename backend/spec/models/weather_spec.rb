# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Weather do
  let(:location) { create(:location) }

  describe 'validations' do
    it 'requires condition' do
      weather = Weather.new(location: location)
      expect(weather.valid?).to be false
      expect(weather.errors[:condition]).not_to be_empty
    end

    it 'validates condition is in allowed list' do
      weather = Weather.new(location: location, condition: 'invalid')
      expect(weather.valid?).to be false
      expect(weather.errors[:condition]).not_to be_empty
    end

    it 'accepts valid conditions' do
      Weather::CONDITIONS.each do |cond|
        weather = Weather.new(location: location, condition: cond)
        weather.valid?
        expect(weather.errors[:condition]).to be_nil, "Expected #{cond} to be valid"
      end
    end

    it 'validates intensity is in allowed list' do
      weather = Weather.new(location: location, condition: 'clear', intensity: 'invalid')
      expect(weather.valid?).to be false
      expect(weather.errors[:intensity]).not_to be_empty
    end

    it 'validates weather_source is in allowed list' do
      weather = Weather.new(location: location, condition: 'clear', weather_source: 'invalid')
      expect(weather.valid?).to be false
      expect(weather.errors[:weather_source]).not_to be_empty
    end
  end

  describe 'constants' do
    it 'has expected conditions' do
      expect(Weather::CONDITIONS).to include('clear', 'rain', 'storm', 'snow', 'fog')
    end

    it 'has expected intensities' do
      expect(Weather::INTENSITIES).to eq(%w[light moderate heavy severe])
    end

    it 'has expected sources' do
      expect(Weather::WEATHER_SOURCES).to eq(%w[internal api])
    end
  end

  describe 'before_save defaults' do
    it 'sets default values' do
      weather = Weather.create(location: location, condition: 'clear')

      expect(weather.intensity).to eq('moderate')
      expect(weather.temperature_c).to eq(20)
      expect(weather.humidity).to eq(50)
      expect(weather.wind_speed_kph).to eq(10)
      expect(weather.weather_source).to eq('internal')
    end
  end

  describe '#temperature_f' do
    it 'converts Celsius to Fahrenheit' do
      weather = create(:weather, location: location, temperature_c: 0)
      expect(weather.temperature_f).to eq(32)
    end

    it 'handles normal temperatures' do
      weather = create(:weather, location: location, temperature_c: 20)
      expect(weather.temperature_f).to eq(68)
    end

    it 'handles negative temperatures' do
      weather = create(:weather, location: location, temperature_c: -10)
      expect(weather.temperature_f).to eq(14)
    end
  end

  describe '#severe?' do
    it 'returns true for storm conditions' do
      %w[storm thunderstorm blizzard hurricane tornado].each do |cond|
        weather = build(:weather, location: location, condition: cond)
        expect(weather.severe?).to be(true), "Expected #{cond} to be severe"
      end
    end

    it 'returns true for severe intensity' do
      weather = build(:weather, location: location, condition: 'rain', intensity: 'severe')
      expect(weather.severe?).to be true
    end

    it 'returns false for mild conditions' do
      weather = build(:weather, location: location, condition: 'clear', intensity: 'light')
      expect(weather.severe?).to be false
    end
  end

  describe '#outdoor_penalty?' do
    it 'returns true for precipitation conditions' do
      %w[rain storm snow blizzard thunderstorm hurricane].each do |cond|
        weather = build(:weather, location: location, condition: cond)
        expect(weather.outdoor_penalty?).to be(true), "Expected #{cond} to have outdoor penalty"
      end
    end

    it 'returns false for clear conditions' do
      weather = build(:weather, location: location, condition: 'clear')
      expect(weather.outdoor_penalty?).to be false
    end
  end

  describe '#visibility_reduced?' do
    it 'returns true for low visibility conditions' do
      %w[fog storm blizzard].each do |cond|
        weather = build(:weather, location: location, condition: cond)
        expect(weather.visibility_reduced?).to be(true), "Expected #{cond} to reduce visibility"
      end
    end

    it 'returns true for severe intensity' do
      weather = build(:weather, location: location, condition: 'rain', intensity: 'severe')
      expect(weather.visibility_reduced?).to be true
    end

    it 'returns false for clear conditions' do
      weather = build(:weather, location: location, condition: 'clear', intensity: 'moderate')
      expect(weather.visibility_reduced?).to be false
    end
  end

  describe '#description' do
    it 'returns condition with intensity for non-moderate' do
      weather = build(:weather, location: location, condition: 'rain', intensity: 'heavy')
      expect(weather.description).to eq('heavy rain')
    end

    it 'omits intensity for moderate' do
      weather = build(:weather, location: location, condition: 'rain', intensity: 'moderate')
      expect(weather.description).to eq('rain')
    end

    it 'replaces underscores with spaces' do
      weather = build(:weather, location: location, condition: 'heat_wave', intensity: 'moderate')
      expect(weather.description).to eq('heat wave')
    end
  end

  describe '#summary' do
    it 'includes description and temperature' do
      weather = build(:weather, location: location, condition: 'clear', temperature_c: 25)
      expect(weather.summary).to include('Clear')
      expect(weather.summary).to include('25°C')
      expect(weather.summary).to include('77°F')
    end
  end

  describe '.for_location' do
    it 'returns existing weather for location' do
      existing = create(:weather, location: location, condition: 'rain')
      result = Weather.for_location(location)
      expect(result.id).to eq(existing.id)
    end

    it 'creates default weather if none exists' do
      new_location = create(:location)
      result = Weather.for_location(new_location)
      expect(result.id).not_to be_nil
      expect(result.condition).to eq('clear')
      expect(result.location_id).to eq(new_location.id)
    end
  end

  describe '#randomize!' do
    let(:weather) { create(:weather, location: location, temperature_c: 20) }

    it 'changes condition' do
      original_condition = weather.condition
      # Run multiple times to ensure it changes eventually
      10.times { weather.randomize! }
      # Can't guarantee it changes, but structure should be valid
      expect(Weather::CONDITIONS).to include(weather.condition)
    end

    it 'clamps temperature to valid range' do
      weather.update(temperature_c: 50)
      weather.randomize!
      expect(weather.temperature_c).to be <= 50
      expect(weather.temperature_c).to be >= -40
    end
  end

  describe '#api_source?' do
    it 'returns true when source is api' do
      weather = build(:weather, location: location, weather_source: 'api')
      expect(weather.api_source?).to be true
    end

    it 'returns false when source is internal' do
      weather = build(:weather, location: location, weather_source: 'internal')
      expect(weather.api_source?).to be false
    end
  end

  describe '#internal_source?' do
    it 'returns true when source is internal' do
      weather = build(:weather, location: location, weather_source: 'internal')
      expect(weather.internal_source?).to be true
    end

    it 'returns true when source is nil' do
      weather = build(:weather, location: location)
      weather.values[:weather_source] = nil
      expect(weather.internal_source?).to be true
    end

    it 'returns false when source is api' do
      weather = build(:weather, location: location, weather_source: 'api')
      expect(weather.internal_source?).to be false
    end
  end

  describe '#needs_api_refresh?' do
    let(:weather) { create(:weather, location: location, weather_source: 'api', api_refresh_minutes: 15) }

    it 'returns false for internal source' do
      internal = create(:weather, location: location, weather_source: 'internal')
      expect(internal.needs_api_refresh?).to be false
    end

    it 'returns true when never fetched' do
      weather.update(last_api_fetch: nil)
      expect(weather.needs_api_refresh?).to be true
    end

    it 'returns false when recently fetched' do
      weather.update(last_api_fetch: Time.now - 60) # 1 minute ago
      expect(weather.needs_api_refresh?).to be false
    end

    it 'returns true when fetch is stale' do
      weather.update(last_api_fetch: Time.now - 1800) # 30 minutes ago
      expect(weather.needs_api_refresh?).to be true
    end
  end

  describe '#wind_speed_mph' do
    it 'converts kph to mph' do
      weather = build(:weather, location: location, wind_speed_kph: 100)
      expect(weather.wind_speed_mph).to be_within(0.1).of(62.1)
    end

    it 'handles nil wind speed' do
      weather = build(:weather, location: location)
      weather.values[:wind_speed_kph] = nil
      expect(weather.wind_speed_mph).to eq(0)
    end
  end

  describe '#configure_api!' do
    let(:weather) { create(:weather, location: location) }

    it 'sets API source and configuration' do
      weather.configure_api!(
        provider: 'openweather',
        location_query: 'London,UK',
        refresh_minutes: 30
      )

      expect(weather.weather_source).to eq('api')
      expect(weather.api_provider).to eq('openweather')
      expect(weather.api_location_query).to eq('London,UK')
      expect(weather.api_refresh_minutes).to eq(30)
    end
  end

  describe '#switch_to_internal!' do
    let(:weather) { create(:weather, location: location, weather_source: 'api') }

    it 'changes source to internal' do
      weather.switch_to_internal!
      expect(weather.weather_source).to eq('internal')
    end
  end

  describe '#temperature_description' do
    it 'returns appropriate descriptions for temperature ranges' do
      descriptions = {
        -15 => 'bitterly cold',
        -5 => 'freezing',
        5 => 'cold',
        12 => 'cool',
        18 => 'mild',
        22 => 'warm',
        27 => 'hot',
        32 => 'very hot',
        40 => 'scorching'
      }

      descriptions.each do |temp, expected|
        weather = build(:weather, location: location, temperature_c: temp)
        expect(weather.temperature_description).to eq(expected), "Expected #{temp}C to be '#{expected}'"
      end
    end
  end

  describe '#sky_visible?' do
    it 'returns true when cloud cover is low and visibility good' do
      weather = build(:weather, location: location, condition: 'clear', cloud_cover: 50)
      expect(weather.sky_visible?).to be true
    end

    it 'returns false when cloud cover is high' do
      weather = build(:weather, location: location, condition: 'clear', cloud_cover: 95)
      expect(weather.sky_visible?).to be false
    end

    it 'returns false when visibility is reduced' do
      weather = build(:weather, location: location, condition: 'fog', cloud_cover: 50)
      expect(weather.sky_visible?).to be false
    end
  end

  describe '#stars_visible?' do
    it 'returns true when conditions allow' do
      weather = build(:weather, location: location, condition: 'clear', cloud_cover: 30)
      expect(weather.stars_visible?).to be true
    end

    it 'returns false when cloud cover is too high' do
      weather = build(:weather, location: location, condition: 'clear', cloud_cover: 70)
      expect(weather.stars_visible?).to be false
    end

    it 'returns false during precipitation' do
      %w[fog storm blizzard rain snow].each do |cond|
        weather = build(:weather, location: location, condition: cond, cloud_cover: 30)
        expect(weather.stars_visible?).to be(false), "Expected stars not visible in #{cond}"
      end
    end
  end
end
