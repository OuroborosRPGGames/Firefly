# frozen_string_literal: true

# Wallet tracks money on a character's person for a specific currency.
# Characters can have multiple wallets for different currencies.
class Wallet < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character_instance
  many_to_one :currency

  def validate
    super
    validates_presence [:character_instance_id, :currency_id]
    validates_unique [:character_instance_id, :currency_id]
    validates_numeric :balance
    errors.add(:balance, 'must be non-negative') if balance && balance < 0
  end

  def before_save
    super
    self.balance ||= 0
  end

  def add(amount)
    return false if amount < 0
    update(balance: balance + amount)
    true
  end

  def remove(amount)
    return false if amount < 0 || amount > balance
    update(balance: balance - amount)
    true
  end

  def transfer_to(other_wallet, amount)
    return false unless currency_id == other_wallet.currency_id
    return false unless remove(amount)
    other_wallet.add(amount)
    true
  end

  def formatted_balance
    currency.format_amount(balance)
  end

  def empty?
    balance.zero?
  end
end
