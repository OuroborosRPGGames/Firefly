# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clothing::Expose, type: :command do
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

    context 'with no argument' do
      it 'returns error' do
        result = command.execute('expose')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/expose what/i)
      end
    end

    context 'with valid concealed item' do
      let!(:shirt) do
        Item.create(
          name: 'Hidden Dagger',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true,
          concealed: true
        )
      end

      it 'exposes the item' do
        result = command.execute('expose dagger')

        expect(result[:success]).to be true
        expect(result[:message]).to include('expose')
        expect(result[:message]).to include('Hidden Dagger')
        expect(shirt.reload.concealed).to be false
      end

      it 'returns expose data' do
        result = command.execute('expose dagger')

        expect(result[:data][:action]).to eq('expose')
        expect(result[:data][:item_name]).to eq('Hidden Dagger')
      end
    end

    context 'with already visible item' do
      let!(:visible_item) do
        Item.create(
          name: 'Visible Shirt',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true,
          concealed: false
        )
      end

      it 'returns error' do
        result = command.execute('expose shirt')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/already visible|not concealed/i)
      end
    end

    context 'with non-worn item' do
      let!(:inventory_item) do
        Item.create(
          name: 'Unworn Hat',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: false,
          concealed: true
        )
      end

      it 'returns error' do
        result = command.execute('expose hat')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/not wearing/i)
      end
    end

    context 'with non-existent item' do
      it 'returns error' do
        result = command.execute('expose nonexistent')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/not wearing/i)
      end
    end

    context 'with multiple items' do
      let!(:dagger) do
        Item.create(
          name: 'Hidden Dagger',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true,
          concealed: true
        )
      end

      let!(:badge) do
        Item.create(
          name: 'Police Badge',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true,
          concealed: true
        )
      end

      let!(:weapon) do
        Item.create(
          name: 'Concealed Weapon',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true,
          concealed: true
        )
      end

      it 'exposes multiple comma-separated items' do
        result = command.execute('expose dagger, badge, weapon')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Hidden Dagger')
        expect(result[:message]).to include('Police Badge')
        expect(result[:message]).to include('Concealed Weapon')
        expect(dagger.reload.concealed).to be false
        expect(badge.reload.concealed).to be false
        expect(weapon.reload.concealed).to be false
      end

      it 'exposes multiple and-separated items' do
        result = command.execute('expose dagger and badge')

        expect(result[:success]).to be true
        expect(dagger.reload.concealed).to be false
        expect(badge.reload.concealed).to be false
      end

      it 'returns data with all items' do
        result = command.execute('expose dagger, badge')

        expect(result[:data][:action]).to eq('expose')
        expect(result[:data][:items]).to contain_exactly('Hidden Dagger', 'Police Badge')
      end

      it 'handles partial failures gracefully' do
        badge.update(concealed: false) # Already visible

        result = command.execute('expose dagger, badge, weapon')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Hidden Dagger')
        expect(result[:message]).to include('Concealed Weapon')
        expect(result[:message]).to include('Could not expose')
        expect(result[:message]).to include('already visible')
        expect(dagger.reload.concealed).to be false
        expect(weapon.reload.concealed).to be false
      end
    end
  end
end
