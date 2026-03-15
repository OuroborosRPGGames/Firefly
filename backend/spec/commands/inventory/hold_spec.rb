# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::Hold, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with a valid item in inventory' do
      let!(:sword) do
        Item.create(
          name: 'Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          held: false
        )
      end

      it 'holds the item' do
        result = command.execute('hold sword')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Sword')
        expect(sword.reload.held).to be true
      end

      it 'returns hold data' do
        result = command.execute('hold sword')

        expect(result[:data][:action]).to eq('hold')
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
        result = command.execute('hold magi')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Magic Staff')
      end

      it 'matches short prefix' do
        result = command.execute('hold ma')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Magic Staff')
      end
    end

    context 'with already held item' do
      let!(:torch) do
        Item.create(
          name: 'Torch',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          held: true
        )
      end

      it 'returns error when already holding' do
        result = command.execute('hold torch')

        expect(result[:success]).to be false
        # Already-held items are excluded from holdable items, so error is "nothing to hold"
        expect(result[:error]).to match(/already holding|nothing to hold/i)
      end
    end

    context 'with empty input' do
      it 'returns error when nothing to hold' do
        result = command.execute('hold')

        expect(result[:success]).to be false
        # With no items in inventory, error says nothing to hold
        expect(result[:error]).to match(/nothing to hold/i)
      end

      it 'returns error for whitespace only when nothing to hold' do
        result = command.execute('hold   ')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/nothing to hold/i)
      end

      context 'with items in inventory' do
        let!(:item) { Item.create(name: 'Sword', character_instance: character_instance, quantity: 1, condition: 'good') }

        it 'shows item selection menu' do
          result = command.execute('hold')

          expect(result[:success]).to be true
          expect(result[:type]).to eq(:quickmenu)
        end
      end
    end

    context 'with item not in inventory' do
      it 'returns error' do
        result = command.execute('hold sword')

        expect(result[:success]).to be false
        # No items means "nothing to hold" rather than specific "don't have"
        expect(result[:error]).to match(/don't have|nothing to hold/i)
      end
    end

    context 'with aliases' do
      let!(:item) do
        Item.create(name: 'Dagger', character_instance: character_instance, quantity: 1, condition: 'good')
      end

      it 'works with wield alias' do
        result = command.execute('wield dagger')

        expect(result[:success]).to be true
        expect(item.reload.held).to be true
      end

      it 'works with brandish alias' do
        result = command.execute('brandish dagger')

        expect(result[:success]).to be true
        expect(item.reload.held).to be true
      end
    end
  end
end
