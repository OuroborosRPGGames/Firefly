# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Building
    # Building plugin provides room customization commands.
    #
    # Commands:
    # - rename: Rename a room you own
    # - resize room: Change room dimensions
    # - set background: Set room background image
    # - windows: Toggle curtains
    # - graffiti: Write graffiti
    # - clean graffiti: Remove graffiti
    # - decorate: Add decoration
    # - redecorate: Replace decoration
    # - make home: Set room as home
    #
    class Plugin < Firefly::Plugin
      name :building
      version '1.0.0'
      description 'Room customization and building commands'

      commands_path 'commands'

      def self.on_enable
        puts '[Building] Building commands enabled'
      end

      def self.on_disable
        puts '[Building] Building commands disabled'
      end
    end
  end
end
