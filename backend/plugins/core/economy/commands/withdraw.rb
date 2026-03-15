# frozen_string_literal: true

require_relative '../../../../app/helpers/banking_access_helper'

module Commands
  module Economy
    class Withdraw < Commands::Base::Command
      include BankingAccessHelper

      command_name 'withdraw'
      aliases 'with'
      category :economy
      help_text 'Withdraw money from your bank account'
      usage 'withdraw <amount> | withdraw all'
      examples 'withdraw 100', 'withdraw all'

      protected

      def perform_command(parsed_input)
        text = parsed_input[:text]
        return error_result("Withdraw how much? (e.g., 'withdraw 100' or 'withdraw all')") if blank?(text)

        return error_result("You need to be at a bank or ATM to withdraw money.") unless has_bank_access?

        currency = default_currency
        return error_result("No currency defined for this area.") unless currency

        bank_account = bank_account_for(currency)
        return error_result("You don't have a bank account.") unless bank_account
        return error_result("Your bank account is empty.") if bank_account.balance <= 0

        amount = parse_amount(text.strip, bank_account.balance)
        return error_result("Invalid amount. Use a number or 'all'.") unless amount
        return error_result("You don't have that much in your account.") if amount > bank_account.balance
        return error_result("Minimum withdrawal is #{currency.format_amount(MINIMUM_TRANSACTION_AMOUNT)}.") if amount < MINIMUM_TRANSACTION_AMOUNT

        wallet = find_or_create_wallet(currency)
        return error_result("Unable to access wallet.") unless wallet

        return error_result("Withdrawal failed.") unless bank_account.withdraw(amount)
        return error_result("Withdrawal failed.") unless wallet.add(amount)

        formatted_amount = currency.format_amount(amount)

        broadcast_to_room(
          "#{character_instance.character.full_name} withdraws some cash.",
          exclude_character: character_instance
        )

        success_result(
          "You withdraw #{formatted_amount}. Cash on hand: #{wallet.formatted_balance}",
          type: :message,
          data: {
            action: 'withdraw',
            amount: amount,
            currency: currency.name,
            new_bank_balance: bank_account.balance,
            new_wallet_balance: wallet.balance
          }
        )
      end

      # Note: has_bank_access?, default_currency, parse_amount, find_or_create_wallet
      # come from BankingAccessHelper
    end
  end
end

Commands::Base::Registry.register(Commands::Economy::Withdraw)
