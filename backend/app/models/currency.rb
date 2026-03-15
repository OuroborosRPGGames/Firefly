# frozen_string_literal: true

# Currency defines a type of money in a universe.
# A universe can have multiple currencies (gold, credits, etc.)
class Currency < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :universe
  one_to_many :wallets
  one_to_many :bank_accounts

  def validate
    super
    validates_presence [:universe_id, :name, :symbol]
    validates_max_length 50, :name
    validates_max_length 10, :symbol
    validates_unique [:universe_id, :name]
  end

  def before_save
    super
    self.decimal_places ||= 2
    self.is_primary ||= false
  end

  def format_amount(amount)
    if decimal_places > 0
      "#{symbol}#{'%.2f' % (amount.to_f / (10**decimal_places))}"
    else
      "#{symbol}#{amount.to_i}"
    end
  end

  def self.default_for(universe)
    first(universe_id: universe.id, is_primary: true) || first(universe_id: universe.id)
  end
end
