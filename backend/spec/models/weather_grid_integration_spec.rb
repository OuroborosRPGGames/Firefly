# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Weather grid integration' do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:zone, world: world) }
  let(:location) { create(:location, zone: zone, world: world, globe_hex_id: 1) }
  let!(:world_hex) do
    create(:world_hex, world: world, globe_hex_id: 1,
                       latitude: 10.0, longitude: 20.0,
                       terrain_type: 'grassy_plains')
  end
  let!(:weather) do
    create(:weather, location: location, condition: 'clear',
                     weather_source: 'internal')
  end

  describe 'World#grid_weather?' do
    it 'returns true when use_grid_weather is true' do
      world.update(use_grid_weather: true)
      expect(world.grid_weather?).to be true
    end

    it 'returns false when use_grid_weather is false' do
      world.update(use_grid_weather: false)
      expect(world.grid_weather?).to be false
    end

    it 'returns false when use_grid_weather is nil' do
      expect(world.grid_weather?).to be false
    end
  end

  describe 'World#active_storms' do
    it 'returns empty array when grid weather is disabled' do
      world.update(use_grid_weather: false)
      expect(world.active_storms).to eq([])
    end

    it 'delegates to StormService when grid weather is enabled' do
      world.update(use_grid_weather: true)
      allow(WeatherGrid::StormService).to receive(:active_storms).with(world).and_return([{ 'id' => 'storm_1' }])

      expect(world.active_storms).to eq([{ 'id' => 'storm_1' }])
    end

    it 'returns empty array on error' do
      world.update(use_grid_weather: true)
      allow(WeatherGrid::StormService).to receive(:active_storms).and_raise(StandardError, 'test error')

      expect(world.active_storms).to eq([])
    end
  end

  describe 'World#weather_grid_meta' do
    it 'returns nil when grid weather is disabled' do
      world.update(use_grid_weather: false)
      expect(world.weather_grid_meta).to be_nil
    end

    it 'returns nil on error' do
      world.update(use_grid_weather: true)
      allow(WeatherGrid::GridService).to receive(:load).and_raise(StandardError, 'test error')

      expect(world.weather_grid_meta).to be_nil
    end
  end

  describe 'World#weather_world_state association' do
    it 'can access weather_world_state' do
      expect(world.weather_world_state).to be_nil
    end
  end

  describe 'Weather#simulate! with grid weather' do
    before { world.update(use_grid_weather: true) }

    it 'uses grid interpolation when world has grid weather enabled' do
      mock_snapshot = {
        'condition' => 'rain', 'temperature' => 15.3,
        'humidity' => 80.0, 'wind_speed' => 25.0,
        'cloud_cover' => 90.0, 'wind_dir' => 220, 'precip_rate' => 5.0,
        'pressure' => 1005.0, 'instability' => 40.0
      }
      allow(WeatherGrid::InterpolationService).to receive(:weather_for_location).and_return(mock_snapshot)

      weather.simulate!
      weather.refresh

      expect(weather.condition).to eq('rain')
      expect(weather.intensity).to eq('moderate')
      expect(weather.temperature_c).to eq(15)
      expect(weather.humidity).to eq(80)
      expect(weather.wind_speed_kph).to eq(25)
      expect(weather.cloud_cover).to eq(90)
    end

    it 'falls back to legacy simulator when grid returns nil' do
      allow(WeatherGrid::InterpolationService).to receive(:weather_for_location).and_return(nil)
      allow(WeatherSimulatorService).to receive(:simulate)

      weather.simulate!

      expect(WeatherSimulatorService).to have_received(:simulate)
    end

    it 'falls back to legacy simulator when grid interpolation raises an error' do
      allow(WeatherGrid::InterpolationService).to receive(:weather_for_location).and_raise(StandardError, 'grid error')
      allow(WeatherSimulatorService).to receive(:simulate)

      weather.simulate!

      expect(WeatherSimulatorService).to have_received(:simulate)
    end

    it 'uses legacy simulator when world does not have grid weather' do
      world.update(use_grid_weather: false)
      allow(WeatherSimulatorService).to receive(:simulate)

      weather.simulate!

      expect(WeatherSimulatorService).to have_received(:simulate)
    end

    it 'uses legacy simulator when location has no globe_hex_id' do
      location.update(globe_hex_id: nil)
      allow(WeatherSimulatorService).to receive(:simulate)

      weather.simulate!

      expect(WeatherSimulatorService).to have_received(:simulate)
    end
  end

  describe 'Weather#map_grid_condition' do
    it 'maps grid conditions to Weather model conditions' do
      expect(weather.send(:map_grid_condition, 'heavy_rain')).to eq({ condition: 'rain', intensity: 'heavy' })
      expect(weather.send(:map_grid_condition, 'thunderstorm')).to eq({ condition: 'thunderstorm', intensity: 'heavy' })
      expect(weather.send(:map_grid_condition, 'clear')).to eq({ condition: 'clear', intensity: 'moderate' })
    end

    it 'maps snow conditions correctly' do
      expect(weather.send(:map_grid_condition, 'light_snow')).to eq({ condition: 'snow', intensity: 'light' })
      expect(weather.send(:map_grid_condition, 'snow')).to eq({ condition: 'snow', intensity: 'moderate' })
      expect(weather.send(:map_grid_condition, 'blizzard')).to eq({ condition: 'blizzard', intensity: 'severe' })
    end

    it 'maps cloud conditions correctly' do
      expect(weather.send(:map_grid_condition, 'partly_cloudy')).to eq({ condition: 'cloudy', intensity: 'light' })
      expect(weather.send(:map_grid_condition, 'cloudy')).to eq({ condition: 'cloudy', intensity: 'moderate' })
      expect(weather.send(:map_grid_condition, 'overcast')).to eq({ condition: 'overcast', intensity: 'moderate' })
    end

    it 'returns default for unknown conditions' do
      result = weather.send(:map_grid_condition, 'alien_weather')
      expect(result[:condition]).to eq('alien_weather')
      expect(result[:intensity]).to eq('moderate')
    end
  end

  describe 'Weather::GRID_CONDITION_MAP' do
    it 'contains expected condition mappings' do
      expect(Weather::GRID_CONDITION_MAP).to be_a(Hash)
      expect(Weather::GRID_CONDITION_MAP).to be_frozen
      expect(Weather::GRID_CONDITION_MAP.keys).to include('clear', 'rain', 'heavy_rain', 'thunderstorm', 'fog')
    end

    it 'maps all conditions to valid Weather model conditions' do
      Weather::GRID_CONDITION_MAP.each do |grid_cond, mapped|
        expect(Weather::CONDITIONS).to include(mapped[:condition]),
          "Grid condition '#{grid_cond}' maps to '#{mapped[:condition]}' which is not in Weather::CONDITIONS"
        expect(Weather::INTENSITIES).to include(mapped[:intensity]),
          "Grid condition '#{grid_cond}' maps to intensity '#{mapped[:intensity]}' which is not in Weather::INTENSITIES"
      end
    end
  end
end
