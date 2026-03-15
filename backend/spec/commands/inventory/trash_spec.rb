# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::Trash, type: :command do
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

    context 'with a valid item in inventory' do
      let!(:sword) do
        Item.create(
          name: 'Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end

      it 'destroys the item' do
        item_id = sword.id
        result = command.execute('trash sword')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Sword')
        expect(result[:message]).to include('gone forever')
        expect(Item[item_id]).to be_nil
      end

      it 'returns trash data' do
        result = command.execute('trash sword')

        expect(result[:data][:action]).to eq('trash')
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
        item_id = item.id
        result = command.execute('trash magi')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Magic Staff')
        expect(Item[item_id]).to be_nil
      end

      it 'matches first item with short ambiguous prefix' do
        # Add another item starting with "ma" to make the short prefix ambiguous
        Item.create(
          name: 'Maple Bow',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )

        result = command.execute('trash ma')

        # Short prefix matches the first item found
        expect(result[:success]).to be true
      end
    end

    context 'with money item' do
      let!(:money_item) do
        Item.create(
          name: 'G100',
          character_instance: character_instance,
          quantity: 100,
          condition: 'good',
          properties: { 'is_currency' => true, 'currency_id' => currency.id }
        )
      end

      it 'prevents trashing money' do
        result = command.execute('trash G100')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/can't trash money/i)
        expect(Item[money_item.id]).not_to be_nil
      end
    end

    context 'with empty input' do
      it 'returns error' do
        result = command.execute('trash')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/trash what/i)
      end

      it 'returns error for whitespace only' do
        result = command.execute('trash   ')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/trash what/i)
      end
    end

    context 'with item not in inventory' do
      it 'returns error' do
        result = command.execute('trash sword')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have/i)
      end
    end

    context 'with held item' do
      let!(:torch) do
        Item.create(
          name: 'Torch',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          held: true
        )
      end

      it 'can trash held items' do
        item_id = torch.id
        result = command.execute('trash torch')

        expect(result[:success]).to be true
        expect(Item[item_id]).to be_nil
      end
    end

    context 'with aliases' do
      let!(:item) do
        Item.create(name: 'Broken Sword', character_instance: character_instance, quantity: 1, condition: 'poor')
      end

      it 'works with destroy alias' do
        item_id = item.id
        result = command.execute('destroy broken sword')

        expect(result[:success]).to be true
        expect(Item[item_id]).to be_nil
      end

      it 'works with junk alias' do
        item_id = item.id
        result = command.execute('junk broken sword')

        expect(result[:success]).to be true
        expect(Item[item_id]).to be_nil
      end
    end
  end
end
