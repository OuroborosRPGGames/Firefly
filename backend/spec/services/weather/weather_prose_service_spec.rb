# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WeatherProseService do
  let(:location) { create(:location) }
  let(:weather) do
    double('Weather',
      condition: 'clear',
      intensity: 'moderate',
      temperature_c: 20,
      temperature_description: 'pleasant',
      wind_speed_mph: 10,
      wind_speed_kph: 16,
      cloud_cover: 20,
      stars_visible?: true
    )
  end

  before do
    allow(Weather).to receive(:for_location).with(location).and_return(weather)
    allow(GameTimeService).to receive(:time_of_day).and_return(:day)
    allow(MoonPhaseService).to receive(:phase_name).and_return('full moon')
    allow(GameSetting).to receive(:get_boolean).with('ai_weather_prose_enabled').and_return(false)
    allow(WeatherProseCache).to receive(:find_valid).and_return(nil)
    allow(WeatherProseCache).to receive(:cache_for)
  end

  describe 'CACHE_DURATION_MINUTES' do
    it 'is 45 minutes' do
      expect(described_class::CACHE_DURATION_MINUTES).to eq(45)
    end
  end

  describe '.prose_for' do
    context 'with cached prose' do
      let(:cached_prose) { double('WeatherProseCache', prose_text: 'Cached sunny day.') }

      before do
        allow(WeatherProseCache).to receive(:find_valid).and_return(cached_prose)
      end

      it 'returns cached prose' do
        result = described_class.prose_for(location)

        expect(result).to eq('Cached sunny day.')
      end

      it 'does not generate new prose' do
        expect(described_class).not_to receive(:generate_prose)

        described_class.prose_for(location)
      end
    end

    context 'without cached prose' do
      it 'returns generated prose' do
        result = described_class.prose_for(location)

        expect(result).to be_a(String)
        expect(result.length).to be > 0
      end

      it 'caches the generated prose' do
        expect(WeatherProseCache).to receive(:cache_for).with(hash_including(
          location: location,
          prose: anything
        ))

        described_class.prose_for(location)
      end
    end
  end

  describe '.generate_for' do
    it 'generates prose without caching' do
      expect(WeatherProseCache).not_to receive(:cache_for)

      result = described_class.generate_for(location)

      expect(result).to be_a(String)
    end

    it 'returns generated prose' do
      result = described_class.generate_for(location)

      expect(result.length).to be > 0
    end
  end

  describe '.clear_expired_cache!' do
    it 'delegates to WeatherProseCache.clear_expired!' do
      expect(WeatherProseCache).to receive(:clear_expired!)

      described_class.clear_expired_cache!
    end
  end

  describe '.invalidate_cache!' do
    it 'delegates to WeatherProseCache.clear_for_location!' do
      expect(WeatherProseCache).to receive(:clear_for_location!).with(location)

      described_class.invalidate_cache!(location)
    end
  end

  describe 'private methods' do
    describe '.build_context' do
      it 'builds context hash with weather data' do
        context = described_class.send(:build_context, weather, :day, 'full moon')

        expect(context[:condition]).to eq('clear')
        expect(context[:intensity]).to eq('moderate')
        expect(context[:time_of_day]).to eq(:day)
        expect(context[:moon_phase]).to eq('full moon')
        expect(context[:temperature_c]).to eq(20)
      end
    end

    describe '.describe_wind' do
      it 'returns calm for 0-5 mph' do
        expect(described_class.send(:describe_wind, 3)).to eq('calm')
        expect(described_class.send(:describe_wind, 5)).to eq('calm')
      end

      it 'returns light breeze for 6-15 mph' do
        expect(described_class.send(:describe_wind, 10)).to eq('a light breeze')
        expect(described_class.send(:describe_wind, 15)).to eq('a light breeze')
      end

      it 'returns moderate wind for 16-25 mph' do
        expect(described_class.send(:describe_wind, 20)).to eq('moderate wind')
      end

      it 'returns strong wind for 26-40 mph' do
        expect(described_class.send(:describe_wind, 35)).to eq('strong wind')
      end

      it 'returns gale-force wind for over 40 mph' do
        expect(described_class.send(:describe_wind, 50)).to eq('gale-force wind')
      end
    end

    describe '.describe_clouds' do
      it 'returns clear skies for 0-10%' do
        expect(described_class.send(:describe_clouds, 5)).to eq('clear skies')
        expect(described_class.send(:describe_clouds, 10)).to eq('clear skies')
      end

      it 'returns scattered clouds for 11-30%' do
        expect(described_class.send(:describe_clouds, 20)).to eq('scattered clouds')
      end

      it 'returns partly cloudy for 31-70%' do
        expect(described_class.send(:describe_clouds, 50)).to eq('partly cloudy')
      end

      it 'returns mostly cloudy for 71-90%' do
        expect(described_class.send(:describe_clouds, 80)).to eq('mostly cloudy')
      end

      it 'returns overcast for over 90%' do
        expect(described_class.send(:describe_clouds, 95)).to eq('overcast')
      end
    end

    describe '.fallback_prose' do
      it 'returns combined prose parts' do
        result = described_class.send(:fallback_prose, weather, :day, 'full moon')

        expect(result).to be_a(String)
        expect(result.length).to be > 0
      end

      it 'includes time-based opening' do
        # Run multiple times to account for random selection
        results = 10.times.map { described_class.send(:fallback_prose, weather, :day, 'full moon') }

        # Should contain at least one sun/day reference
        expect(results.any? { |r| r.include?('sun') || r.include?('Sunlight') || r.include?('day') || r.include?('Clouds') }).to be true
      end
    end

    describe '.time_opening' do
      context 'dawn' do
        it 'returns a dawn opening' do
          result = described_class.send(:time_opening, :dawn, 'full moon', weather)
          lowered = result.downcase

          expect(lowered).to include('dawn').or include('light').or include('morning').or include('rosy').or include('stirs')
        end
      end

      context 'day with clear sky' do
        before do
          allow(weather).to receive(:cloud_cover).and_return(10)
        end

        it 'returns a sunny day opening' do
          result = described_class.send(:time_opening, :day, 'full moon', weather)

          expect(result).to be_a(String)
        end
      end

      context 'day with cloudy sky' do
        before do
          allow(weather).to receive(:cloud_cover).and_return(60)
        end

        it 'returns a cloudy day opening' do
          result = described_class.send(:time_opening, :day, 'full moon', weather)

          expect(result).to be_a(String)
        end
      end

      context 'dusk' do
        it 'returns a dusk opening' do
          result = described_class.send(:time_opening, :dusk, 'full moon', weather)

          expect(result).to include('sun').or include('Evening').or include('Twilight').or include('fades')
        end
      end

      context 'night with visible stars' do
        before do
          allow(weather).to receive(:stars_visible?).and_return(true)
        end

        it 'returns a starry night opening' do
          result = described_class.send(:time_opening, :night, 'full moon', weather)

          expect(result).to include('moon').or include('Stars').or include('Night').or include('night')
        end
      end

      context 'night without visible stars' do
        before do
          allow(weather).to receive(:stars_visible?).and_return(false)
        end

        it 'returns a dark night opening' do
          result = described_class.send(:time_opening, :night, 'full moon', weather)

          expect(result).to include('darkness').or include('shadow').or include('clouds').or include('Night').or include('night')
        end
      end
    end

    describe '.weather_description' do
      it 'returns description for clear weather' do
        allow(weather).to receive(:condition).and_return('clear')

        result = described_class.send(:weather_description, weather)

        expect(result).to include('clear').or include('crisp').or include('horizon').or include('cloud')
      end

      it 'returns description for cloudy weather' do
        allow(weather).to receive(:condition).and_return('cloudy')

        result = described_class.send(:weather_description, weather)

        expect(result).to include('clouds').or include('Clouds')
      end

      it 'returns description for overcast weather' do
        allow(weather).to receive(:condition).and_return('overcast')

        result = described_class.send(:weather_description, weather)

        expect(result).to eq('Heavy clouds blanket the sky.')
      end

      it 'returns description for rain' do
        allow(weather).to receive(:condition).and_return('rain')
        allow(weather).to receive(:intensity).and_return('light')

        result = described_class.send(:weather_description, weather)

        expect(result).to include('drizzle').or include('rain').or include('patters')
      end

      it 'returns description for thunderstorm' do
        allow(weather).to receive(:condition).and_return('thunderstorm')

        result = described_class.send(:weather_description, weather)

        expect(result).to include('Thunder').or include('lightning')
      end

      it 'returns description for snow' do
        allow(weather).to receive(:condition).and_return('snow')
        allow(weather).to receive(:intensity).and_return('moderate')

        result = described_class.send(:weather_description, weather)

        expect(result).to include('Snow').or include('snow').or include('white')
      end

      it 'returns description for fog' do
        allow(weather).to receive(:condition).and_return('fog')

        result = described_class.send(:weather_description, weather)

        expect(result).to eq('Mist clings to the ground, obscuring distant shapes.')
      end

      it 'returns description for heat wave' do
        allow(weather).to receive(:condition).and_return('heat_wave')

        result = described_class.send(:weather_description, weather)

        expect(result).to eq('The air shimmers with oppressive heat.')
      end

      it 'returns nil for unknown condition' do
        allow(weather).to receive(:condition).and_return('unknown')

        result = described_class.send(:weather_description, weather)

        expect(result).to be_nil
      end
    end

    describe '.rain_descriptions' do
      it 'returns light rain descriptions' do
        allow(weather).to receive(:intensity).and_return('light')

        result = described_class.send(:rain_descriptions, weather)

        expect(result).to be_an(Array)
        expect(result.any? { |d| d.include?('drizzle') || d.include?('Gentle') }).to be true
      end

      it 'returns moderate rain descriptions' do
        allow(weather).to receive(:intensity).and_return('moderate')

        result = described_class.send(:rain_descriptions, weather)

        expect(result.any? { |d| d.include?('steady') || d.include?('drum') }).to be true
      end

      it 'returns heavy rain descriptions' do
        allow(weather).to receive(:intensity).and_return('heavy')

        result = described_class.send(:rain_descriptions, weather)

        expect(result.any? { |d| d.include?('Heavy') || d.include('pounds') || d.include?('Sheets') }).to be true
      end

      it 'returns severe rain descriptions' do
        allow(weather).to receive(:intensity).and_return('severe')

        result = described_class.send(:rain_descriptions, weather)

        expect(result.any? { |d| d.include?('Torrential') || d.include?('deluge') }).to be true
      end
    end

    describe '.snow_descriptions' do
      it 'returns light snow descriptions' do
        allow(weather).to receive(:intensity).and_return('light')

        result = described_class.send(:snow_descriptions, weather)

        expect(result.any? { |d| d.include?('flurries') || d.include?('dance') }).to be true
      end

      it 'returns heavy snow descriptions' do
        allow(weather).to receive(:intensity).and_return('heavy')

        result = described_class.send(:snow_descriptions, weather)

        expect(result.any? { |d| d.include?('Heavy') || d.include?('blankets') || d.include?('piles') }).to be true
      end
    end

    describe '.wind_descriptions' do
      it 'returns powerful wind descriptions for high speeds' do
        allow(weather).to receive(:wind_speed_mph).and_return(35)

        result = described_class.send(:wind_descriptions, weather)

        expect(result.any? { |d| d.include?('Powerful') || d.include?('howls') }).to be true
      end

      it 'returns brisk wind descriptions for moderate speeds' do
        allow(weather).to receive(:wind_speed_mph).and_return(20)

        result = described_class.send(:wind_descriptions, weather)

        expect(result.any? { |d| d.include?('brisk') || d.include?('Gusty') }).to be true
      end

      it 'returns gentle wind descriptions for low speeds' do
        allow(weather).to receive(:wind_speed_mph).and_return(5)

        result = described_class.send(:wind_descriptions, weather)

        expect(result.any? { |d| d.include?('gentle') || d.include?('whispers') }).to be true
      end
    end

    describe '.temperature_feeling' do
      it 'returns bitter cold for below -10C' do
        allow(weather).to receive(:temperature_c).and_return(-15)

        result = described_class.send(:temperature_feeling, weather)

        expect(result).to eq('The cold bites at exposed skin.')
      end

      it 'returns freezing for -10 to 0C' do
        allow(weather).to receive(:temperature_c).and_return(-5)

        result = described_class.send(:temperature_feeling, weather)

        expect(result).to eq('The air holds a freezing chill.')
      end

      it 'returns cold for 0 to 10C' do
        allow(weather).to receive(:temperature_c).and_return(5)

        result = described_class.send(:temperature_feeling, weather)

        expect(result).to eq('A cold edge lingers in the air.')
      end

      it 'returns cool for 10 to 15C' do
        allow(weather).to receive(:temperature_c).and_return(12)

        result = described_class.send(:temperature_feeling, weather)

        expect(result).to eq('The temperature is pleasantly cool.')
      end

      it 'returns nil for comfortable 15-25C' do
        allow(weather).to receive(:temperature_c).and_return(22)

        result = described_class.send(:temperature_feeling, weather)

        expect(result).to be_nil
      end

      it 'returns warm for 25 to 30C' do
        allow(weather).to receive(:temperature_c).and_return(28)

        result = described_class.send(:temperature_feeling, weather)

        expect(result).to eq('Warmth hangs heavy in the air.')
      end

      it 'returns oppressive heat for 30 to 35C' do
        allow(weather).to receive(:temperature_c).and_return(33)

        result = described_class.send(:temperature_feeling, weather)

        expect(result).to eq('The heat presses down oppressively.')
      end

      it 'returns scorching for over 35C' do
        allow(weather).to receive(:temperature_c).and_return(40)

        result = described_class.send(:temperature_feeling, weather)

        expect(result).to eq('The scorching heat is almost unbearable.')
      end
    end
  end

  describe 'AI prose generation' do
    before do
      allow(GameSetting).to receive(:boolean).with('ai_weather_prose_enabled').and_return(true)
      allow(AIProviderService).to receive(:any_available?).and_return(true)
      allow(GamePrompts).to receive(:get).and_return('Generate weather prose')
    end

    context 'when AI generation succeeds' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: 'AI-generated weather prose.'
        })
      end

      it 'returns AI-generated prose' do
        result = described_class.generate_for(location)

        expect(result).to eq('AI-generated weather prose.')
      end
    end

    context 'when AI generation fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({
          success: false,
          error: 'Generation failed'
        })
      end

      it 'falls back to template prose' do
        result = described_class.generate_for(location)

        expect(result).not_to eq('AI-generated weather prose.')
        expect(result.length).to be > 0
      end
    end

    context 'when AI is not available' do
      before do
        allow(AIProviderService).to receive(:any_available?).and_return(false)
      end

      it 'falls back to template prose' do
        result = described_class.generate_for(location)

        expect(result.length).to be > 0
      end
    end

    context 'when AI generation raises error' do
      before do
        allow(LLM::Client).to receive(:generate).and_raise(StandardError.new('API error'))
      end

      it 'falls back to template prose' do
        result = described_class.generate_for(location)

        expect(result.length).to be > 0
      end

      it 'logs the error' do
        expect {
          described_class.generate_for(location)
        }.to output(/AI generation failed/).to_stderr
      end
    end
  end
end
