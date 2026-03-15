# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Vehicles
    # Vehicles plugin provides commands for vehicle interaction.
    #
    # Commands:
    # - open roof: Open a convertible vehicle's roof
    # - close roof: Close a convertible vehicle's roof
    #
    class Plugin < Firefly::Plugin
      name :vehicles
      version '1.0.0'
      description 'Commands for interacting with vehicles'

      commands_path 'commands'

      def self.on_enable
        puts "[Vehicles] Vehicle commands enabled"
      end

      def self.on_disable
        puts "[Vehicles] Vehicle commands disabled"
      end
    end
  end
end
