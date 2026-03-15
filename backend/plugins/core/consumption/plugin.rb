# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Consumption
    class Plugin < Firefly::Plugin
      name :consumption
      version '1.0.0'
      description 'Food, drink, and substance consumption commands'

      commands_path 'commands'

      def self.on_enable
        puts '[Consumption] Consumption commands enabled (eat, drink, smoke)'
      end

      def self.on_disable
        puts '[Consumption] Consumption plugin disabled'
      end
    end
  end
end
