# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Posture
    # Posture plugin provides stance and position commands.
    #
    # Commands:
    # - sit: Sit down, optionally on furniture
    # - stand: Stand up from sitting or lying position
    # - lie: Lie down, optionally on furniture
    #
    class Plugin < Firefly::Plugin
      name :posture
      version '1.0.0'
      description 'Stance and position commands for character posture'

      commands_path 'commands'

      def self.on_enable
        puts "[Posture] Posture commands enabled"
      end

      def self.on_disable
        puts "[Posture] Posture commands disabled"
      end
    end
  end
end
