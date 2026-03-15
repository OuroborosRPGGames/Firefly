# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Dice
    # Dice plugin provides rolling commands for stat-based checks and custom dice.
    #
    # Commands:
    # - roll: Roll 2d8 with exploding 8s using character stats
    # - diceroll: Roll custom dice (e.g., 2d6, 1d20)
    #
    class Plugin < Firefly::Plugin
      name :dice
      version '1.0.0'
      description 'Stat-based rolling and custom dice commands'

      commands_path 'commands'

      def self.on_enable
        puts "[Dice] Dice commands enabled"
      end

      def self.on_disable
        puts "[Dice] Dice commands disabled"
      end
    end
  end
end
