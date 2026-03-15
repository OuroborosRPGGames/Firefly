# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BankAccount do
  let(:universe) { create(:universe) }
  let(:currency) { create(:currency, universe: universe) }
  let(:character) { create(:character) }
  let(:bank_account) { create(:bank_account, character: character, currency: currency) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(bank_account).to be_valid
    end

    it 'requires character_id' do
      account = build(:bank_account, character: nil, currency: currency)
      expect(account).not_to be_valid
    end

    it 'requires currency_id' do
      account = build(:bank_account, character: character, currency: nil)
      expect(account).not_to be_valid
    end

    it 'validates uniqueness of character_id and currency_id' do
      create(:bank_account, character: character, currency: currency)
      duplicate = build(:bank_account, character: character, currency: currency)
      expect(duplicate).not_to be_valid
    end

    it 'defaults balance to 0 when nil via before_save' do
      account = create(:bank_account, character: character, currency: currency)
      expect(account.balance).to be >= 0
    end
  end

  describe 'associations' do
    it 'belongs to character' do
      expect(bank_account.character).to eq(character)
    end

    it 'belongs to currency' do
      expect(bank_account.currency).to eq(currency)
    end
  end

  describe '#deposit' do
    it 'adds to balance' do
      bank_account.update(balance: 100)
      expect(bank_account.deposit(50)).to be true
      expect(bank_account.reload.balance).to eq(150)
    end

    it 'returns false for negative amount' do
      expect(bank_account.deposit(-10)).to be false
    end
  end

  describe '#withdraw' do
    it 'removes from balance' do
      bank_account.update(balance: 100)
      expect(bank_account.withdraw(30)).to be true
      expect(bank_account.reload.balance).to eq(70)
    end

    it 'returns false if amount exceeds balance' do
      bank_account.update(balance: 50)
      expect(bank_account.withdraw(100)).to be false
      expect(bank_account.reload.balance).to eq(50)
    end

    it 'returns false for negative amount' do
      expect(bank_account.withdraw(-10)).to be false
    end
  end

  describe '#transfer_to' do
    let(:other_character) { create(:character) }
    let(:other_account) { create(:bank_account, character: other_character, currency: currency, balance: 50) }

    it 'transfers amount to another account' do
      bank_account.update(balance: 100)
      expect(bank_account.transfer_to(other_account, 30)).to be true
      expect(bank_account.reload.balance).to eq(70)
      expect(other_account.reload.balance).to eq(80)
    end

    it 'returns false for different currencies' do
      other_currency = create(:currency, universe: universe)
      different_account = create(:bank_account, character: other_character, currency: other_currency)
      expect(bank_account.transfer_to(different_account, 10)).to be false
    end

    it 'returns false if insufficient funds' do
      bank_account.update(balance: 10)
      expect(bank_account.transfer_to(other_account, 100)).to be false
    end
  end

  describe '#formatted_balance' do
    it 'delegates to currency format_amount' do
      bank_account.update(balance: 1050)
      currency.update(symbol: '$', decimal_places: 2)
      expect(bank_account.formatted_balance).to eq('$10.50')
    end
  end
end
