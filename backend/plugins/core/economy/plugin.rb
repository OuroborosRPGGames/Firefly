# frozen_string_literal: true

require_relative '../../../lib/firefly/plugin'

module Plugins
  module Economy
    # Economy plugin provides economic and shop commands.
    #
    # This is a core plugin that enables financial transactions in the game.
    # It includes:
    # - Buy: Purchase items from shops
    # - Deposit: Transfer cash to bank account
    # - Withdraw: Transfer money from bank to wallet
    # - Add Stock: Shop owners add items to inventory
    # - Remove Stock: Shop owners remove items from inventory
    #
    class Plugin < Firefly::Plugin
      name :economy
      version '1.0.0'
      description 'Economic and shop commands: buy, deposit, withdraw, stock management'

      commands_path 'commands'

      # Minimum amount for bank transactions
      MINIMUM_BANK_TRANSACTION = 5

      def self.on_enable
        puts "[Economy] Economy commands enabled"
      end

      def self.on_disable
        puts "[Economy] Economy commands disabled"
      end
    end
  end
end
