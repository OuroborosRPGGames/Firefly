# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Wallet do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }
  let(:currency) { create(:currency, universe: universe) }
  let(:wallet) { create(:wallet, character_instance: character_instance, currency: currency) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(wallet).to be_valid
    end

    it 'requires character_instance_id' do
      wallet = build(:wallet, character_instance: nil, currency: currency)
      expect(wallet).not_to be_valid
    end

    it 'requires currency_id' do
      wallet = build(:wallet, character_instance: character_instance, currency: nil)
      expect(wallet).not_to be_valid
    end

    it 'validates uniqueness of currency per character_instance' do
      create(:wallet, character_instance: character_instance, currency: currency)
      duplicate = build(:wallet, character_instance: character_instance, currency: currency)
      expect(duplicate).not_to be_valid
    end

    it 'does not allow negative balance' do
      wallet = build(:wallet, character_instance: character_instance, currency: currency, balance: -100)
      expect(wallet).not_to be_valid
      expect(wallet.errors[:balance]).to include('must be non-negative')
    end
  end

  describe 'associations' do
    it 'belongs to character_instance' do
      expect(wallet.character_instance).to eq(character_instance)
    end

    it 'belongs to currency' do
      expect(wallet.currency).to eq(currency)
    end
  end

  describe 'before_save callbacks' do
    it 'sets balance to 0 by default' do
      new_currency = create(:currency, universe: universe)
      wallet = Wallet.new(character_instance_id: character_instance.id, currency_id: new_currency.id, balance: 0)
      wallet.save
      expect(wallet.balance).to eq(0)
    end
  end

  describe '#add' do
    it 'adds to balance' do
      initial_balance = wallet.balance
      expect(wallet.add(50)).to be true
      expect(wallet.reload.balance).to eq(initial_balance + 50)
    end

    it 'returns false for negative amount' do
      expect(wallet.add(-10)).to be false
    end
  end

  describe '#remove' do
    it 'removes from balance' do
      wallet.update(balance: 100)
      expect(wallet.remove(30)).to be true
      expect(wallet.reload.balance).to eq(70)
    end

    it 'returns false if amount exceeds balance' do
      wallet.update(balance: 50)
      expect(wallet.remove(100)).to be false
      expect(wallet.reload.balance).to eq(50)
    end

    it 'returns false for negative amount' do
      expect(wallet.remove(-10)).to be false
    end
  end

  describe '#transfer_to' do
    let(:other_instance) { create(:character_instance, character: create(:character), current_room: room, reality: reality) }
    let(:other_wallet) { create(:wallet, character_instance: other_instance, currency: currency, balance: 50) }

    it 'transfers amount to another wallet' do
      wallet.update(balance: 100)
      expect(wallet.transfer_to(other_wallet, 30)).to be true
      expect(wallet.reload.balance).to eq(70)
      expect(other_wallet.reload.balance).to eq(80)
    end

    it 'returns false for different currencies' do
      other_currency = create(:currency, universe: universe)
      different_wallet = create(:wallet, character_instance: other_instance, currency: other_currency)
      expect(wallet.transfer_to(different_wallet, 10)).to be false
    end

    it 'returns false if insufficient funds' do
      wallet.update(balance: 10)
      expect(wallet.transfer_to(other_wallet, 100)).to be false
    end
  end

  describe '#formatted_balance' do
    it 'delegates to currency format_amount' do
      wallet.update(balance: 1050)
      currency.update(symbol: '$', decimal_places: 2)
      expect(wallet.formatted_balance).to eq('$10.50')
    end
  end

  describe '#empty?' do
    it 'returns true when balance is zero' do
      wallet.update(balance: 0)
      expect(wallet.empty?).to be true
    end

    it 'returns false when balance is positive' do
      wallet.update(balance: 100)
      expect(wallet.empty?).to be false
    end
  end
end
