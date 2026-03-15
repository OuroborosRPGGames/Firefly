# frozen_string_literal: true

# Provides banking access helpers for economy commands.
#
# Consolidates the duplicate methods found in deposit, withdraw,
# and potentially other economy commands.
#
# Usage:
#   class MyCommand < Commands::Base::Command
#     include BankingAccessHelper
#
#     def perform_command(parsed_input)
#       return error_result("No bank access here.") unless has_bank_access?
#       currency = default_currency
#       amount = parse_amount("100", max_amount)
#     end
#   end
#
module BankingAccessHelper
  MINIMUM_TRANSACTION_AMOUNT = 5

  # Check if the current location provides bank access.
  # Bank access is available at:
  # - Physical banks (all eras)
  # - Shops with banking (modern+ eras, non-cash-only shops)
  # - ATMs (modern+ eras)
  #
  # @return [Boolean] true if banking operations can be performed
  def has_bank_access?
    banking_config = EraService.banking_config

    # Physical bank is always valid in any era
    return true if location.room_type == 'bank'

    # In medieval/gaslight eras, only physical banks work - no ATMs or shop banking
    if banking_config[:physical_only] && !banking_config[:atm_available]
      return false
    end

    # Check for shop with banking (not cash-only) - modern+ eras
    shop = location.shop
    return true if shop && !shop.cash_shop

    # ATMs only available in modern+ eras
    if banking_config[:atm_available]
      # Check for ATM in places
      if location.respond_to?(:places_dataset)
        return true if location.places_dataset.any? { |p| p.name&.downcase&.include?('atm') }
      end

      # Check for ATM in decorations
      if location.respond_to?(:decorations_dataset)
        return true if location.decorations_dataset.any? { |d| d.name&.downcase&.include?('atm') }
      end
    end

    false
  end

  # Get the default currency for the current location's universe.
  #
  # @return [Currency, nil] the default currency or nil if not found
  def default_currency
    universe = location.location.zone.world.universe
    Currency.default_for(universe)
  end

  # Parse an amount string into a numeric value.
  # Supports "all" to return the max_amount, or a numeric string.
  #
  # @param text [String] the amount text ("100", "all", etc.)
  # @param max_amount [Integer] the maximum amount available
  # @return [Integer, nil] the parsed amount or nil if invalid
  def parse_amount(text, max_amount)
    if text.downcase == 'all'
      max_amount
    elsif text.match?(/^\d+$/)
      text.to_i
    end
  end

  # Find or create a bank account for a character.
  #
  # @param char [Character] the character
  # @param currency [Currency] the currency for the account
  # @return [BankAccount, nil] the bank account or nil on failure
  def find_or_create_bank_account(char, currency)
    account = char.bank_accounts_dataset.first(currency_id: currency.id)
    return account if account

    BankAccount.create(
      character: char,
      currency: currency,
      balance: 0
    )
  rescue StandardError => e
    warn "Failed to create bank account: #{e.class} - #{e.message}"
    nil
  end

  # Find or create a wallet for the current character instance.
  #
  # @param currency [Currency] the currency for the wallet
  # @return [Wallet, nil] the wallet or nil on failure
  def find_or_create_wallet(currency)
    wallet = character_instance.wallets_dataset.first(currency_id: currency.id)
    return wallet if wallet

    Wallet.create(
      character_instance: character_instance,
      currency: currency,
      balance: 0
    )
  rescue StandardError => e
    warn "Failed to create wallet: #{e.class} - #{e.message}"
    nil
  end
end
