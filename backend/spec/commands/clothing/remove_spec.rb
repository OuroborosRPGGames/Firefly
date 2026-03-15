# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clothing::Remove, type: :command do
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

    context 'with a worn clothing item' do
      let!(:shirt) do
        Item.create(
          name: 'Blue Shirt',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true
        )
      end

      it 'removes the item' do
        result = command.execute('remove blue shirt')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Blue Shirt')
        expect(shirt.reload.worn).to be false
      end

      it 'returns remove data' do
        result = command.execute('remove blue shirt')

        expect(result[:data][:action]).to eq('remove')
        expect(result[:data][:item_name]).to eq('Blue Shirt')
      end
    end

    context 'with worn jewelry' do
      let!(:ring) do
        Item.create(
          name: 'Gold Ring',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_jewelry: true,
          worn: true
        )
      end

      it 'removes the jewelry' do
        result = command.execute('remove gold ring')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Gold Ring')
        expect(ring.reload.worn).to be false
      end
    end

    context 'with fuzzy matching' do
      let!(:item) do
        Item.create(
          name: 'Leather Jacket',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true
        )
      end

      it 'matches 4+ character prefix' do
        result = command.execute('remove leat')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Leather Jacket')
      end

      it 'matches short prefix' do
        result = command.execute('remove le')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Leather Jacket')
      end
    end

    context 'with item not worn' do
      let!(:dress) do
        Item.create(
          name: 'Red Dress',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: false
        )
      end

      it 'returns error when not wearing' do
        result = command.execute('remove red dress')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/not wearing/i)
      end
    end

    context 'with empty input' do
      it 'returns error when not wearing anything' do
        result = command.execute('remove')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/not wearing anything/i)
      end

      it 'returns error for whitespace only when not wearing anything' do
        result = command.execute('remove   ')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/not wearing anything/i)
      end
    end

    context 'with item not in possession' do
      it 'returns error' do
        result = command.execute('remove shirt')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/not wearing/i)
      end
    end

    context 'with aliases' do
      let!(:item) do
        Item.create(
          name: 'Wool Coat',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true
        )
      end

      it 'works with doff alias' do
        result = command.execute('doff wool coat')

        expect(result[:success]).to be true
        expect(item.reload.worn).to be false
      end

      # Note: Multi-word aliases like "take off" are handled by the Registry,
      # which transforms "take off X" to "remove X" before calling execute.
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
          worn: true
        )
      end

      let!(:scarf) do
        Item.create(
          name: 'Red Scarf',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true
        )
      end

      let!(:gloves) do
        Item.create(
          name: 'Leather Gloves',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true
        )
      end

      it 'removes multiple comma-separated items' do
        result = command.execute('remove hat, scarf, gloves')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Wool Hat')
        expect(result[:message]).to include('Red Scarf')
        expect(result[:message]).to include('Leather Gloves')
        expect(hat.reload.worn).to be false
        expect(scarf.reload.worn).to be false
        expect(gloves.reload.worn).to be false
      end

      it 'removes multiple and-separated items' do
        result = command.execute('remove hat and scarf')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Wool Hat')
        expect(result[:message]).to include('Red Scarf')
        expect(hat.reload.worn).to be false
        expect(scarf.reload.worn).to be false
      end

      it 'removes mixed comma and and-separated items' do
        result = command.execute('remove hat, scarf, and gloves')

        expect(result[:success]).to be true
        expect(hat.reload.worn).to be false
        expect(scarf.reload.worn).to be false
        expect(gloves.reload.worn).to be false
      end

      it 'returns data with all items' do
        result = command.execute('remove hat, scarf')

        expect(result[:data][:action]).to eq('remove')
        expect(result[:data][:items]).to contain_exactly('Wool Hat', 'Red Scarf')
        expect(result[:data][:item_ids]).to contain_exactly(hat.id, scarf.id)
      end

      it 'handles partial failures gracefully' do
        result = command.execute('remove hat, nonexistent, scarf')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Wool Hat')
        expect(result[:message]).to include('Red Scarf')
        expect(result[:message]).to include('Could not process')
        expect(hat.reload.worn).to be false
        expect(scarf.reload.worn).to be false
      end

      it 'fails when all items not found' do
        result = command.execute('remove nonexistent, alsonotfound')

        expect(result[:success]).to be false
        expect(result[:error]).to include("not wearing")
      end
    end
  end
end
