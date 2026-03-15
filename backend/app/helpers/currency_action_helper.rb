# frozen_string_literal: true

# Helper for standardized currency/money actions (drop money, get money, give money)
# Reduces duplication across economy commands
module CurrencyActionHelper
  # Drop money from wallet to room floor
  # @param amount_text [String] Amount to drop (e.g., "100")
  # @return [Hash] Success or error result
  def drop_money(amount_text)
    amount = amount_text.to_i
    return error_result("Invalid amount.") if amount <= 0

    currency = default_currency
    return error_result("No currency defined.") unless currency

    wallet = wallet_for(currency)
    return error_result("You don't have any money.") unless wallet
    return error_result("You don't have that much money.") if wallet.balance < amount

    # Remove from wallet
    wallet.remove(amount)

    # Find existing money item in room or create new one
    money_item = find_money_in_room(currency)
    if money_item
      money_item.update(quantity: money_item.quantity + amount)
    else
      create_money_item(amount, currency)
    end

    formatted = currency.format_amount(amount)
    broadcast_to_room(
      "#{character.full_name} drops #{formatted}.",
      exclude_character: character_instance
    )

    success_result(
      "You drop #{formatted}.",
      type: :message,
      data: { action: 'drop_money', amount: amount, currency: currency.name }
    )
  end

  # Pick up money from room floor to wallet
  # @param amount_text [String] Amount or keyword ("money", "cash", "coins", or number)
  # @return [Hash] Success or error result
  def money_pickup(amount_text)
    money_item = find_money_in_room
    return error_result("There's no money here.") unless money_item

    props = money_item.properties || {}
    currency_id = props['currency_id'].to_i
    currency = currency_id.positive? ? Currency[currency_id] : default_currency
    return error_result("No currency defined.") unless currency

    # Determine amount to pick up
    if amount_text.match?(/^\d+$/)
      amount = amount_text.to_i
      if amount > money_item.quantity
        return error_result("There's only #{currency.format_amount(money_item.quantity)} here.")
      end
    else
      # "money", "cash", "coins" - take all
      amount = money_item.quantity
    end

    # Get or create wallet for this currency
    wallet = find_or_create_wallet(currency)

    # Transfer money from item to wallet
    wallet.add(amount)

    # Update or delete money item
    if amount >= money_item.quantity
      money_item.destroy
    else
      money_item.update(quantity: money_item.quantity - amount)
    end

    formatted = currency.format_amount(amount)
    broadcast_to_room(
      "#{character.full_name} picks up #{formatted}.",
      exclude_character: character_instance
    )

    success_result(
      "You pick up #{formatted}.",
      type: :message,
      data: { action: 'get_money', amount: amount, currency: currency.name }
    )
  end

  # Give money from wallet to another character's wallet
  # @param target_instance [CharacterInstance] The recipient
  # @param amount_text [String] Amount to give
  # @return [Hash] Success or error result
  def give_money(target_instance, amount_text)
    amount = amount_text.to_i
    return error_result("Invalid amount.") if amount <= 0

    currency = default_currency
    return error_result("No currency defined.") unless currency

    wallet = wallet_for(currency)
    return error_result("You don't have any money.") unless wallet
    return error_result("You don't have that much money.") if wallet.balance < amount

    # Get or create recipient's wallet
    target_wallet = find_or_create_wallet_for(target_instance, currency)

    # Transfer
    wallet.remove(amount)
    target_wallet.add(amount)

    formatted = currency.format_amount(amount)
    target_name = target_instance.character.full_name

    # Notify target (use personalized name - target may not know giver's real name)
    giver_name = character.display_name_for(target_instance)
    send_to_character(
      target_instance,
      "#{giver_name} gives you #{formatted}."
    )

    broadcast_to_room(
      "#{character.full_name} gives #{target_name} some money.",
      exclude_character: character_instance
    )

    success_result(
      "You give #{target_name} #{formatted}.",
      type: :message,
      data: { action: 'give_money', amount: amount, currency: currency.name, target: target_name }
    )
  end

  private

  # Create a money item on the ground
  def create_money_item(amount, currency)
    Item.create(
      name: currency.format_amount(amount),
      room: location,
      quantity: amount,
      properties: { 'is_currency' => true, 'currency_id' => currency.id }
    )
  end

  # Get or create wallet for a specific character instance
  def find_or_create_wallet_for(char_instance, currency)
    wallet = char_instance.wallets_dataset.first(currency_id: currency.id)
    return wallet if wallet

    Wallet.create(
      character_instance: char_instance,
      currency: currency,
      balance: 0
    )
  end
end
