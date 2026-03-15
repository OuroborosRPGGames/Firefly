# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Social
    # Social plugin provides commands for social interactions and privacy settings.
    #
    # This is a core plugin that enables social features in the game.
    # It includes:
    # - Private: Toggle private mode for adult content visibility
    #
    class Plugin < Firefly::Plugin
      name :social
      version '1.0.0'
      description 'Social interaction and privacy commands'

      # Configure paths
      commands_path 'commands'

      # Called when the plugin is enabled
      def self.on_enable
        puts "[Social] Social commands enabled"
      end

      # Called when the plugin is disabled
      def self.on_disable
        puts "[Social] Social commands disabled"
      end
    end
  end
end
