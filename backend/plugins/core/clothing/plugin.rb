# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Clothing
    # Clothing plugin provides clothing and appearance management commands.
    #
    # This is a core plugin that enables wearing, removing, and managing outfits.
    # It includes:
    # - Wear: Put on clothing items from inventory
    # - Remove: Take off worn clothing items
    # - Strip: Remove all worn clothing
    # - Outfit: Manage saved outfits
    # - Expose/Cover: Reveal or conceal clothing items
    #
    class Plugin < Firefly::Plugin
      name :clothing
      version '1.0.0'
      description 'Clothing and appearance management commands'

      commands_path 'commands'

      def self.on_enable
        puts "[Clothing] Clothing commands enabled"
      end

      def self.on_disable
        puts "[Clothing] Clothing commands disabled"
      end
    end
  end
end
