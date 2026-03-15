# frozen_string_literal: true

module Commands
  module Economy
    class Balance < Commands::Base::Command
      command_name 'balance'
      aliases 'bal', 'money', 'cash', 'wallet'
      category :economy
      output_category :info
      help_text 'Check your wallet and bank balance'
      usage 'balance'
      examples 'balance', 'bal', 'money'

      protected

      def perform_command(_parsed_input)
        lines = []
        lines << "<h3>Your Finances</h3>"
        lines << ""

        # Get all wallets (cash on hand)
        wallets = character_instance.wallets_dataset.all
        if wallets.any?
          lines << "Wallet (Cash):"
          wallets.each do |wallet|
            formatted = wallet.currency.format_amount(wallet.balance)
            lines << "  #{wallet.currency.name}: #{formatted}"
          end
          lines << ""
        else
          lines << "Wallet: Empty"
          lines << ""
        end

        # Get all bank accounts
        bank_accounts = character_instance.character.bank_accounts_dataset.all
        if bank_accounts.any?
          lines << "Bank Accounts:"
          bank_accounts.each do |account|
            formatted = account.currency.format_amount(account.balance)
            lines << "  #{account.currency.name}: #{formatted}"
          end
        else
          lines << "Bank: No accounts"
        end

        # Calculate total
        total_by_currency = {}
        wallets.each do |w|
          total_by_currency[w.currency_id] ||= { currency: w.currency, amount: 0 }
          total_by_currency[w.currency_id][:amount] += w.balance
        end
        bank_accounts.each do |a|
          total_by_currency[a.currency_id] ||= { currency: a.currency, amount: 0 }
          total_by_currency[a.currency_id][:amount] += a.balance
        end

        if total_by_currency.any?
          lines << ""
          lines << "Total:"
          total_by_currency.each do |_id, data|
            formatted = data[:currency].format_amount(data[:amount])
            lines << "  #{data[:currency].name}: #{formatted}"
          end
        end

        success_result(
          lines.join("\n"),
          type: :status,
          data: {
            action: 'balance',
            wallets: wallets.map { |w| { currency: w.currency.name, balance: w.balance } },
            bank_accounts: bank_accounts.map { |a| { currency: a.currency.name, balance: a.balance } }
          }
        )
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Economy::Balance)
