# frozen_string_literal: true

# WeatherProseService generates atmospheric prose descriptions of weather.
# Supports AI-generated prose with 45-minute caching.
class WeatherProseService
  CACHE_DURATION_MINUTES = 45

  class << self
    # Get weather prose for a location
    # @param location [Location] the location
    # @return [String] prose description
    def prose_for(location)
      weather = Weather.for_location(location)
      time_of_day = GameTimeService.time_of_day(location)
      moon_phase = MoonPhaseService.phase_name

      context = build_context(weather, time_of_day, moon_phase)

      # Check cache
      cached = WeatherProseCache.find_valid(
        location: location,
        condition: context[:condition],
        intensity: context[:intensity],
        time_of_day: context[:time_of_day],
        moon_phase: context[:moon_phase]
      )

      return cached.prose_text if cached

      # Return fast fallback prose immediately - never block look on LLM
      prose = fallback_prose(weather, time_of_day, moon_phase)

      # Cache the fallback prose now so subsequent looks are instant
      WeatherProseCache.cache_for(
        location: location,
        prose: prose,
        context: context
      )

      # Generate AI prose in background thread to replace fallback for next cache cycle
      if GameSetting.boolean('ai_weather_prose_enabled')
        Thread.new do
          ai_prose = generate_ai_prose(weather, time_of_day, moon_phase)
          if ai_prose
            WeatherProseCache.cache_for(
              location: location,
              prose: ai_prose,
              context: context
            )
          end
        rescue StandardError => e
          warn "[WeatherProseService] Background AI generation failed: #{e.message}"
        end
      end

      prose
    end

    # Generate prose without caching (for testing/preview)
    # Tries AI synchronously since caller explicitly wants generation
    # @param location [Location] the location
    # @return [String] prose description
    def generate_for(location)
      weather = Weather.for_location(location)
      time_of_day = GameTimeService.time_of_day(location)
      moon_phase = MoonPhaseService.phase_name

      if GameSetting.boolean('ai_weather_prose_enabled')
        ai_prose = generate_ai_prose(weather, time_of_day, moon_phase)
        return ai_prose if ai_prose
      end

      fallback_prose(weather, time_of_day, moon_phase)
    end

    # Clear expired cache entries
    # @return [Integer] number of entries cleared
    def clear_expired_cache!
      WeatherProseCache.clear_expired!
    end

    # Invalidate cache for a location (after weather change)
    # @param location [Location] the location
    # @return [Integer] number of entries cleared
    def invalidate_cache!(location)
      WeatherProseCache.clear_for_location!(location)
    end

    private

    # Build context hash for cache key
    def build_context(weather, time_of_day, moon_phase)
      {
        condition: weather.condition,
        intensity: weather.intensity,
        time_of_day: time_of_day,
        moon_phase: moon_phase,
        temperature_c: weather.temperature_c
      }
    end

    # Generate prose description (always uses fallback - AI is handled async in prose_for)
    def generate_prose(weather, time_of_day, moon_phase, _location)
      fallback_prose(weather, time_of_day, moon_phase)
    end

    # Generate AI prose for weather description
    def generate_ai_prose(weather, time_of_day, moon_phase)
      return nil unless AIProviderService.any_available?

      prompt = GamePrompts.get('weather.prose_enhancement',
        time_of_day: time_of_day.to_s,
        moon_phase: moon_phase.to_s,
        intensity: weather.intensity.to_s,
        condition: weather.condition.to_s.tr('_', ' '),
        wind_description: describe_wind(weather.wind_speed_mph),
        cloud_description: describe_clouds(weather.cloud_cover),
        temp_description: weather.temperature_description
      )

      result = LLM::Client.generate(
        prompt: prompt,
        options: { max_tokens: 200, temperature: 0.7 }
      )

      result[:success] ? result[:text]&.strip : nil
    rescue StandardError => e
      warn "[WeatherProseService] AI generation failed: #{e.message}"
      nil
    end

    # Describe wind speed in natural language
    def describe_wind(mph)
      case mph.to_i
      when 0..5 then 'calm'
      when 6..15 then 'a light breeze'
      when 16..25 then 'moderate wind'
      when 26..40 then 'strong wind'
      else 'gale-force wind'
      end
    end

    # Describe cloud cover in natural language
    def describe_clouds(percent)
      case percent.to_i
      when 0..10 then 'clear skies'
      when 11..30 then 'scattered clouds'
      when 31..70 then 'partly cloudy'
      when 71..90 then 'mostly cloudy'
      else 'overcast'
      end
    end

    # Generate fallback template-based prose
    def fallback_prose(weather, time_of_day, moon_phase)
      parts = []

      # Time of day opening
      parts << time_opening(time_of_day, moon_phase, weather)

      # Weather description
      parts << weather_description(weather)

      # Temperature feeling
      parts << temperature_feeling(weather) if weather.temperature_c

      parts.compact.join(' ')
    end

    # Opening line based on time of day
    def time_opening(time_of_day, moon_phase, weather)
      case time_of_day
      when :dawn
        dawn_openings.sample
      when :day
        day_openings(weather).sample
      when :dusk
        dusk_openings.sample
      when :night
        night_openings(moon_phase, weather).sample
      end
    end

    def dawn_openings
      [
        'The first light of dawn breaks over the horizon.',
        'A rosy glow spreads across the eastern sky.',
        'Dawn arrives with a gentle blush of color.',
        'The world stirs as morning light creeps across the land.'
      ]
    end

    def day_openings(weather)
      if weather.cloud_cover.to_i < 30
        [
          'The sun shines bright overhead.',
          'Sunlight bathes the surroundings in warmth.',
          'A clear day stretches before you.'
        ]
      else
        [
          'Clouds drift across the sky.',
          'The day unfolds under a canopy of clouds.',
          'Muted light filters through the overcast sky.'
        ]
      end
    end

    def dusk_openings
      [
        'The sun sinks toward the horizon as dusk settles in.',
        'Evening colors paint the western sky.',
        'Twilight descends, casting long shadows.',
        'The day fades into a tapestry of orange and purple.'
      ]
    end

    def night_openings(moon_phase, weather)
      if weather.stars_visible?
        [
          "The #{moon_phase} illuminates the night sky.",
          "Stars glitter overhead beneath a #{moon_phase}.",
          "Night has fallen under the watchful #{moon_phase}.",
          "The #{moon_phase} casts silver light across the land."
        ]
      else
        [
          'Night has fallen, cloaking the world in darkness.',
          'The night wraps everything in shadow.',
          "A #{moon_phase} hides behind the clouds."
        ]
      end
    end

    # Weather condition description
    def weather_description(weather)
      case weather.condition
      when 'clear'
        clear_descriptions(weather).sample
      when 'cloudy'
        cloudy_descriptions(weather).sample
      when 'overcast'
        'Heavy clouds blanket the sky.'
      when 'rain'
        rain_descriptions(weather).sample
      when 'storm'
        'Storm clouds churn overhead, threatening worse to come.'
      when 'thunderstorm'
        'Thunder rumbles in the distance as lightning flickers across the sky.'
      when 'snow'
        snow_descriptions(weather).sample
      when 'blizzard'
        'Howling wind drives snow in blinding sheets.'
      when 'fog'
        'Mist clings to the ground, obscuring distant shapes.'
      when 'wind'
        wind_descriptions(weather).sample
      when 'hail'
        'Ice pellets rattle down from angry clouds.'
      when 'heat_wave'
        'The air shimmers with oppressive heat.'
      when 'cold_snap'
        'A bitter chill grips the air.'
      else
        nil
      end
    end

    def clear_descriptions(_weather)
      [
        'The air is crisp and clear.',
        'Visibility stretches to the horizon.',
        'Not a cloud mars the sky.'
      ]
    end

    def cloudy_descriptions(_weather)
      [
        'Clouds drift lazily overhead.',
        'A patchwork of clouds moves across the sky.',
        'Fluffy clouds meander through the blue.'
      ]
    end

    def rain_descriptions(weather)
      case weather.intensity
      when 'light'
        ['A light drizzle mists the air.', 'Gentle rain patters softly.']
      when 'moderate'
        ['Rain falls in a steady rhythm.', 'Raindrops drum a constant beat.']
      when 'heavy'
        ['Heavy rain pounds everything it touches.', 'Sheets of rain obscure the distance.']
      when 'severe'
        ['Torrential rain hammers down relentlessly.', 'The deluge seems endless.']
      else
        ['Rain falls from the sky.']
      end
    end

    def snow_descriptions(weather)
      case weather.intensity
      when 'light'
        ['Light flurries drift down.', 'Snowflakes dance in the air.']
      when 'moderate'
        ['Snow falls steadily, coating everything in white.']
      when 'heavy'
        ['Heavy snow blankets the world.', 'Snow piles up quickly.']
      when 'severe'
        ['An intense snowfall transforms the landscape.']
      else
        ['Snow drifts from the clouds.']
      end
    end

    def wind_descriptions(weather)
      mph = weather.wind_speed_mph
      if mph > 30
        ['Powerful gusts threaten to knock you off balance.', 'The wind howls fiercely.']
      elsif mph > 15
        ['A brisk wind tugs at clothing and hair.', 'Gusty winds swirl around you.']
      else
        ['A gentle breeze stirs the air.', 'A light wind whispers past.']
      end
    end

    # Temperature feeling
    def temperature_feeling(weather)
      case weather.temperature_c
      when ..-10
        'The cold bites at exposed skin.'
      when -10..0
        'The air holds a freezing chill.'
      when 0..10
        'A cold edge lingers in the air.'
      when 10..15
        'The temperature is pleasantly cool.'
      when 15..20
        nil # Comfortable, no comment needed
      when 20..25
        nil # Comfortable, no comment needed
      when 25..30
        'Warmth hangs heavy in the air.'
      when 30..35
        'The heat presses down oppressively.'
      else
        'The scorching heat is almost unbearable.'
      end
    end
  end
end
