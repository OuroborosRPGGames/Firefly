# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::Hidedesc, type: :command do
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

    context 'with a valid item' do
      let!(:ring) do
        Item.create(
          name: 'Silver Ring',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          desc_hidden: false
        )
      end

      it 'hides the description' do
        result = command.execute('hidedesc silver ring')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Silver Ring')
        expect(result[:message]).to include('hide')
        expect(ring.reload.desc_hidden).to be true
      end

      it 'returns hidedesc data' do
        result = command.execute('hidedesc silver ring')

        expect(result[:data][:action]).to eq('hidedesc')
        expect(result[:data][:item_name]).to eq('Silver Ring')
      end
    end

    context 'with item already hidden' do
      let!(:ring) do
        Item.create(
          name: 'Silver Ring',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          desc_hidden: true
        )
      end

      it 'returns error' do
        result = command.execute('hidedesc silver ring')

        expect(result[:success]).to be false
        expect(result[:error]).to include('already')
      end
    end

    context 'with fuzzy matching' do
      let!(:item) do
        Item.create(
          name: 'Diamond Necklace',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end

      it 'matches 3+ character prefix' do
        result = command.execute('hidedesc dia')

        expect(result[:success]).to be true
        expect(item.reload.desc_hidden).to be true
      end
    end

    context 'with empty input' do
      it 'returns error' do
        result = command.execute('hidedesc')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/hide.*what/i)
      end
    end

    context 'with item not owned' do
      it 'returns error' do
        result = command.execute('hidedesc sword')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have/i)
      end
    end

    context 'with worn item' do
      let!(:shirt) do
        Item.create(
          name: 'Shirt',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          worn: true
        )
      end

      it 'can hide worn item descriptions' do
        result = command.execute('hidedesc shirt')

        expect(result[:success]).to be true
        expect(shirt.reload.desc_hidden).to be true
      end
    end

    context 'with aliases' do
      let!(:item) do
        Item.create(name: 'Gold Coin', character_instance: character_instance, quantity: 1, condition: 'good')
      end

      it 'works with hide description alias' do
        command_class, _words = Commands::Base::Registry.find_command('hide description')
        expect(command_class).to eq(Commands::Inventory::Hidedesc)
      end
    end
  end
end
