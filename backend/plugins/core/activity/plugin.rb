# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Activity
    # Activity plugin provides mission, competition, and task commands.
    #
    # Commands:
    # - activity: Manage activities (list, start, join, leave, status)
    # - ready: Mark yourself as ready in an activity
    #
    class Plugin < Firefly::Plugin
      name :activity
      version '1.0.0'
      description 'Collaborative and competitive group activities'

      commands_path 'commands'

      def self.on_enable
        puts '[Activity] Activity commands enabled'
      end

      def self.on_disable
        puts '[Activity] Activity commands disabled'
      end

      # Event handlers for activity state changes
      on_event :activity_started do |instance, room|
        # Notifies room of activity starting
      end

      on_event :activity_round_complete do |instance, result|
        # Processes round completion
      end

      on_event :activity_complete do |instance, success|
        # Handles activity completion
      end
    end
  end
end
