# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Clan
    # Clan plugin provides commands for managing clans/groups.
    #
    # Commands:
    # - clan: Main command for clan management (create, invite, kick, etc.)
    # - clanchat/cc: Quick shortcut for clan channel messaging
    #
    class Plugin < Firefly::Plugin
      name :clan
      version '1.0.0'
      description 'Clan/group management system with channels, memos, and room access'

      commands_path 'commands'

      def self.on_enable
        puts '[Clan] Clan management commands enabled'
      end

      def self.on_disable
        puts '[Clan] Clan management commands disabled'
      end
    end
  end
end
