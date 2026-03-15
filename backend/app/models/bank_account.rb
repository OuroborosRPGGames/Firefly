# frozen_string_literal: true

# BankAccount stores money safely for a character in a specific currency.
# Money in bank is protected from theft/loss.
class BankAccount < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character
  many_to_one :currency

  def validate
    super
    validates_presence [:character_id, :currency_id]
    validates_unique [:character_id, :currency_id]
    validates_numeric :balance, minimum: 0
  end

  def before_save
    super
    self.balance ||= 0
    self.account_name ||= generate_account_number
  end

  def deposit(amount)
    return false if amount < 0
    update(balance: balance + amount)
    true
  end

  def withdraw(amount)
    return false if amount < 0 || amount > balance
    update(balance: balance - amount)
    true
  end

  def transfer_to(other_account, amount)
    return false unless currency_id == other_account.currency_id
    return false unless withdraw(amount)
    other_account.deposit(amount)
    true
  end

  def formatted_balance
    currency.format_amount(balance)
  end

  private

  def generate_account_number
    # Account name is auto-generated using currency symbol prefix
    "#{currency.symbol.upcase}#{SecureRandom.hex(6).upcase}"
  end
end
