# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::Drop, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  # Create currency for money tests
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

    context 'with a valid item in inventory' do
      let!(:item) do
        Item.create(
          name: 'Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end

      it 'drops the item to the room' do
        result = command.execute('drop sword')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Sword')
        expect(item.reload.room_id).to eq(room.id)
        expect(item.reload.character_instance_id).to be_nil
      end

      it 'returns item data in result' do
        result = command.execute('drop sword')

        expect(result[:data][:action]).to eq('drop')
        expect(result[:data][:item_name]).to eq('Sword')
      end
    end

    context 'with fuzzy matching' do
      let!(:item) do
        Item.create(
          name: 'Magic Staff',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end

      it 'matches 4+ character prefix' do
        result = command.execute('drop magi')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Magic Staff')
      end

      it 'matches short prefix' do
        result = command.execute('drop mag')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Magic Staff')
      end
    end

    context 'with money in wallet' do
      let!(:wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 100
        )
      end

      it 'drops money to create money item on ground' do
        result = command.execute('drop 50')

        expect(result[:success]).to be true
        expect(result[:message]).to include('G50')
        expect(wallet.reload.balance).to eq(50)

        # Check money item was created
        money_item = Item.first(room_id: room.id)
        expect(money_item).not_to be_nil
        expect(money_item.properties['is_currency']).to be true
        expect(money_item.quantity).to eq(50)
      end

      it 'adds to existing money pile on ground' do
        # Create existing money item
        Item.create(
          name: 'G50',
          room: room,
          quantity: 50,
          condition: 'good',
          properties: { 'is_currency' => true, 'currency_id' => currency.id }
        )

        result = command.execute('drop 25')

        expect(result[:success]).to be true
        money_items = Item.where(room_id: room.id).all
        expect(money_items.count).to eq(1)
        expect(money_items.first.quantity).to eq(75)
      end

      it 'returns error when dropping more than wallet balance' do
        result = command.execute('drop 200')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have that much/i)
      end
    end

    context 'with drop all' do
      let!(:sword) do
        Item.create(name: 'Sword', character_instance: character_instance, quantity: 1, condition: 'good')
      end
      let!(:shield) do
        Item.create(name: 'Shield', character_instance: character_instance, quantity: 1, condition: 'good')
      end

      it 'drops all items' do
        result = command.execute('drop all')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Sword')
        expect(result[:message]).to include('Shield')
        expect(result[:data][:action]).to eq('drop_all')
      end

      it 'returns error when inventory is empty' do
        sword.destroy
        shield.destroy

        result = command.execute('drop all')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/aren't carrying/i)
      end
    end

    context 'with empty input' do
      it 'returns error when not carrying anything' do
        result = command.execute('drop')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/aren't carrying anything/i)
      end

      it 'returns error for whitespace only when not carrying anything' do
        result = command.execute('drop   ')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/aren't carrying anything/i)
      end
    end

    context 'with item not in inventory' do
      it 'returns error' do
        result = command.execute('drop sword')

        expect(result[:success]).to be false
        # Empty inventory returns "aren't carrying anything" message
        expect(result[:error]).to match(/aren't carrying anything/i)
      end
    end

    context 'with item in storage' do
      let!(:item) do
        Item.create(
          name: 'Stored Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          stored: true
        )
      end

      it 'does not allow dropping stored items' do
        result = command.execute('drop stored sword')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/aren't carrying anything|don't have/i)
      end
    end

    context 'with no money' do
      before { currency }  # Ensure currency exists

      it 'returns error when no wallet exists' do
        result = command.execute('drop 50')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have any money/i)
      end

      it 'returns error when wallet is empty' do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 0
        )

        result = command.execute('drop 50')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have that much/i)
      end
    end

    context 'with aliases' do
      let!(:item) do
        Item.create(name: 'Potion', character_instance: character_instance, quantity: 1, condition: 'good')
      end

      it 'works with discard alias' do
        result = command.execute('discard potion')

        expect(result[:success]).to be true
      end
    end
  end
end
