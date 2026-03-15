# frozen_string_literal: true

require_relative '../../../../app/helpers/banking_access_helper'

module Commands
  module Economy
    class Deposit < Commands::Base::Command
      include BankingAccessHelper

      command_name 'deposit'
      aliases 'dep'
      category :economy
      help_text 'Deposit cash into your bank account'
      usage 'deposit <amount> | deposit all'
      examples 'deposit 100', 'deposit all'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]
        return error_result("Deposit how much? (e.g., 'deposit 100' or 'deposit all')") if blank?(text)

        return error_result("You need to be at a bank or ATM to deposit money.") unless has_bank_access?

        currency = default_currency
        return error_result("No currency defined for this area.") unless currency

        wallet = wallet_for(currency)
        return error_result("You don't have any money to deposit.") unless wallet && wallet.balance > 0

        amount = parse_amount(text.strip, wallet.balance)
        return error_result("Invalid amount. Use a number or 'all'.") unless amount
        return error_result("You don't have that much money.") if amount > wallet.balance
        return error_result("Minimum deposit is #{currency.format_amount(MINIMUM_TRANSACTION_AMOUNT)}.") if amount < MINIMUM_TRANSACTION_AMOUNT

        bank_account = find_or_create_bank_account(character_instance.character, currency)
        return error_result("Unable to access bank account.") unless bank_account

        return error_result("Deposit failed.") unless wallet.remove(amount)
        return error_result("Deposit failed.") unless bank_account.deposit(amount)

        formatted_amount = currency.format_amount(amount)

        broadcast_to_room(
          "#{character_instance.character.full_name} deposits some cash.",
          exclude_character: character_instance
        )

        success_result(
          "You deposit #{formatted_amount}. Bank balance: #{bank_account.formatted_balance}",
          type: :message,
          data: {
            action: 'deposit',
            amount: amount,
            currency: currency.name,
            new_bank_balance: bank_account.balance,
            new_wallet_balance: wallet.balance
          }
        )
      end

      # Note: has_bank_access?, default_currency, parse_amount, find_or_create_bank_account
      # come from BankingAccessHelper
    end
  end
end

Commands::Base::Registry.register(Commands::Economy::Deposit)
