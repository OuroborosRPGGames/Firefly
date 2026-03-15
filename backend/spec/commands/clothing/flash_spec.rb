# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Clothing::Flash, type: :command do
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
        result = command.execute('flash')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/flash what/i)
      end
    end

    context 'with valid concealed item' do
      let!(:shirt) do
        Item.create(
          name: 'Hidden Badge',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          is_clothing: true,
          worn: true,
          concealed: true
        )
      end

      it 'flashes the item' do
        result = command.execute('flash badge')

        expect(result[:success]).to be true
        expect(result[:message]).to include('flash')
        expect(result[:message]).to include('Hidden Badge')
      end

      it 'item remains concealed after flash' do
        command.execute('flash badge')

        # Flash is a quick reveal then re-conceal - item stays concealed
        expect(shirt.reload.concealed).to be true
      end

      it 'returns flash data' do
        result = command.execute('flash badge')

        expect(result[:data][:action]).to eq('flash')
        expect(result[:data][:item_name]).to eq('Hidden Badge')
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

      it 'returns error about item being visible' do
        result = command.execute('flash shirt')

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
        result = command.execute('flash hat')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/not wearing/i)
      end
    end

    context 'with non-existent item' do
      it 'returns error' do
        result = command.execute('flash nonexistent')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/not wearing/i)
      end
    end
  end
end
