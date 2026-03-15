# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Economy::Balance, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
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

  subject(:command) { described_class.new(character_instance) }

  describe 'command metadata' do
    it 'has correct name' do
      expect(described_class.command_name).to eq('balance')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:economy)
    end

    it 'has aliases' do
      expect(described_class.alias_names).to include('bal', 'money', 'cash', 'wallet')
    end
  end

  describe '#execute' do
    context 'with no wallet or bank accounts' do
      it 'returns success' do
        result = command.execute('')
        expect(result[:success]).to be true
      end

      it 'shows empty wallet message' do
        result = command.execute('')
        expect(result[:message]).to include('Wallet: Empty')
      end

      it 'shows no bank accounts message' do
        result = command.execute('')
        expect(result[:message]).to include('Bank: No accounts')
      end

      it 'returns status type' do
        result = command.execute('')
        expect(result[:type]).to eq(:status)
      end
    end

    context 'with wallet funds' do
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 150
        )
      end

      it 'shows wallet balance' do
        result = command.execute('')
        expect(result[:message]).to include('Wallet (Cash):')
        expect(result[:message]).to include('Gold')
        expect(result[:message]).to include('150')
      end

      it 'returns wallet data' do
        result = command.execute('')
        expect(result[:data][:wallets]).to be_an(Array)
        expect(result[:data][:wallets].first[:currency]).to eq('Gold')
        expect(result[:data][:wallets].first[:balance]).to eq(150)
      end
    end

    context 'with bank accounts' do
      let!(:bank_account) do
        BankAccount.create(
          character: character,
          currency: currency,
          balance: 5000
        )
      end

      it 'shows bank balance' do
        result = command.execute('')
        expect(result[:message]).to include('Bank Accounts:')
        expect(result[:message]).to include('Gold')
        expect(result[:message]).to include('5000')
      end

      it 'returns bank account data' do
        result = command.execute('')
        expect(result[:data][:bank_accounts]).to be_an(Array)
        expect(result[:data][:bank_accounts].first[:currency]).to eq('Gold')
        expect(result[:data][:bank_accounts].first[:balance]).to eq(5000)
      end
    end

    context 'with both wallet and bank' do
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 100
        )
      end

      let!(:bank_account) do
        BankAccount.create(
          character: character,
          currency: currency,
          balance: 400
        )
      end

      it 'shows total' do
        result = command.execute('')
        expect(result[:message]).to include('Total:')
        expect(result[:message]).to include('500')
      end

      it 'shows both sections' do
        result = command.execute('')
        expect(result[:message]).to include('Wallet (Cash):')
        expect(result[:message]).to include('Bank Accounts:')
      end
    end

    context 'with multiple currencies' do
      let(:other_currency) do
        Currency.create(
          universe: universe,
          name: 'Silver',
          symbol: 'S',
          decimal_places: 0,
          is_primary: false
        )
      end

      let!(:gold_wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 100
        )
      end

      let!(:silver_wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: other_currency,
          balance: 250
        )
      end

      it 'shows both currencies' do
        result = command.execute('')
        expect(result[:message]).to include('Gold')
        expect(result[:message]).to include('Silver')
      end

      it 'returns multiple wallet entries' do
        result = command.execute('')
        expect(result[:data][:wallets].length).to eq(2)
      end
    end
  end
end
