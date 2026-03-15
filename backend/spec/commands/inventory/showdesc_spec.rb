# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::Showdesc, type: :command do
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

    context 'with a hidden item' do
      let!(:ring) do
        Item.create(
          name: 'Silver Ring',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          desc_hidden: true
        )
      end

      it 'shows the description' do
        result = command.execute('showdesc silver ring')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Silver Ring')
        expect(result[:message]).to include('reveal')
        expect(ring.reload.desc_hidden).to be false
      end

      it 'returns showdesc data' do
        result = command.execute('showdesc silver ring')

        expect(result[:data][:action]).to eq('showdesc')
        expect(result[:data][:item_name]).to eq('Silver Ring')
      end
    end

    context 'with item already visible' do
      let!(:ring) do
        Item.create(
          name: 'Silver Ring',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          desc_hidden: false
        )
      end

      it 'returns error' do
        result = command.execute('showdesc silver ring')

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
          condition: 'good',
          desc_hidden: true
        )
      end

      it 'matches 3+ character prefix' do
        result = command.execute('showdesc dia')

        expect(result[:success]).to be true
        expect(item.reload.desc_hidden).to be false
      end
    end

    context 'with empty input' do
      it 'returns error' do
        result = command.execute('showdesc')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/show.*what/i)
      end
    end

    context 'with item not owned' do
      it 'returns error' do
        result = command.execute('showdesc sword')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have/i)
      end
    end

    context 'with aliases' do
      let!(:item) do
        Item.create(name: 'Gold Coin', character_instance: character_instance, quantity: 1, condition: 'good', desc_hidden: true)
      end

      it 'works with show description alias' do
        command_class, _words = Commands::Base::Registry.find_command('show description')
        expect(command_class).to eq(Commands::Inventory::Showdesc)
      end
    end
  end
end
