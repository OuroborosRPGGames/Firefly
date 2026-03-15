# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Communication
    # Communication plugin provides say, whisper, emote, and channel commands.
    #
    # This is a core plugin that enables character communication in the game.
    # It includes:
    # - Say: Speak to everyone in the room
    # - Emote: Perform actions visible to everyone in the room
    # - Whisper: Private messages (planned)
    # - Channels: Global/regional chat channels (planned)
    #
    class Plugin < Firefly::Plugin
      name :communication
      version '1.0.0'
      description 'Say, whisper, emote, and channel commands for character communication'

      # No dependencies for this core plugin
      # depends_on :core

      # Configure paths (these are defaults, shown here for clarity)
      commands_path 'commands'

      # Called when the plugin is enabled
      def self.on_enable
        puts "[Communication] Communication commands enabled"
        # Commands are auto-discovered from the commands/ directory
      end

      # Called when the plugin is disabled
      def self.on_disable
        puts "[Communication] Communication commands disabled"
        # Could unregister commands here if needed
      end

      # Event handlers
      on_event :character_enters_room do |character_instance, room|
        # Could broadcast arrival messages here
      end

      on_event :character_leaves_room do |character_instance, room, direction|
        # Could broadcast departure messages here
      end
    end
  end
end
