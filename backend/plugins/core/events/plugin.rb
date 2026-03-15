# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Events
    # Events plugin provides event management commands.
    #
    # Commands:
    # - bounce: Remove a character from your event (host/staff only)
    #
    class Plugin < Firefly::Plugin
      name :events
      version '1.0.0'
      description 'Event management commands for hosts and organizers'

      commands_path 'commands'

      def self.on_enable
        puts "[Events] Event commands enabled"
      end

      def self.on_disable
        puts "[Events] Event commands disabled"
      end
    end
  end
end
