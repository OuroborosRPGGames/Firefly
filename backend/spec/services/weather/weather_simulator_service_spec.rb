# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WeatherSimulatorService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) do
    create(:area,
           world: world,
           min_latitude: 40.0,
           max_latitude: 50.0,
           min_longitude: -80.0,
           max_longitude: -70.0)
  end
  let(:location) { create(:location, zone: area) }
  let(:weather) do
    create(:weather,
           location: location,
           condition: 'clear',
           intensity: 'moderate',
           temperature_c: 20,
           humidity: 50,
           wind_speed_kph: 10,
           cloud_cover: 30,
           weather_source: 'internal')
  end

  describe '.simulate' do
    it 'updates weather condition' do
      expect { described_class.simulate(weather, location: location, zone: area) }
        .to change { weather.reload; weather.updated_at }
    end

    it 'keeps temperature within reasonable bounds' do
      10.times { described_class.simulate(weather, location: location, zone: area) }
      expect(weather.temperature_c).to be_between(-60, 60)
    end

    it 'keeps humidity within bounds' do
      10.times { described_class.simulate(weather, location: location, zone: area) }
      expect(weather.humidity).to be_between(10, 100)
    end

    it 'uses area climate for calculations' do
      # Set area to tropical latitude
      area.update(min_latitude: 0.0, max_latitude: 10.0)
      expect(area.climate).to eq('tropical')

      5.times { described_class.simulate(weather, location: location, zone: area) }
      # Tropical areas have higher base temperature
      expect(weather.temperature_c).to be > 10
    end

    context 'with world-level settings' do
      before do
        # Use raw SQL to set columns that may not have Sequel accessors yet
        DB[:worlds].where(id: world.id).update(
          base_temperature_offset: 10,
          storm_frequency_multiplier: 2.0,
          precipitation_multiplier: 1.5,
          weather_variability: 1.0
        )
        world.refresh
      end

      it 'applies global temperature offset' do
        described_class.simulate(weather, location: location, zone: area)
        # Temperature should trend higher due to offset
        expect(weather.temperature_c).to be >= 15
      end
    end

    context 'with area-level modifiers' do
      before do
        # Use raw SQL to set columns that may not have Sequel accessors yet
        DB[:zones].where(id: area.id).update(
          temperature_modifier: -15,
          humidity_modifier: 20,
          precipitation_modifier: 50
        )
        area.refresh
      end

      it 'applies area temperature modifier' do
        10.times { described_class.simulate(weather, location: location, zone: area) }
        # Temperature should be lower due to modifier
        expect(weather.temperature_c).to be < 25
      end

      it 'applies area humidity modifier' do
        10.times { described_class.simulate(weather, location: location, zone: area) }
        # Humidity should be higher due to modifier
        expect(weather.humidity).to be >= 40
      end
    end

    context 'without location or area' do
      it 'uses temperate defaults' do
        bare_weather = create(:weather, condition: 'clear', temperature_c: 20)
        expect { described_class.simulate(bare_weather) }.not_to raise_error
        expect(Weather::CONDITIONS).to include(bare_weather.condition)
      end
    end
  end

  describe 'climate zones' do
    # Clear polygon_points so climate calculation uses geographic bounds instead
    before do
      area.update(polygon_points: [])
    end

    it 'calculates tropical for equatorial latitudes' do
      area.update(min_latitude: 0.0, max_latitude: 20.0)
      expect(area.climate).to eq('tropical')
    end

    it 'calculates subtropical for sub-tropic latitudes' do
      area.update(min_latitude: 25.0, max_latitude: 33.0)
      expect(area.climate).to eq('subtropical')
    end

    it 'calculates temperate for mid-latitudes' do
      area.update(min_latitude: 40.0, max_latitude: 50.0)
      expect(area.climate).to eq('temperate')
    end

    it 'calculates subarctic for high latitudes' do
      area.update(min_latitude: 58.0, max_latitude: 65.0)
      expect(area.climate).to eq('subarctic')
    end

    it 'calculates arctic for polar latitudes' do
      area.update(min_latitude: 70.0, max_latitude: 80.0)
      expect(area.climate).to eq('arctic')
    end

    it 'respects climate_override' do
      DB[:zones].where(id: area.id).update(climate_override: 'arctic')
      area.refresh
      expect(area.climate).to eq('arctic')
    end
  end

  describe 'weather transitions' do
    it 'changes temperature gradually' do
      initial_temp = weather.temperature_c
      described_class.simulate(weather, location: location, zone: area)
      # Max change is ~2-3 degrees per tick
      expect((weather.temperature_c - initial_temp).abs).to be <= 10
    end

    it 'preserves valid conditions' do
      5.times { described_class.simulate(weather, location: location, zone: area) }
      expect(Weather::CONDITIONS).to include(weather.condition)
    end

    it 'preserves valid intensities' do
      5.times { described_class.simulate(weather, location: location, zone: area) }
      expect(Weather::INTENSITIES).to include(weather.intensity)
    end
  end

  describe 'seasonal bias' do
    it 'produces appropriate winter conditions' do
      # Mock winter season
      allow(GameTimeService).to receive(:season).and_return(:winter)
      area.update(min_latitude: 60.0, max_latitude: 70.0) # Subarctic

      conditions = []
      20.times do
        described_class.simulate(weather, location: location, zone: area)
        conditions << weather.condition
      end

      # Should have some cold-weather conditions
      cold_conditions = conditions & %w[snow blizzard clear cloudy fog cold_snap]
      expect(cold_conditions).not_to be_empty
    end
  end
end
