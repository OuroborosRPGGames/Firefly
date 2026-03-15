# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Customization
    class Plugin < Firefly::Plugin
      name :customization
      version '1.0.0'
      description 'Character customization commands for profiles, handles, and appearance'

      commands_path 'commands'

      def self.on_enable
        puts '[Customization] Character customization commands enabled'
      end

      def self.on_disable
        puts '[Customization] Customization commands disabled'
      end
    end
  end
end
