# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Entertainment
    class Plugin < Firefly::Plugin
      name :entertainment
      version '1.0.0'
      description 'Media playback commands for playing videos and audio'

      commands_path 'commands'

      def self.on_enable
        puts '[Entertainment] Entertainment plugin enabled (media playback)'
      end

      def self.on_disable
        puts '[Entertainment] Entertainment plugin disabled'
      end
    end
  end
end
