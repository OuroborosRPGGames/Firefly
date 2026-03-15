# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WeatherGrid::InterpolationService do
  let(:world) { create(:world) }

  before do
    WeatherGrid::GridService.clear(world)
    WeatherGrid::TerrainService.clear(world)
    WeatherGrid::GridService.initialize_world(world)
  end

  after do
    described_class.clear_all_cache(world)
    WeatherGrid::GridService.clear(world)
    WeatherGrid::TerrainService.clear(world)
  end

  describe '.weather_at' do
    it 'returns interpolated weather for a lat/lon' do
      weather = described_class.weather_at(world, latitude: 0.0, longitude: 0.0)

      expect(weather).not_to be_nil
      expect(weather).to have_key('temperature')
      expect(weather).to have_key('humidity')
      expect(weather).to have_key('pressure')
      expect(weather).to have_key('wind_speed')
      expect(weather).to have_key('condition')
    end

    it 'includes lat/lon coordinates in result' do
      weather = described_class.weather_at(world, latitude: 30.0, longitude: -45.0)

      expect(weather['latitude']).to eq(30.0)
      expect(weather['longitude']).to eq(-45.0)
    end

    it 'includes computed timestamp' do
      weather = described_class.weather_at(world, latitude: 0.0, longitude: 0.0)

      expect(weather['computed_at']).not_to be_nil
    end

    it 'caches results' do
      # First call computes
      weather1 = described_class.weather_at(world, latitude: 0.0, longitude: 0.0)

      # Second call should return cached value
      weather2 = described_class.weather_at(world, latitude: 0.0, longitude: 0.0)

      expect(weather1['computed_at']).to eq(weather2['computed_at'])
    end

    it 'returns nil for invalid world' do
      expect(described_class.weather_at(nil, latitude: 0.0, longitude: 0.0)).to be_nil
    end
  end

  describe '.weather_for_location' do
    it 'returns nil for locations without globe_hex_id' do
      loc = double('Location', globe_hex_id: nil, world_id: 1)
      result = described_class.weather_for_location(loc)
      expect(result).to be_nil
    end

    it 'returns nil for locations without a world' do
      loc = double('Location', globe_hex_id: 42, world_id: 1, world: nil)
      result = described_class.weather_for_location(loc)
      expect(result).to be_nil
    end

    it 'returns nil for locations whose world_hex has no lat/lon' do
      world_hex = double('WorldHex', latitude: nil, longitude: nil)
      loc = double('Location', globe_hex_id: 42, world_id: 1, world: world, world_hex: world_hex)
      result = described_class.weather_for_location(loc)
      expect(result).to be_nil
    end

    it 'returns weather for a valid location with globe hex' do
      world_hex = double('WorldHex', latitude: 0.0, longitude: 0.0)
      loc = double('Location', globe_hex_id: 42, world_id: world.id, world: world, world_hex: world_hex)
      result = described_class.weather_for_location(loc)
      expect(result).not_to be_nil
      expect(result).to have_key('condition')
    end
  end

  describe '.condition_for_location' do
    it 'returns clear for locations without globe_hex_id' do
      loc = double('Location', globe_hex_id: nil, world_id: 1)
      expect(described_class.condition_for_location(loc)).to eq('clear')
    end

    it 'returns a condition string for a valid location' do
      world_hex = double('WorldHex', latitude: 0.0, longitude: 0.0)
      loc = double('Location', globe_hex_id: 42, world_id: world.id, world: world, world_hex: world_hex)
      condition = described_class.condition_for_location(loc)
      expect(condition).to be_a(String)
      expect(%w[clear partly_cloudy cloudy overcast light_rain rain heavy_rain
                light_snow snow blizzard fog thunderstorm]).to include(condition)
    end
  end

  describe '.condition_at' do
    it 'returns weather condition string' do
      condition = described_class.condition_at(world, latitude: 0.0, longitude: 0.0)

      expect(condition).to be_a(String)
      expect(%w[clear partly_cloudy cloudy overcast light_rain rain heavy_rain
                light_snow snow blizzard fog thunderstorm]).to include(condition)
    end

    it 'returns clear for calm weather' do
      # Set calm conditions in the grid
      grid = WeatherGrid::GridService.load(world)
      grid[:cells].each do |cell|
        cell['cloud_cover'] = 10
        cell['precip_rate'] = 0
        cell['humidity'] = 50
      end
      WeatherGrid::GridService.save(world, grid)
      described_class.clear_all_cache(world)

      condition = described_class.condition_at(world, latitude: 0.0, longitude: 0.0)
      expect(condition).to eq('clear')
    end
  end

  describe '.description_at' do
    it 'returns human-readable weather description' do
      description = described_class.description_at(world, latitude: 0.0, longitude: 0.0)

      expect(description).to be_a(String)
      expect(description).to include("\u00B0C")
      expect(description).to include('kph')
      expect(description).to include('humidity')
    end

    it 'includes condition in description' do
      description = described_class.description_at(world, latitude: 0.0, longitude: 0.0)

      # Should contain a capitalized condition word
      expect(description).to match(/Clear|Cloudy|Rain|Snow|Fog|Storm|Overcast|Partly/i)
    end
  end

  describe 'weather conditions' do
    before do
      described_class.clear_all_cache(world)
    end

    it 'derives rain from high precipitation and warm temp' do
      grid = WeatherGrid::GridService.load(world)
      center_idx = WeatherGrid::GridService.coords_to_index(32, 32)
      grid[:cells][center_idx]['precip_rate'] = 5.0
      grid[:cells][center_idx]['temperature'] = 15.0
      grid[:cells][center_idx]['cloud_cover'] = 80.0
      grid[:cells][center_idx]['instability'] = 30.0
      WeatherGrid::GridService.save(world, grid)

      # lat=0, lon=0 maps to grid center (32, 32)
      weather = described_class.weather_at(world, latitude: 0.0, longitude: 0.0)
      expect(weather['condition']).to eq('rain')
    end

    it 'derives snow from precipitation and cold temp' do
      grid = WeatherGrid::GridService.load(world)
      center_idx = WeatherGrid::GridService.coords_to_index(32, 32)
      grid[:cells][center_idx]['precip_rate'] = 5.0
      grid[:cells][center_idx]['temperature'] = -5.0
      grid[:cells][center_idx]['cloud_cover'] = 90.0
      WeatherGrid::GridService.save(world, grid)

      weather = described_class.weather_at(world, latitude: 0.0, longitude: 0.0)
      expect(weather['condition']).to eq('snow')
    end

    it 'derives fog from very high humidity and low wind' do
      grid = WeatherGrid::GridService.load(world)
      center_idx = WeatherGrid::GridService.coords_to_index(32, 32)
      grid[:cells][center_idx]['humidity'] = 98.0
      grid[:cells][center_idx]['wind_speed'] = 3.0
      grid[:cells][center_idx]['precip_rate'] = 0.0
      grid[:cells][center_idx]['cloud_cover'] = 50.0
      WeatherGrid::GridService.save(world, grid)

      weather = described_class.weather_at(world, latitude: 0.0, longitude: 0.0)
      expect(weather['condition']).to eq('fog')
    end
  end

  describe 'terrain adjustments' do
    before do
      described_class.clear_all_cache(world)
    end

    it 'applies altitude lapse rate' do
      # Create a high altitude hex near lat=-90, lon=-180 (grid 0,0)
      WorldHex.create(
        world: world,
        globe_hex_id: 99999,
        latitude: -90.0,
        longitude: -180.0,
        terrain_type: 'mountain',
        altitude: 2000
      )

      # Set base grid temperature at cell (0,0)
      grid = WeatherGrid::GridService.load(world)
      grid[:cells][0]['temperature'] = 20.0
      WeatherGrid::GridService.save(world, grid)

      weather = described_class.weather_at(world, latitude: -90.0, longitude: -180.0)

      # 2000m altitude should reduce temp by ~13C (6.5C per 1000m)
      # Plus additional -3C for mountain terrain type
      expect(weather['temperature']).to be < 10
    end

    it 'increases humidity over water' do
      WorldHex.create(
        world: world,
        globe_hex_id: 99998,
        latitude: -90.0,
        longitude: -180.0,
        terrain_type: 'ocean',
        altitude: 0
      )

      grid = WeatherGrid::GridService.load(world)
      grid[:cells][0]['humidity'] = 50.0
      WeatherGrid::GridService.save(world, grid)

      weather = described_class.weather_at(world, latitude: -90.0, longitude: -180.0)
      expect(weather['humidity']).to be > 50
    end
  end

  describe 'storm overlay' do
    before do
      described_class.clear_all_cache(world)

      # Add a storm over the test area (grid center = lat 0, lon 0)
      WeatherGrid::GridService.update_meta(world, {
        'storms' => [
          {
            'id' => 'storm_test',
            'type' => 'thunderstorm',
            'name' => 'Storm Alpha',
            'grid_x' => 32.0,
            'grid_y' => 32.0,
            'intensity' => 0.8,
            'phase' => 'mature',
            'radius_cells' => 5.0
          }
        ]
      })
    end

    it 'includes storm data in weather result' do
      weather = described_class.weather_at(world, latitude: 0.0, longitude: 0.0)

      expect(weather['active_storm']).not_to be_nil
      expect(weather['active_storm']['id']).to eq('storm_test')
      expect(weather['active_storm']['name']).to eq('Storm Alpha')
    end

    it 'returns storm type as condition' do
      weather = described_class.weather_at(world, latitude: 0.0, longitude: 0.0)

      expect(weather['condition']).to eq('thunderstorm')
    end

    it 'boosts precipitation from storm' do
      # Get weather outside storm (lat=-45, lon=-90 => grid ~16,16)
      weather_outside = described_class.weather_at(world, latitude: -45.0, longitude: -90.0)

      # Get weather inside storm (lat=0, lon=0 => grid center)
      weather_inside = described_class.weather_at(world, latitude: 0.0, longitude: 0.0)

      expect(weather_inside['precip_rate']).to be > weather_outside['precip_rate']
    end
  end

  describe '.clear_cache' do
    it 'clears cached weather for a specific lat/lon' do
      lat = 0.0
      lon = 0.0

      # Populate cache
      described_class.weather_at(world, latitude: lat, longitude: lon)

      # Clear specific location
      described_class.clear_cache(world, lat, lon)

      # Verify cache key was removed
      lat_bucket = (lat * 10).round
      lon_bucket = (lon * 10).round
      REDIS_POOL.with do |redis|
        key_exists = redis.exists?("weather:#{world.id}:ll:#{lat_bucket}:#{lon_bucket}")
        expect(key_exists).to be false
      end
    end
  end

  describe '.clear_all_cache' do
    it 'clears all cached weather for a world' do
      # Populate cache with multiple locations
      described_class.weather_at(world, latitude: 0.0, longitude: 0.0)
      described_class.weather_at(world, latitude: 30.0, longitude: 30.0)
      described_class.weather_at(world, latitude: -45.0, longitude: -90.0)

      # Clear all
      described_class.clear_all_cache(world)

      # Verify all cleared
      REDIS_POOL.with do |redis|
        keys = redis.keys("weather:#{world.id}:ll:*")
        expect(keys).to be_empty
      end
    end
  end
end
