# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clothing::Wear, type: :command do
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

    context 'with a valid clothing item in inventory' do
      let!(:shirt) do
        Item.create(
          name: 'Blue Shirt',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: false
        )
      end

      it 'wears the item' do
        result = command.execute('wear blue shirt')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Blue Shirt')
        expect(shirt.reload.worn).to be true
      end

      it 'returns wear data' do
        result = command.execute('wear blue shirt')

        expect(result[:data][:action]).to eq('wear')
        expect(result[:data][:item_name]).to eq('Blue Shirt')
      end
    end

    context 'with a jewelry item' do
      let!(:ring) do
        Item.create(
          name: 'Gold Ring',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_jewelry: true,
          worn: false
        )
      end

      it 'wears the jewelry' do
        result = command.execute('wear gold ring')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Gold Ring')
        expect(ring.reload.worn).to be true
      end
    end

    context 'with fuzzy matching' do
      let!(:item) do
        Item.create(
          name: 'Leather Jacket',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true
        )
      end

      it 'matches 4+ character prefix' do
        result = command.execute('wear leat')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Leather Jacket')
      end

      it 'matches short prefix' do
        result = command.execute('wear lea')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Leather Jacket')
      end
    end

    context 'with already worn item' do
      let!(:dress) do
        Item.create(
          name: 'Red Dress',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true
        )
      end

      it 'returns error when already wearing' do
        result = command.execute('wear red dress')

        expect(result[:success]).to be false
        # Already worn items are filtered from candidates, so "nothing to wear" is correct
        expect(result[:error]).to match(/don't have anything to wear/i)
      end
    end

    context 'with non-wearable item' do
      let!(:sword) do
        Item.create(
          name: 'Steel Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: false,
          is_jewelry: false
        )
      end

      it 'returns error when trying to wear non-clothing' do
        result = command.execute('wear steel sword')

        expect(result[:success]).to be false
        # Non-wearable items are filtered from candidates, so "nothing to wear" is correct
        expect(result[:error]).to match(/don't have anything to wear/i)
      end
    end

    context 'with empty input' do
      it 'returns error when nothing to wear' do
        result = command.execute('wear')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have anything to wear/i)
      end

      it 'returns error for whitespace only when nothing to wear' do
        result = command.execute('wear   ')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have anything to wear/i)
      end
    end

    context 'with item not in inventory' do
      it 'returns error' do
        result = command.execute('wear shirt')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have/i)
      end
    end

    context 'with item in room (not inventory)' do
      let!(:pants) do
        Item.create(
          name: 'Black Pants',
          room: room,
          quantity: 1,
          condition: 'good',
          is_clothing: true
        )
      end

      it 'returns error for item not in inventory' do
        result = command.execute('wear black pants')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have/i)
      end
    end

    context 'with item in storage (not inventory)' do
      let!(:stored_shirt) do
        Item.create(
          name: 'Stored Shirt',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          stored: true,
          worn: false
        )
      end

      it 'returns error for item not in inventory' do
        result = command.execute('wear stored shirt')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have anything to wear/i)
        expect(stored_shirt.reload.worn).to be false
      end
    end

    context 'with aliases' do
      let!(:item) do
        Item.create(
          name: 'Wool Coat',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true
        )
      end

      it 'works with don alias' do
        result = command.execute('don wool coat')

        expect(result[:success]).to be true
        expect(item.reload.worn).to be true
      end

      # Note: Multi-word aliases like "put on" are handled by the Registry,
      # which transforms "put on X" to "wear X" before calling execute.
      # This is tested at the integration/registry level.
    end

    context 'with multiple items' do
      let!(:hat) do
        Item.create(
          name: 'Wool Hat',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: false
        )
      end

      let!(:scarf) do
        Item.create(
          name: 'Red Scarf',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: false
        )
      end

      let!(:gloves) do
        Item.create(
          name: 'Leather Gloves',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: false
        )
      end

      it 'wears multiple comma-separated items' do
        result = command.execute('wear hat, scarf, gloves')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Wool Hat')
        expect(result[:message]).to include('Red Scarf')
        expect(result[:message]).to include('Leather Gloves')
        expect(hat.reload.worn).to be true
        expect(scarf.reload.worn).to be true
        expect(gloves.reload.worn).to be true
      end

      it 'wears multiple and-separated items' do
        result = command.execute('wear hat and scarf')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Wool Hat')
        expect(result[:message]).to include('Red Scarf')
        expect(hat.reload.worn).to be true
        expect(scarf.reload.worn).to be true
      end

      it 'wears mixed comma and and-separated items' do
        result = command.execute('wear hat, scarf, and gloves')

        expect(result[:success]).to be true
        expect(hat.reload.worn).to be true
        expect(scarf.reload.worn).to be true
        expect(gloves.reload.worn).to be true
      end

      it 'returns data with all items' do
        result = command.execute('wear hat, scarf')

        expect(result[:data][:action]).to eq('wear')
        expect(result[:data][:items]).to contain_exactly('Wool Hat', 'Red Scarf')
        expect(result[:data][:item_ids]).to contain_exactly(hat.id, scarf.id)
      end

      it 'handles partial failures gracefully' do
        result = command.execute('wear hat, nonexistent, scarf')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Wool Hat')
        expect(result[:message]).to include('Red Scarf')
        expect(result[:message]).to include('Could not process')
        expect(hat.reload.worn).to be true
        expect(scarf.reload.worn).to be true
      end

      it 'fails when all items not found' do
        result = command.execute('wear nonexistent, alsonotfound')

        expect(result[:success]).to be false
        expect(result[:error]).to include("don't have")
      end
    end
  end
end
