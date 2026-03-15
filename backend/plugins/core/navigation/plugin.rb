# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Navigation
    # Navigation plugin provides movement and observation commands.
    #
    # Commands:
    # - look: Examine your surroundings, objects, or characters
    # - move: Move in a direction
    # - directions: Shortcut commands for cardinal directions (n, s, e, w, etc.)
    #
    class Plugin < Firefly::Plugin
      name :navigation
      version '1.0.0'
      description 'Movement and observation commands for exploring the world'

      # No dependencies for this core plugin
      commands_path 'commands'

      def self.on_enable
        puts "[Navigation] Navigation commands enabled"
      end

      def self.on_disable
        puts "[Navigation] Navigation commands disabled"
      end

      # Event handlers for room transitions
      on_event :character_enters_room do |character_instance, room, from_direction|
        # Could trigger room description display
      end

      on_event :character_leaves_room do |character_instance, room, direction|
        # Could notify other characters in the room
      end
    end
  end
end
