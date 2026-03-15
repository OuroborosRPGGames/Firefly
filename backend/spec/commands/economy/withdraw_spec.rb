# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Economy::Withdraw, type: :command do
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

    context 'with bank access and funds' do
      let!(:shop) { Shop.create(room: room, name: 'Bank', cash_shop: false) }
      let!(:bank_account) do
        BankAccount.create(
          character: character,
          currency: currency,
          balance: 100
        )
      end

      it 'withdraws money successfully' do
        result = command.execute('withdraw 50')

        expect(result[:success]).to be true
        expect(result[:message]).to include('G50')
        expect(bank_account.reload.balance).to eq(50)
      end

      it 'creates wallet if needed' do
        expect(Wallet.where(character_instance_id: character_instance.id).count).to eq(0)

        result = command.execute('withdraw 50')

        expect(result[:success]).to be true
        wallet = Wallet.first(character_instance_id: character_instance.id, currency_id: currency.id)
        expect(wallet).not_to be_nil
        expect(wallet.balance).to eq(50)
      end

      it 'withdraws all with "all" keyword' do
        result = command.execute('withdraw all')

        expect(result[:success]).to be true
        expect(bank_account.reload.balance).to eq(0)
        wallet = Wallet.first(character_instance_id: character_instance.id, currency_id: currency.id)
        expect(wallet.balance).to eq(100)
      end

      it 'returns withdraw data in result' do
        result = command.execute('withdraw 50')

        expect(result[:data][:action]).to eq('withdraw')
        expect(result[:data][:amount]).to eq(50)
        expect(result[:data][:new_bank_balance]).to eq(50)
      end
    end

    context 'without bank access' do
      let(:standard_room) { create(:room, location: location, room_type: 'standard') }
      let(:no_bank_instance) { create(:character_instance, character: character, current_room: standard_room, reality: reality, online: true) }

      subject(:no_bank_command) { described_class.new(no_bank_instance) }

      it 'returns error' do
        result = no_bank_command.execute('withdraw 50')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/bank or ATM/i)
      end
    end

    context 'with minimum amount enforcement' do
      let!(:shop) { Shop.create(room: room, name: 'Bank', cash_shop: false) }
      let!(:bank_account) do
        BankAccount.create(
          character: character,
          currency: currency,
          balance: 100
        )
      end

      it 'rejects withdrawals below minimum' do
        result = command.execute('withdraw 3')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/minimum withdrawal/i)
      end
    end

    context 'with insufficient funds' do
      let!(:shop) { Shop.create(room: room, name: 'Bank', cash_shop: false) }
      let!(:bank_account) do
        BankAccount.create(
          character: character,
          currency: currency,
          balance: 10
        )
      end

      it 'returns error when amount exceeds bank balance' do
        result = command.execute('withdraw 50')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have that much/i)
      end
    end

    context 'with no bank account' do
      let!(:shop) { Shop.create(room: room, name: 'Bank', cash_shop: false) }

      before { currency }

      it 'returns error' do
        result = command.execute('withdraw 50')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have a bank account/i)
      end
    end

    context 'with empty bank account' do
      let!(:shop) { Shop.create(room: room, name: 'Bank', cash_shop: false) }
      let!(:bank_account) do
        BankAccount.create(
          character: character,
          currency: currency,
          balance: 0
        )
      end

      it 'returns error' do
        result = command.execute('withdraw 50')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/bank account is empty/i)
      end
    end

    context 'with invalid input' do
      let!(:shop) { Shop.create(room: room, name: 'Bank', cash_shop: false) }
      let!(:bank_account) do
        BankAccount.create(
          character: character,
          currency: currency,
          balance: 100
        )
      end

      it 'returns error for empty input' do
        result = command.execute('withdraw')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/withdraw how much/i)
      end

      it 'returns error for non-numeric input' do
        result = command.execute('withdraw abc')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/invalid amount/i)
      end
    end
  end
end
