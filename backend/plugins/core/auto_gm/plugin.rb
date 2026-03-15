# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module AutoGm
    # Auto-GM plugin provides AI-driven spontaneous adventures.
    #
    # The Auto-GM system creates adventures based on:
    # - Current location context
    # - Nearby world memories
    # - Character backgrounds
    # - Discovered locations
    #
    # Commands:
    # - autogm start: Start a new spontaneous adventure
    # - autogm status: Check adventure progress
    # - autogm end: End the current adventure
    #
    class Plugin < Firefly::Plugin
      name :auto_gm
      version '1.0.0'
      description 'AI-driven spontaneous adventure system'

      commands_path 'commands'

      def self.on_enable
        puts '[AutoGM] Auto-GM commands enabled'
      end

      def self.on_disable
        puts '[AutoGM] Auto-GM commands disabled'
      end

    end
  end
end
