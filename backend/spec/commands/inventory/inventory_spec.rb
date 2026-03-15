# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::InventoryCmd, type: :command do
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

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with empty inventory' do
      it 'shows empty message' do
        result = command.execute('inventory')

        expect(result[:success]).to be true
        expect(result[:message]).to include("aren't carrying anything")
      end
    end

    context 'with items in inventory' do
      let!(:sword) do
        Item.create(
          name: 'Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end
      let!(:shield) do
        Item.create(
          name: 'Shield',
          character_instance: character_instance,
          quantity: 1,
          condition: 'fair'
        )
      end

      it 'lists all items' do
        result = command.execute('inventory')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Sword')
        expect(result[:message]).to include('Shield')
      end

      it 'shows condition if not good' do
        result = command.execute('inventory')

        expect(result[:message]).to include('(fair)')
      end

      it 'returns correct data' do
        result = command.execute('inventory')

        expect(result[:data][:action]).to eq('inventory')
        expect(result[:data][:item_count]).to eq(2)
      end
    end

    context 'with held items' do
      let!(:torch) do
        Item.create(
          name: 'Torch',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          held: true
        )
      end
      let!(:sword) do
        Item.create(
          name: 'Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          held: false
        )
      end

      it 'separates held items' do
        result = command.execute('inventory')

        expect(result[:success]).to be true
        expect(result[:message]).to include('In Hand')
        expect(result[:message]).to include('Torch')
        expect(result[:message]).to include('Carrying')
        expect(result[:message]).to include('Sword')
      end

      it 'counts held items separately' do
        result = command.execute('inventory')

        expect(result[:data][:held_count]).to eq(1)
      end
    end

    context 'with worn items' do
      let!(:robe) do
        Item.create(
          name: 'Robe',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          worn: true
        )
      end

      it 'excludes worn items from inventory' do
        result = command.execute('inventory')

        expect(result[:success]).to be true
        expect(result[:message]).not_to include('Wearing')
        expect(result[:message]).not_to include('Robe')
      end
    end

    context 'with stored items' do
      let!(:stored_item) do
        Item.create(
          name: 'Stored Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          stored: true
        )
      end

      it 'excludes stored items from inventory output' do
        result = command.execute('inventory')

        expect(result[:success]).to be true
        expect(result[:message]).not_to include('Stored Sword')
      end
    end

    context 'with wallet' do
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 100
        )
      end

      it 'shows wallet balance' do
        result = command.execute('inventory')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Wallet')
        expect(result[:message]).to include('G100')
      end

      it 'counts wallets' do
        result = command.execute('inventory')

        expect(result[:data][:wallet_count]).to eq(1)
      end
    end

    context 'with multiple quantities' do
      let!(:arrow) do
        Item.create(
          name: 'Arrow',
          character_instance: character_instance,
          quantity: 20,
          condition: 'good'
        )
      end

      it 'shows quantity' do
        result = command.execute('inventory')

        expect(result[:message]).to include('(20) Arrow')
      end
    end

    context 'with damaged items' do
      let!(:broken_sword) do
        Item.create(
          name: 'Broken Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          torn: 5
        )
      end

      it 'shows damage level' do
        result = command.execute('inventory')

        expect(result[:message]).to include('damaged')
      end
    end

    context 'with aliases' do
      let!(:item) do
        Item.create(name: 'Potion', character_instance: character_instance, quantity: 1, condition: 'good')
      end

      it 'works with inv alias' do
        result = command.execute('inv')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Potion')
      end

      it 'works with i alias' do
        result = command.execute('i')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Potion')
      end
    end
  end
end
