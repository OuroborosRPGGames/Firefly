# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Inventory::Give, type: :command do
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

  # Create currency for money tests
  let(:currency) do
    Currency.create(
      universe: universe,
      name: 'Gold',
      symbol: 'G',
      decimal_places: 0,
      is_primary: true
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with a valid item to give' do
      let!(:item) do
        Item.create(
          name: 'Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good'
        )
      end

      before { target_instance }

      it 'gives the item to target' do
        result = command.execute('give sword to Bob')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Sword')
        expect(result[:message]).to include('Bob')
        expect(item.reload.character_instance_id).to eq(target_instance.id)
      end

      it 'returns give data in result' do
        result = command.execute('give sword to Bob')

        expect(result[:data][:action]).to eq('give')
        expect(result[:data][:item_name]).to eq('Sword')
        expect(result[:data][:recipient_name]).to eq('Bob')
      end

      it 'clears held state on transfer' do
        item.update(held: true)

        result = command.execute('give sword to Bob')

        expect(result[:success]).to be true
        item.reload
        expect(item.character_instance_id).to eq(target_instance.id)
        expect(item.held).to be false
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
        result = command.execute('give magi to Bob')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Magic Staff')
      end
    end

    context 'with money transfer' do
      let!(:my_wallet) do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 100
        )
      end

      before { target_instance }

      it 'transfers money to target' do
        result = command.execute('give 50 to Bob')

        expect(result[:success]).to be true
        expect(result[:message]).to include('G50')
        expect(result[:message]).to include('Bob')
        expect(my_wallet.reload.balance).to eq(50)

        # Target should have wallet with money
        target_wallet = Wallet.first(character_instance_id: target_instance.id)
        expect(target_wallet).not_to be_nil
        expect(target_wallet.balance).to eq(50)
      end

      it 'creates wallet for target if needed' do
        expect(Wallet.where(character_instance_id: target_instance.id).count).to eq(0)

        result = command.execute('give 25 to Bob')

        expect(result[:success]).to be true
        expect(Wallet.where(character_instance_id: target_instance.id).count).to eq(1)
      end

      it 'returns error when giving more than wallet balance' do
        result = command.execute('give 200 to Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have that much/i)
      end
    end

    context 'with invalid input format' do
      before { target_instance }

      it 'resolves "give sword Bob" via context-aware normalizer' do
        result = command.execute('give sword Bob')

        expect(result[:success]).to be false
        # Normalizer detects Bob is a character, sword is the item — but we don't have a sword
        expect(result[:error]).to match(/don't have/i)
      end

      it 'returns error for empty input when not carrying anything' do
        result = command.execute('give')

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
        result = command.execute('give sword to Nobody')

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
        result = command.execute('give sword to Bob')

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
        result = command.execute('give sword to Alice')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/can't give.*yourself/i)
      end
    end

    context 'with item not in inventory' do
      before { target_instance }

      it 'returns error' do
        result = command.execute('give sword to Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have/i)
      end
    end

    context 'with item in storage' do
      let!(:item) do
        Item.create(
          name: 'Stored Sword',
          character_instance: character_instance,
          quantity: 1,
          condition: 'good',
          stored: true
        )
      end

      before { target_instance }

      it 'does not allow giving stored items' do
        result = command.execute('give stored sword to Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have/i)
      end
    end

    context 'with no money' do
      before do
        target_instance
        currency  # Ensure currency exists
      end

      it 'returns error when no wallet exists' do
        result = command.execute('give 50 to Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have any money/i)
      end

      it 'returns error when wallet is empty' do
        Wallet.create(
          character_instance: character_instance,
          currency: currency,
          balance: 0
        )

        result = command.execute('give 50 to Bob')

        expect(result[:success]).to be false
        expect(result[:error]).to match(/don't have that much/i)
      end
    end

    context 'with aliases' do
      let!(:item) do
        Item.create(name: 'Potion', character_instance: character_instance, quantity: 1, condition: 'good')
      end

      before { target_instance }

      it 'works with hand alias' do
        result = command.execute('hand potion to Bob')

        expect(result[:success]).to be true
      end

      it 'works with offer alias' do
        result = command.execute('offer potion to Bob')

        expect(result[:success]).to be true
      end
    end
  end
end
