# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::Get, type: :command do
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

    context 'with a valid item in the room' do
      let!(:item) do
        Item.create(
          name: 'Sword',
          room: room,
          quantity: 1,
          condition: 'good'
        )
      end

      it 'picks up the item' do
        result = command.execute('get sword')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Sword')
        expect(item.reload.character_instance_id).to eq(character_instance.id)
        expect(item.reload.room_id).to be_nil
      end

      it 'returns item data in result' do
        result = command.execute('get sword')

        expect(result[:data][:action]).to eq('get')
        expect(result[:data][:item_name]).to eq('Sword')
      end
    end

    context 'with fuzzy matching' do
      let!(:item) do
        Item.create(
          name: 'Magic Staff',
          room: room,
          quantity: 1,
          condition: 'good'
        )
      end

      it 'matches 4+ character prefix' do
        result = command.execute('get magi')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Magic Staff')
      end

      it 'matches short prefix' do
        result = command.execute('get mag')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Magic Staff')
      end
    end

    context 'with money in the room' do
      let!(:money_item) do
        Item.create(
          name: 'G100',
          room: room,
          quantity: 100,
          condition: 'good',
          properties: { 'is_currency' => true, 'currency_id' => currency.id }
        )
      end

      it 'picks up all money with "get money"' do
        result = command.execute('get money')

        expect(result[:success]).to be true
        expect(result[:message]).to include('G100')
        expect(result[:data][:action]).to eq('get_money')
        expect(result[:data][:amount]).to eq(100)
      end

      it 'picks up specific amount' do
        result = command.execute('get 50')

        expect(result[:success]).to be true
        expect(result[:data][:amount]).to eq(50)
        expect(money_item.reload.quantity).to eq(50)
      end

      it 'returns error when requesting more than available' do
        result = command.execute('get 200')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/only.*100/i)
      end
    end

    context 'with non-default currency in the room' do
      let(:silver_currency) do
        Currency.create(
          universe: universe,
          name: 'Silver',
          symbol: 'S',
          decimal_places: 0,
          is_primary: false
        )
      end

      let!(:money_item) do
        silver_currency
        Item.create(
          name: 'S80',
          room: room,
          quantity: 80,
          condition: 'good',
          properties: { 'is_currency' => true, 'currency_id' => silver_currency.id }
        )
      end

      it 'credits the wallet for the pile currency, not default currency' do
        result = command.execute('get money')

        expect(result[:success]).to be true
        expect(result[:data][:currency]).to eq('Silver')
        expect(result[:data][:amount]).to eq(80)

        silver_wallet = Wallet.first(character_instance_id: character_instance.id, currency_id: silver_currency.id)
        gold_wallet = Wallet.first(character_instance_id: character_instance.id, currency_id: currency.id)

        expect(silver_wallet).not_to be_nil
        expect(silver_wallet.balance).to eq(80)
        expect(gold_wallet).to be_nil
      end
    end

    context 'with get all' do
      let!(:sword) do
        Item.create(name: 'Sword', room: room, quantity: 1, condition: 'good')
      end
      let!(:shield) do
        Item.create(name: 'Shield', room: room, quantity: 1, condition: 'good')
      end

      it 'picks up all items' do
        result = command.execute('get all')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Sword')
        expect(result[:message]).to include('Shield')
        expect(result[:data][:action]).to eq('get_all')
      end

      it 'does not pick up money items' do
        Item.create(
          name: 'G50',
          room: room,
          quantity: 50,
          condition: 'good',
          properties: { 'is_currency' => true, 'currency_id' => currency.id }
        )

        result = command.execute('get all')

        expect(result[:success]).to be true
        expect(result[:data][:items]).to contain_exactly('Sword', 'Shield')
      end
    end

    context 'with empty input' do
      it 'returns error when nothing to pick up' do
        result = command.execute('get')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/nothing here to pick up/i)
      end

      it 'returns error for whitespace only when nothing to pick up' do
        result = command.execute('get   ')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/nothing here to pick up/i)
      end
    end

    context 'with item not in room' do
      it 'returns error' do
        result = command.execute('get sword')

        expect(result[:success]).to be false
        # Empty room returns "nothing here to pick up" message
        expect(result[:error]).to match(/nothing here to pick up/i)
      end
    end

    context 'with empty room for get all' do
      it 'returns error' do
        result = command.execute('get all')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/nothing here/i)
      end
    end

    context 'with no money in room' do
      it 'returns error for get money' do
        result = command.execute('get money')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/no money/i)
      end
    end

    context 'with aliases' do
      let!(:item) do
        Item.create(name: 'Potion', room: room, quantity: 1, condition: 'good')
      end

      it 'works with take alias' do
        result = command.execute('take potion')

        expect(result[:success]).to be true
      end

      it 'works with pickup alias' do
        result = command.execute('pickup potion')

        expect(result[:success]).to be true
      end

      it 'works with grab alias' do
        result = command.execute('grab potion')

        expect(result[:success]).to be true
      end
    end
  end
end
