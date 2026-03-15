# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Timeline
    # Timeline plugin provides snapshot and time travel commands.
    #
    # Commands:
    # - snapshot: Create a snapshot of your character to return to later
    # - timeline: Manage and enter different timelines
    #
    class Plugin < Firefly::Plugin
      name :timeline
      version '1.0.0'
      description 'Snapshot and time travel commands for historical roleplay'

      commands_path 'commands'

      def self.on_enable
        puts "[Timeline] Timeline commands enabled"
      end

      def self.on_disable
        puts "[Timeline] Timeline commands disabled"
      end
    end
  end
end
