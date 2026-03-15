# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clothing::Cover, type: :command do
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
        result = command.execute('cover')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/cover what/i)
      end
    end

    context 'with valid visible item' do
      let!(:shirt) do
        Item.create(
          name: 'Red Shirt',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true,
          concealed: false
        )
      end

      it 'covers the item' do
        result = command.execute('cover shirt')

        expect(result[:success]).to be true
        expect(result[:message]).to include('cover')
        expect(result[:message]).to include('Red Shirt')
        expect(shirt.reload.concealed).to be true
      end

      it 'returns cover data' do
        result = command.execute('cover shirt')

        expect(result[:data][:action]).to eq('cover')
        expect(result[:data][:item_name]).to eq('Red Shirt')
      end
    end

    context 'with already concealed item' do
      let!(:hidden_item) do
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

      it 'returns error' do
        result = command.execute('cover dagger')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/already concealed|already covered/i)
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
          concealed: false
        )
      end

      it 'returns error' do
        result = command.execute('cover hat')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/not wearing/i)
      end
    end

    context 'with non-existent item' do
      it 'returns error' do
        result = command.execute('cover nonexistent')

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
          concealed: false
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
          concealed: false
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
          concealed: false
        )
      end

      it 'covers multiple comma-separated items' do
        result = command.execute('cover dagger, badge, weapon')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Hidden Dagger')
        expect(result[:message]).to include('Police Badge')
        expect(result[:message]).to include('Concealed Weapon')
        expect(dagger.reload.concealed).to be true
        expect(badge.reload.concealed).to be true
        expect(weapon.reload.concealed).to be true
      end

      it 'covers multiple and-separated items' do
        result = command.execute('cover dagger and badge')

        expect(result[:success]).to be true
        expect(dagger.reload.concealed).to be true
        expect(badge.reload.concealed).to be true
      end

      it 'returns data with all items' do
        result = command.execute('cover dagger, badge')

        expect(result[:data][:action]).to eq('cover')
        expect(result[:data][:items]).to contain_exactly('Hidden Dagger', 'Police Badge')
      end

      it 'handles partial failures gracefully' do
        badge.update(concealed: true) # Already concealed

        result = command.execute('cover dagger, badge, weapon')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Hidden Dagger')
        expect(result[:message]).to include('Concealed Weapon')
        expect(result[:message]).to include('Could not cover')
        expect(result[:message]).to include('already concealed')
        expect(dagger.reload.concealed).to be true
        expect(weapon.reload.concealed).to be true
      end
    end
  end
end
