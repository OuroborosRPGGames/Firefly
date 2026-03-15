# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::Equipment, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no worn or held items' do
      it 'shows empty equipment message' do
        result = command.execute('equipment')

        expect(result[:success]).to be true
        expect(result[:message]).to include("aren't wearing or holding anything")
      end

      it 'returns structured data' do
        result = command.execute('equipment')

        expect(result[:data][:action]).to eq('equipment')
      end
    end

    context 'with worn items' do
      let!(:robe) do
        Item.create(
          name: 'Silk Robe',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          worn: true
        )
      end

      it 'lists worn items under Wearing section' do
        result = command.execute('equipment')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Wearing')
        expect(result[:message]).to include('Silk Robe')
      end

      it 'returns worn count in data' do
        result = command.execute('equipment')

        expect(result[:data][:worn_count]).to eq(1)
        expect(result[:data][:held_count]).to eq(0)
      end
    end

    context 'with held items' do
      let!(:sword) do
        Item.create(
          name: 'Iron Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          held: true
        )
      end

      it 'lists held items under In Hand section' do
        result = command.execute('equipment')

        expect(result[:success]).to be true
        expect(result[:message]).to include('In Hand')
        expect(result[:message]).to include('Iron Sword')
      end

      it 'returns held count in data' do
        result = command.execute('equipment')

        expect(result[:data][:held_count]).to eq(1)
      end
    end

    context 'with both worn and held items' do
      let!(:helm) do
        Item.create(name: 'Steel Helm', character_instance: character_instance, quantity: 1, condition: 'good', worn: true)
      end
      let!(:shield) do
        Item.create(name: 'Buckler', character_instance: character_instance, quantity: 1, condition: 'good', held: true)
      end

      it 'shows both sections' do
        result = command.execute('equipment')

        expect(result[:message]).to include('In Hand')
        expect(result[:message]).to include('Buckler')
        expect(result[:message]).to include('Wearing')
        expect(result[:message]).to include('Steel Helm')
      end

      it 'returns correct counts' do
        result = command.execute('equipment')

        expect(result[:data][:worn_count]).to eq(1)
        expect(result[:data][:held_count]).to eq(1)
      end
    end

    context 'with item condition' do
      let!(:worn_item) do
        Item.create(name: 'Battered Gloves', character_instance: character_instance, quantity: 1, condition: 'fair', worn: true)
      end

      it 'shows condition when not good' do
        result = command.execute('equipment')

        expect(result[:message]).to include('fair')
      end
    end

    context 'with damaged items' do
      let!(:torn_cloak) do
        Item.create(name: 'Cloak', character_instance: character_instance, quantity: 1, condition: 'good', worn: true, torn: 2)
      end

      it 'shows slight damage' do
        result = command.execute('equipment')
        expect(result[:message]).to include('slightly damaged')
      end
    end

    context 'with heavily damaged items' do
      let!(:wrecked) do
        Item.create(name: 'Armor', character_instance: character_instance, quantity: 1, condition: 'good', worn: true, torn: 8)
      end

      it 'shows heavy damage' do
        result = command.execute('equipment')
        expect(result[:message]).to include('heavily damaged')
      end
    end

    context 'with stacked identical items' do
      before do
        2.times do
          Item.create(name: 'Ring', character_instance: character_instance, quantity: 1, condition: 'good', worn: true)
        end
      end

      it 'stacks identical items with count' do
        result = command.execute('equipment')

        expect(result[:message]).to include('x2')
        expect(result[:data][:worn_count]).to eq(2)
      end
    end

    context 'with aliases' do
      let!(:item) do
        Item.create(name: 'Hat', character_instance: character_instance, quantity: 1, condition: 'good', worn: true)
      end

      it 'works with eq alias' do
        result = command.execute('eq')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Hat')
      end

      it 'works with worn alias' do
        result = command.execute('worn')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Hat')
      end

      it 'works with wearing alias' do
        result = command.execute('wearing')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Hat')
      end
    end

    context 'excludes non-worn non-held items' do
      let!(:carried_only) do
        Item.create(name: 'Potion', character_instance: character_instance, quantity: 1, condition: 'good', worn: false, held: false)
      end

      it 'does not show carried-only items' do
        result = command.execute('equipment')

        expect(result[:message]).to include("aren't wearing or holding anything")
        expect(result[:message]).not_to include('Potion')
      end
    end
  end
end
