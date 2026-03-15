# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Info
    # Info plugin provides character status and information commands.
    #
    # Commands:
    # - who: List online players in area/room
    # - observe: Focus on a character for continuous updates
    # - profile: View character profile information
    # - score: View own character statistics
    # - finger: Get detailed information about a character
    #
    class Plugin < Firefly::Plugin
      name :info
      version '1.0.0'
      description 'Character status and information commands'

      commands_path 'commands'

      def self.on_enable
        puts "[Info] Character info commands enabled"
      end

      def self.on_disable
        puts "[Info] Character info commands disabled"
      end
    end
  end
end
