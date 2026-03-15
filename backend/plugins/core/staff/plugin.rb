# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Staff
    # Staff plugin provides commands for staff/GM NPC puppeteering.
    #
    # Commands:
    # - puppet: Take control of an NPC
    # - unpuppet: Release control of an NPC
    # - pemote: Make a puppeted NPC emote
    # - seed: Inject an instruction into an NPC for their next action
    # - puppets: List NPCs you are currently puppeting
    #
    class Plugin < Firefly::Plugin
      name :staff
      version '1.0.0'
      description 'Staff commands for NPC puppeteering and control'

      commands_path 'commands'

      def self.on_enable
        puts '[Staff] NPC puppeteering commands enabled'
      end

      def self.on_disable
        puts '[Staff] NPC puppeteering commands disabled'
      end
    end
  end
end
