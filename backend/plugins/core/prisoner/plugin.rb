# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Prisoner
    # Prisoner plugin provides restraint and captivity mechanics.
    #
    # Commands:
    # - helpless: Toggle voluntary helpless state
    # - wake: Wake an unconscious character
    # - tie: Bind a helpless character's hands or feet
    # - untie: Remove restraints from a character
    # - gag: Gag a helpless character
    # - blindfold: Blindfold a helpless character
    # - drag: Drag a helpless character
    # - carry: Pick up a helpless character
    # - drop: Put down a carried character
    # - release: Stop dragging someone
    # - search: Examine a helpless character's inventory
    #
    class Plugin < Firefly::Plugin
      name :prisoner
      version '1.0.0'
      description 'Restraint and captivity mechanics for prisoner roleplay'

      commands_path 'commands'

      def self.on_enable
        puts '[Prisoner] Prisoner/restraint commands enabled'
      end

      def self.on_disable
        puts '[Prisoner] Prisoner/restraint commands disabled'
      end
    end
  end
end
