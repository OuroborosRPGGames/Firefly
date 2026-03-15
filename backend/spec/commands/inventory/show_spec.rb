# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::Show, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }
  let(:target_character) { create(:character, forename: 'Bob') }
  let(:target_instance) { create(:character_instance, character: target_character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with a valid item and target' do
      let!(:item) do
        Item.create(
          name: 'Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end

      before { target_instance }

      it 'shows the item to target' do
        result = command.execute('show sword to Bob')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Sword')
        expect(result[:message]).to include('Bob')
      end

      it 'returns show data' do
        result = command.execute('show sword to Bob')

        expect(result[:data][:action]).to eq('show')
        expect(result[:data][:item_name]).to eq('Sword')
        expect(result[:data][:target_name]).to eq('Bob')
      end

      it 'broadcasts only to others after sending direct message to target' do
        expect(command).to receive(:send_to_character).with(target_instance, include('shows you Sword:'))
        expect(command).to receive(:broadcast_to_room_except) do |excluded, message|
          expect(excluded).to contain_exactly(character_instance, target_instance)
          expect(message).to include('shows something to Bob')
        end

        result = command.execute('show sword to Bob')
        expect(result[:success]).to be true
      end
    end

    context 'with item description' do
      let!(:item) do
        Item.create(
          name: 'Ring',
          description: 'A ring with mysterious runes',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end

      before { target_instance }

      it 'uses description when available' do
        result = command.execute('show ring to Bob')

        expect(result[:success]).to be true
      end
    end

    context 'with fuzzy matching for item' do
      let!(:item) do
        Item.create(
          name: 'Magic Staff',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end

      before { target_instance }

      it 'matches 4+ character prefix for item' do
        result = command.execute('show magi to Bob')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Magic Staff')
      end
    end

    context 'with invalid input format' do
      before { target_instance }

      it 'resolves "show sword Bob" via context-aware normalizer' do
        result = command.execute('show sword Bob')

        expect(result[:success]).to be false
        # Normalizer detects Bob is a character, sword is the item — but we don't have a sword
        expect(result[:error]).to match(/don't have/i)
      end

      it 'returns error for empty input when not carrying anything' do
        result = command.execute('show')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/aren't carrying anything/i)
      end
    end

    context 'with unknown target' do
      let!(:item) do
        Item.create(
          name: 'Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end

      it 'returns error' do
        result = command.execute('show sword to Nobody')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't see/i)
      end
    end

    context 'with target not in room' do
      let!(:item) do
        Item.create(
          name: 'Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end
      let(:other_room) { create(:room, location: location) }
      let!(:distant_instance) do
        create(:character_instance, character: target_character, current_room: other_room, reality: reality, online: true)
      end

      it 'returns error when target is in different room' do
        result = command.execute('show sword to Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't see/i)
      end
    end

    context 'with self as target' do
      let!(:item) do
        Item.create(
          name: 'Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end

      it 'returns error' do
        result = command.execute('show sword to Alice')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/can't show.*yourself/i)
      end
    end

    context 'with item not in inventory' do
      before { target_instance }

      it 'returns error' do
        result = command.execute('show sword to Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have/i)
      end
    end

    context 'with aliases' do
      let!(:item) do
        Item.create(name: 'Potion', character_instance: character_instance, quantity: 1, condition: 'good')
      end

      before { target_instance }

      it 'works with display alias' do
        result = command.execute('display potion to Bob')

        expect(result[:success]).to be true
      end

      it 'works with present alias' do
        result = command.execute('present potion to Bob')

        expect(result[:success]).to be true
      end
    end
  end
end
