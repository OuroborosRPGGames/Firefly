# frozen_string_literal: true

module Commands
  module Environment
    class Weather < Commands::Base::Command
      command_name 'weather'
      aliases 'forecast', 'conditions'
      category :info
      output_category :info
      help_text 'Check the current weather conditions'
      usage 'weather [forecast]'
      examples 'weather', 'forecast', 'conditions', 'weather forecast'

      WIND_DIRECTIONS = %w[N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW].freeze

      protected

      def perform_command(parsed_input)
        args = parsed_input[:text]&.strip || ''

        # Handle forecast subcommand (either 'weather forecast' or the 'forecast' alias)
        if args.downcase == 'forecast' || parsed_input[:command_word] == 'forecast'
          return handle_forecast
        end

        room_location = location&.location

        # Check if this room shows weather
        unless room_shows_weather?
          return success_result(
            'You cannot see the sky from here.',
            type: :message,
            data: { action: 'weather', visible: false }
          )
        end

        weather = room_location ? ::Weather.for_location(room_location) : nil

        unless weather
          return success_result(
            'The weather is unclear.',
            type: :message,
            data: { action: 'weather', available: false }
          )
        end

        # Get atmospheric prose
        prose = room_location ? WeatherProseService.prose_for(room_location) : nil

        lines = []
        lines << prose if prose && !prose.empty?
        lines << ''
        lines << format_weather_details(weather)

        data = build_weather_data(weather, prose)

        # Enrich with grid weather data if available
        enrich_with_grid_data(data) if grid_weather_active?

        success_result(
          lines.join("\n"),
          type: :message,
          data: data
        )
      end

      private

      def wind_direction_label(degrees)
        return nil unless degrees
        index = ((degrees.to_f % 360) / 22.5).round % 16
        WIND_DIRECTIONS[index]
      end

      def grid_weather_active?
        loc = character_instance&.current_room&.location
        return false unless loc
        world = loc.world
        world&.grid_weather? && loc.has_globe_hex?
      end

      def enrich_with_grid_data(data)
        loc = character_instance.current_room&.location
        return unless loc

        snapshot = WeatherGrid::InterpolationService.weather_for_location(loc)
        return unless snapshot

        data[:wind_direction] = wind_direction_label(snapshot['wind_dir'])
        data[:pressure_hpa] = snapshot['pressure']&.round

        if snapshot['active_storm']
          storm = snapshot['active_storm']
          data[:storm_warning] = "A #{storm['type']&.tr('_', ' ')} (#{storm['phase']}) is active in this area."
        end
      rescue StandardError => e
        warn "[WeatherCommand] Grid enrichment failed: #{e.message}"
      end

      def handle_forecast
        unless room_shows_weather?
          return success_result(
            'You cannot see the sky from here.',
            type: :message,
            data: { action: 'weather', visible: false }
          )
        end

        unless grid_weather_active?
          return success_result(
            'Weather forecasting is not available in this area.',
            type: :weather,
            data: { action: 'weather_forecast', available: false }
          )
        end

        loc = character_instance.current_room&.location
        snapshot = WeatherGrid::InterpolationService.weather_for_location(loc)
        unless snapshot
          return success_result(
            'Unable to generate forecast.',
            type: :weather,
            data: { action: 'weather_forecast', available: false }
          )
        end

        lines = []
        lines << '<h4>Weather Forecast</h4>'
        lines << ''
        lines << "Current: #{snapshot['condition']&.tr('_', ' ')&.capitalize}, #{snapshot['temperature']&.round}\u00B0C"
        lines << "Wind: #{wind_direction_label(snapshot['wind_dir'])} at #{snapshot['wind_speed']&.round} kph"
        lines << "Pressure: #{snapshot['pressure']&.round} hPa | Humidity: #{snapshot['humidity']&.round}%"

        if snapshot['active_storm']
          storm = snapshot['active_storm']
          lines << ''
          lines << "[Storm Warning] #{storm['type']&.tr('_', ' ')&.capitalize} (#{storm['phase']}) detected in the area."
        end

        success_result(
          lines.join("\n"),
          type: :weather,
          data: {
            action: 'weather_forecast',
            available: true,
            forecast: true,
            condition: snapshot['condition'],
            temperature_c: snapshot['temperature']&.round,
            wind_direction: wind_direction_label(snapshot['wind_dir']),
            wind_speed_kph: snapshot['wind_speed']&.round,
            pressure_hpa: snapshot['pressure']&.round,
            humidity: snapshot['humidity']&.round,
            storm: snapshot['active_storm']
          }
        )
      end

      def room_shows_weather?
        # Check room's weather_visible flag (defaults to true if not set)
        return true unless location.respond_to?(:weather_visible)

        location.weather_visible != false
      end

      def format_weather_details(weather)
        temp_f = weather.temperature_f.round
        wind_mph = weather.wind_speed_mph.round

        details = []
        details << "Conditions: #{weather.description}"
        details << "Temperature: #{weather.temperature_c}\u00B0C (#{temp_f}\u00B0F)"
        details << "Wind: #{wind_mph} mph"
        details << "Humidity: #{weather.humidity}%" if weather.humidity
        details << "Cloud Cover: #{weather.cloud_cover}%" if weather.cloud_cover

        details.join(' | ')
      end

      def build_weather_data(weather, prose)
        {
          action: 'weather',
          visible: true,
          available: true,
          condition: weather.condition,
          intensity: weather.intensity,
          temperature_c: weather.temperature_c,
          temperature_f: weather.temperature_f.round,
          temperature_description: weather.temperature_description,
          humidity: weather.humidity,
          wind_speed_kph: weather.wind_speed_kph,
          wind_speed_mph: weather.wind_speed_mph.round,
          cloud_cover: weather.cloud_cover,
          prose: prose,
          severe: weather.severe?,
          visibility_reduced: weather.visibility_reduced?,
          weather_source: weather.weather_source
        }
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Environment::Weather)
