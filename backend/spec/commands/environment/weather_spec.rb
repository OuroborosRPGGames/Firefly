# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Environment::Weather, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Weatherman') }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  before do
    allow(WeatherProseService).to receive(:prose_for).and_return('The sky is clear.')
  end

  describe 'command metadata' do
    it 'has correct name' do
      expect(described_class.command_name).to eq('weather')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:info)
    end

    it 'has aliases' do
      expect(described_class.alias_names).to include('forecast', 'conditions')
    end

    it 'has help text' do
      expect(described_class.help_text).to include('weather')
    end

    it 'has usage' do
      expect(described_class.usage).to include('weather')
    end

    it 'has examples' do
      expect(described_class.examples).to be_an(Array)
      expect(described_class.examples.length).to be > 0
    end
  end

  describe '#execute' do
    context 'with weather data available' do
      let!(:weather) do
        create(:weather,
               location: location,
               condition: 'clear',
               intensity: 'moderate',
               temperature_c: 22,
               humidity: 55,
               wind_speed_kph: 15,
               cloud_cover: 20)
      end

      it 'returns success' do
        result = command.execute('')
        expect(result[:success]).to be true
      end

      it 'includes weather data' do
        result = command.execute('')
        expect(result[:data][:action]).to eq('weather')
        expect(result[:data][:visible]).to be true
      end

      it 'includes temperature in celsius' do
        result = command.execute('')
        expect(result[:data][:temperature_c]).to eq(22)
      end

      it 'includes condition' do
        result = command.execute('')
        expect(result[:data][:condition]).to eq('clear')
      end

      it 'includes humidity' do
        result = command.execute('')
        expect(result[:data][:humidity]).to eq(55)
      end

      it 'includes wind speed' do
        result = command.execute('')
        expect(result[:data][:wind_speed_kph]).to eq(15)
      end

      it 'includes prose description' do
        result = command.execute('')
        expect(result[:data][:prose]).to eq('The sky is clear.')
      end
    end

    context 'without weather data' do
      it 'returns success with a message' do
        result = command.execute('')
        expect(result[:success]).to be true
        expect(result[:message]).to be_a(String)
      end
    end

    context 'with grid weather active' do
      let!(:weather) do
        create(:weather,
               location: location,
               condition: 'clear',
               intensity: 'moderate',
               temperature_c: 22,
               humidity: 55,
               wind_speed_kph: 15,
               cloud_cover: 20)
      end

      before do
        allow_any_instance_of(Commands::Environment::Weather).to receive(:grid_weather_active?).and_return(true)
      end

      it 'enriches weather data with wind direction' do
        mock_snapshot = { 'wind_dir' => 220, 'pressure' => 1008.0 }
        allow(WeatherGrid::InterpolationService).to receive(:weather_for_location).and_return(mock_snapshot)

        result = command.execute('')
        expect(result[:data][:wind_direction]).to eq('SW')
        expect(result[:data][:pressure_hpa]).to eq(1008)
      end

      it 'includes storm warning when storm is active' do
        allow(WeatherGrid::InterpolationService).to receive(:weather_for_location).and_return({
          'wind_dir' => 220, 'pressure' => 1008.0,
          'active_storm' => { 'type' => 'thunderstorm', 'phase' => 'mature' }
        })

        result = command.execute('')
        expect(result[:data][:storm_warning]).to include('thunderstorm')
      end

      it 'does not break when grid enrichment fails' do
        allow(WeatherGrid::InterpolationService).to receive(:weather_for_location).and_raise(StandardError, 'redis down')

        result = command.execute('')
        expect(result[:success]).to be true
        expect(result[:data][:condition]).to eq('clear')
      end
    end

    context 'without grid weather active' do
      let!(:weather) do
        create(:weather,
               location: location,
               condition: 'clear',
               intensity: 'moderate',
               temperature_c: 22,
               humidity: 55,
               wind_speed_kph: 15,
               cloud_cover: 20)
      end

      it 'does not include grid-specific fields' do
        result = command.execute('')
        expect(result[:data]).not_to have_key(:wind_direction)
        expect(result[:data]).not_to have_key(:pressure_hpa)
        expect(result[:data]).not_to have_key(:storm_warning)
      end
    end
  end

  describe 'forecast subcommand' do
    context 'when grid weather is not active' do
      it 'returns not available message via weather forecast args' do
        result = command.execute('weather forecast')
        expect(result[:success]).to be true
        expect(result[:message]).to include('not available')
      end

      it 'returns not available message via forecast alias' do
        result = command.execute('forecast')
        expect(result[:success]).to be true
        expect(result[:message]).to include('not available')
      end
    end

    context 'when grid weather is active' do
      before do
        allow_any_instance_of(Commands::Environment::Weather).to receive(:grid_weather_active?).and_return(true)
      end

      it 'returns forecast data' do
        allow(WeatherGrid::InterpolationService).to receive(:weather_for_location).and_return({
          'condition' => 'clear', 'temperature' => 22.0, 'wind_dir' => 180,
          'pressure' => 1015.0, 'humidity' => 40.0, 'wind_speed' => 15.0, 'cloud_cover' => 20.0
        })

        result = command.execute('weather forecast')
        expect(result[:success]).to be true
        expect(result[:data][:forecast]).to be true
        expect(result[:data][:condition]).to eq('clear')
        expect(result[:data][:temperature_c]).to eq(22)
        expect(result[:data][:wind_direction]).to eq('S')
        expect(result[:data][:wind_speed_kph]).to eq(15)
        expect(result[:data][:pressure_hpa]).to eq(1015)
        expect(result[:data][:humidity]).to eq(40)
      end

      it 'includes storm data in forecast' do
        allow(WeatherGrid::InterpolationService).to receive(:weather_for_location).and_return({
          'condition' => 'thunderstorm', 'temperature' => 25.0, 'wind_dir' => 90,
          'pressure' => 995.0, 'humidity' => 85.0, 'wind_speed' => 40.0, 'cloud_cover' => 100.0,
          'active_storm' => { 'type' => 'thunderstorm', 'phase' => 'mature' }
        })

        result = command.execute('weather forecast')
        expect(result[:success]).to be true
        expect(result[:data][:storm]).to be_a(Hash)
        expect(result[:data][:storm]['type']).to eq('thunderstorm')
        expect(result[:message]).to include('Storm Warning')
      end

      it 'returns not available when snapshot is nil' do
        allow(WeatherGrid::InterpolationService).to receive(:weather_for_location).and_return(nil)

        result = command.execute('weather forecast')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Unable to generate forecast')
      end
    end
  end

  describe 'wind direction helper' do
    subject(:cmd) { described_class.new(character_instance) }

    it 'maps 0 degrees to N' do
      expect(cmd.send(:wind_direction_label, 0)).to eq('N')
    end

    it 'maps 90 degrees to E' do
      expect(cmd.send(:wind_direction_label, 90)).to eq('E')
    end

    it 'maps 180 degrees to S' do
      expect(cmd.send(:wind_direction_label, 180)).to eq('S')
    end

    it 'maps 270 degrees to W' do
      expect(cmd.send(:wind_direction_label, 270)).to eq('W')
    end

    it 'maps 220 degrees to SW' do
      expect(cmd.send(:wind_direction_label, 220)).to eq('SW')
    end

    it 'returns nil for nil input' do
      expect(cmd.send(:wind_direction_label, nil)).to be_nil
    end

    it 'handles values over 360' do
      expect(cmd.send(:wind_direction_label, 450)).to eq('E')
    end
  end
end
