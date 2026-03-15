# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::Pocket, type: :command do
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

    context 'with a held item' do
      let!(:sword) do
        Item.create(
          name: 'Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          held: true
        )
      end

      it 'pockets the item' do
        result = command.execute('pocket sword')

        expect(result[:success]).to be true
        expect(result[:message]).to include('put')
        expect(result[:message]).to include('Sword')
        expect(sword.reload.held).to be false
      end

      it 'returns pocket data' do
        result = command.execute('pocket sword')

        expect(result[:data][:action]).to eq('pocket')
        expect(result[:data][:item_name]).to eq('Sword')
      end
    end

    context 'with fuzzy matching' do
      let!(:item) do
        Item.create(
          name: 'Magic Staff',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          held: true
        )
      end

      it 'matches 4+ character prefix' do
        result = command.execute('pocket magi')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Magic Staff')
      end

      it 'matches short prefix' do
        result = command.execute('pocket mag')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Magic Staff')
      end
    end

    context 'with item not held' do
      let!(:shield) do
        Item.create(
          name: 'Shield',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          held: false
        )
      end

      it 'returns error' do
        result = command.execute('pocket shield')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/aren't holding/i)
      end
    end

    context 'with pocket all' do
      let!(:sword) do
        Item.create(name: 'Sword', character_instance: character_instance, quantity: 1, condition: 'good', held: true)
      end
      let!(:shield) do
        Item.create(name: 'Shield', character_instance: character_instance, quantity: 1, condition: 'good', held: true)
      end
      let!(:not_held) do
        Item.create(name: 'Ring', character_instance: character_instance, quantity: 1, condition: 'good', held: false)
      end

      it 'pockets all held items' do
        result = command.execute('pocket all')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Sword')
        expect(result[:message]).to include('Shield')
        expect(sword.reload.held).to be false
        expect(shield.reload.held).to be false
      end

      it 'returns pocket_all action' do
        result = command.execute('pocket all')

        expect(result[:data][:action]).to eq('pocket_all')
        expect(result[:data][:items]).to contain_exactly('Sword', 'Shield')
      end

      it 'returns error when nothing is held' do
        sword.update(held: false)
        shield.update(held: false)

        result = command.execute('pocket all')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/aren't holding anything/i)
      end
    end

    context 'with empty input' do
      it 'returns error when not holding anything' do
        result = command.execute('pocket')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/aren't holding anything/i)
      end

      it 'returns error for whitespace only when not holding anything' do
        result = command.execute('pocket   ')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/aren't holding anything/i)
      end

      context 'with held items' do
        let!(:item) { Item.create(name: 'Sword', character_instance: character_instance, quantity: 1, condition: 'good', held: true) }

        it 'shows item selection menu' do
          result = command.execute('pocket')

          expect(result[:success]).to be true
          expect(result[:type]).to eq(:quickmenu)
        end
      end
    end

    context 'with item not in inventory' do
      it 'returns error' do
        result = command.execute('pocket sword')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/aren't holding/i)
      end
    end

    context 'with aliases' do
      let!(:item) do
        Item.create(name: 'Dagger', character_instance: character_instance, quantity: 1, condition: 'good', held: true)
      end

      it 'works with stow alias' do
        result = command.execute('stow dagger')

        expect(result[:success]).to be true
        expect(item.reload.held).to be false
      end

      it 'works with stash alias' do
        item.update(held: true)
        result = command.execute('stash dagger')

        expect(result[:success]).to be true
        expect(item.reload.held).to be false
      end
    end
  end
end
