# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Economy::Deposit, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, room_type: 'shop') }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  let(:currency) do
    Currency.create(
      universe: universe,
      name: 'Gold',
      symbol: 'G',
      decimal_places: 0,
      is_primary: true
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with bank access (shop with banking)' do
      # Shop with cash_shop=false provides bank access
      let!(:shop) { Shop.create(room: room, name: 'Bank & Store', cash_shop: false) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 100
        )
      end

      it 'deposits money successfully' do
        result = command.execute('deposit 50')

        expect(result[:success]).to be true
        expect(result[:message]).to include('G50')
        expect(wallet.reload.balance).to eq(50)
      end

      it 'creates bank account if needed' do
        expect(BankAccount.where(character_id: character.id).count).to eq(0)

        result = command.execute('deposit 50')

        expect(result[:success]).to be true
        bank = BankAccount.first(character_id: character.id, currency_id: currency.id)
        expect(bank).not_to be_nil
        expect(bank.balance).to eq(50)
      end

      it 'deposits all with "all" keyword' do
        result = command.execute('deposit all')

        expect(result[:success]).to be true
        expect(wallet.reload.balance).to eq(0)
        bank = BankAccount.first(character_id: character.id, currency_id: currency.id)
        expect(bank.balance).to eq(100)
      end

      it 'returns deposit data in result' do
        result = command.execute('deposit 50')

        expect(result[:data][:action]).to eq('deposit')
        expect(result[:data][:amount]).to eq(50)
        expect(result[:data][:new_wallet_balance]).to eq(50)
      end
    end

    context 'without bank access' do
      let(:standard_room) { create(:room, location: location, room_type: 'standard') }
      let(:no_bank_instance) { create(:character_instance, character: character, current_room: standard_room, reality: reality, online: true) }

      subject(:no_bank_command) { described_class.new(no_bank_instance) }

      it 'returns error' do
        result = no_bank_command.execute('deposit 50')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/bank or ATM/i)
      end
    end

    context 'with cash-only shop (no banking)' do
      let!(:cash_shop) { Shop.create(room: room, name: 'Cash Only', cash_shop: true) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 100
        )
      end

      it 'returns error' do
        result = command.execute('deposit 50')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/bank or ATM/i)
      end
    end

    context 'with minimum amount enforcement' do
      let!(:shop) { Shop.create(room: room, name: 'Bank', cash_shop: false) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 100
        )
      end

      it 'rejects deposits below minimum' do
        result = command.execute('deposit 3')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/minimum deposit/i)
      end
    end

    context 'with insufficient funds' do
      let!(:shop) { Shop.create(room: room, name: 'Bank', cash_shop: false) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 10
        )
      end

      it 'returns error when amount exceeds wallet' do
        result = command.execute('deposit 50')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have that much/i)
      end
    end

    context 'with no wallet' do
      let!(:shop) { Shop.create(room: room, name: 'Bank', cash_shop: false) }

      before { currency }

      it 'returns error' do
        result = command.execute('deposit 50')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have any money/i)
      end
    end

    context 'with invalid input' do
      let!(:shop) { Shop.create(room: room, name: 'Bank', cash_shop: false) }
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 100
        )
      end

      it 'returns error for empty input' do
        result = command.execute('deposit')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/deposit how much/i)
      end

      it 'returns error for non-numeric input' do
        result = command.execute('deposit abc')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/invalid amount/i)
      end
    end
  end
end
