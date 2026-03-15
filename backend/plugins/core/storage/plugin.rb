# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Storage
    class Plugin < Firefly::Plugin
      name :storage
      version '1.0.0'
      description 'Storage and library commands for storing items and saving configurations'

      commands_path 'commands'

      def self.on_enable
        puts '[Storage] Storage and library commands enabled'
      end

      def self.on_disable
        puts '[Storage] Storage commands disabled'
      end
    end
  end
end
