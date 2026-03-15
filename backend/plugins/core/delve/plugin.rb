# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Delve
    # Delve plugin provides procedural dungeon exploration commands.
    #
    # Commands:
    # - delve: Enter and explore procedural dungeons with fog of war
    #
    # Features:
    # - Fractal dungeon generation with multiple levels
    # - Per-action time costs (60 minute limit)
    # - Fog of war (3 square danger visibility)
    # - Monsters, traps, treasure, and boss fights
    #
    class Plugin < Firefly::Plugin
      name :delve
      version '1.0.0'
      description 'Procedural dungeon exploration with timed challenges'

      commands_path 'commands'

      def self.on_enable
        puts "[Delve] Delve commands enabled"
      end

      def self.on_disable
        puts "[Delve] Delve commands disabled"
      end
    end
  end
end
