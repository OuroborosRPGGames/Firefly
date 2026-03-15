# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Status
    # Status plugin provides presence and availability commands.
    #
    # Commands:
    # - afk: Set away from keyboard status with optional timer
    # - gtg: Set "got to go" status with timer
    # - semiafk: Toggle semi-away status
    #
    class Plugin < Firefly::Plugin
      name :status
      version '1.0.0'
      description 'Presence and availability status commands'

      commands_path 'commands'

      def self.on_enable
        puts "[Status] Status commands enabled"
      end

      def self.on_disable
        puts "[Status] Status commands disabled"
      end
    end
  end
end
