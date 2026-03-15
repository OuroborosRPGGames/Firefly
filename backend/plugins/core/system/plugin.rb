# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module System
    # System plugin provides utility commands for game interface.
    #
    # Commands:
    # - commands: List all available commands
    # - help: Get help on commands and topics
    #
    class Plugin < Firefly::Plugin
      name :system
      version '1.0.0'
      description 'Utility commands for help and command listing'

      # No dependencies for this core plugin
      commands_path 'commands'

      def self.on_enable
        puts "[System] System commands enabled"
      end

      def self.on_disable
        puts "[System] System commands disabled"
      end
    end
  end
end
