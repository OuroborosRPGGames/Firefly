# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Inventory
    # Inventory plugin provides item manipulation commands: get, drop, give.
    #
    # This is a core plugin that enables item and money handling in the game.
    # It includes:
    # - Get: Pick up items or money from the room
    # - Drop: Drop items or money to the room
    # - Give: Give items or money to another character
    #
    class Plugin < Firefly::Plugin
      name :inventory
      version '1.0.0'
      description 'Item manipulation commands: get, drop, give'

      commands_path 'commands'

      def self.on_enable
        puts "[Inventory] Inventory commands enabled"
      end

      def self.on_disable
        puts "[Inventory] Inventory commands disabled"
      end
    end
  end
end
