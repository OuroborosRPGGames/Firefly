# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Environment
    # Environment plugin provides context-sensitive actions and world information.
    #
    # Commands:
    # - time/clock/date: Show current game time and celestial info
    # - weather/forecast: Show current weather conditions with prose
    # - swim: Swim in water (requires water room type)
    # - rest: Rest to recover (requires not in combat)
    #
    # Services:
    # - GameTimeService: Manages game clock (realtime or accelerated)
    # - MoonPhaseService: Calculates lunar phases
    # - WeatherProseService: Generates atmospheric descriptions
    #
    class Plugin < Firefly::Plugin
      name :environment
      version '1.1.0'
      description 'Environment commands: time, weather, swimming, resting'

      commands_path 'commands'

      def self.on_enable
        puts '[Environment] Environment commands enabled (time, weather, swim, rest)'
      end

      def self.on_disable
        puts '[Environment] Environment commands disabled'
      end

      # Environment event handlers
      on_event :room_type_changed do |_room, _old_type, _new_type|
        # Handle room type transitions
      end

      on_event :weather_changed do |location, _old_weather, _new_weather|
        # Invalidate prose cache when weather changes
        WeatherProseService.invalidate_cache!(location) if defined?(WeatherProseService)
      end
    end
  end
end
