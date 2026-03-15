# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clothing::Strip, type: :command do
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

    context 'with strip all and worn items' do
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

      let!(:pants) do
        Item.create(
          name: 'Black Pants',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true
        )
      end

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

      it 'removes all worn items with strip all' do
        result = command.execute('strip all')

        expect(result[:success]).to be true
        expect(result[:message]).to include('strip')
        expect(shirt.reload.worn).to be false
        expect(pants.reload.worn).to be false
        expect(ring.reload.worn).to be false
      end

      it 'removes all worn items with strip naked' do
        result = command.execute('strip naked')

        expect(result[:success]).to be true
        expect(shirt.reload.worn).to be false
        expect(pants.reload.worn).to be false
        expect(ring.reload.worn).to be false
      end

      it 'lists all removed items' do
        result = command.execute('strip all')

        expect(result[:message]).to include('Blue Shirt')
        expect(result[:message]).to include('Black Pants')
        expect(result[:message]).to include('Gold Ring')
      end

      it 'returns strip data with all items' do
        result = command.execute('strip all')

        expect(result[:data][:action]).to eq('strip')
        expect(result[:data][:items]).to include('Blue Shirt')
        expect(result[:data][:items]).to include('Black Pants')
        expect(result[:data][:items]).to include('Gold Ring')
      end
    end

    context 'with undress alias' do
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

      it 'works with undress all' do
        result = command.execute('undress all')

        expect(result[:success]).to be true
        expect(shirt.reload.worn).to be false
      end
    end

    context 'with plain strip command (no argument)' do
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

      it 'shows usage help' do
        result = command.execute('strip')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/usage/i)
        expect(shirt.reload.worn).to be true  # Item not removed
      end
    end

    context 'with invalid argument' do
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

      it 'shows usage help' do
        result = command.execute('strip something')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/usage/i)
        expect(shirt.reload.worn).to be true  # Item not removed
      end
    end

    context 'with no worn items' do
      let!(:unworn_shirt) do
        Item.create(
          name: 'Blue Shirt',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: false
        )
      end

      it 'returns error' do
        result = command.execute('strip all')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/aren't wearing/i)
      end
    end

    context 'with no items at all' do
      it 'returns error' do
        result = command.execute('strip all')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/aren't wearing/i)
      end
    end

    context 'with mixed worn and unworn items' do
      let!(:worn_shirt) do
        Item.create(
          name: 'Blue Shirt',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true
        )
      end

      let!(:unworn_pants) do
        Item.create(
          name: 'Black Pants',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: false
        )
      end

      it 'only removes worn items' do
        result = command.execute('strip all')

        expect(result[:success]).to be true
        expect(worn_shirt.reload.worn).to be false
        expect(result[:data][:items]).to include('Blue Shirt')
        expect(result[:data][:items]).not_to include('Black Pants')
      end
    end
  end
end
