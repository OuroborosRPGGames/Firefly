# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Combat
    # Combat plugin provides fighting and combat-related commands.
    #
    # Commands:
    # - attack: Attack a target (requires combat state)
    #
    # This plugin demonstrates conditional command availability.
    #
    class Plugin < Firefly::Plugin
      name :combat
      version '1.0.0'
      description 'Combat system with attack commands and battle mechanics'

      commands_path 'commands'

      def self.on_enable
        puts "[Combat] Combat commands enabled"
      end

      def self.on_disable
        puts "[Combat] Combat commands disabled"
      end

      # Combat event handlers
      on_event :combat_started do |attacker, defender|
        # Initialize combat state
      end

      on_event :combat_ended do |winner, loser|
        # Clean up combat state
      end
    end
  end
end
