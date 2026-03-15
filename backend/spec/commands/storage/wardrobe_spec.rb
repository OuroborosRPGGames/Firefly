# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Storage::Wardrobe, type: :command do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'TestChar') }
  # Make room a vault so vault_accessible? returns true
  let(:room) { create(:room, is_vault: true) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('wardrobe')
    end

    it 'has aliases' do
      aliases = described_class.aliases.map { |a| a[:name] }
      expect(aliases).to include('closet', 'stash', 'vault', 'retrieve')
      expect(aliases).not_to include('store')
    end

    it 'has category' do
      expect(described_class.category).to eq(:inventory)
    end
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    describe 'vault access' do
      context 'when vault not accessible' do
        let(:non_vault_room) { create(:room, is_vault: false) }
        let(:other_instance) { create(:character_instance, character: character, current_room: non_vault_room) }
        let(:other_command) { described_class.new(other_instance) }

        it 'returns error' do
          result = other_command.execute('wardrobe')

          expect(result[:success]).to be false
          expect(result[:message]).to include('storage facility')
        end
      end
    end

    describe 'main menu' do
      it 'shows quickmenu when called without args' do
        result = command.execute('wardrobe')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
      end

      it 'includes list option' do
        result = command.execute('wardrobe')

        options = result[:data][:options]
        expect(options.any? { |o| o[:key] == 'list' }).to be true
      end

      context 'with inventory items' do
        let!(:item) { create(:item, character_instance: character_instance, stored: false, worn: false, equipped: false) }

        it 'includes store option' do
          result = command.execute('wardrobe')

          options = result[:data][:options]
          expect(options.any? { |o| o[:key] == 'store' }).to be true
        end
      end

      context 'with stored items' do
        let!(:stored_item) { create(:item, character_instance: character_instance, stored: true, stored_room_id: room.id) }

        it 'includes retrieve option' do
          result = command.execute('wardrobe')

          options = result[:data][:options]
          expect(options.any? { |o| o[:key] == 'retrieve' }).to be true
        end

        it 'includes retrieve_all option' do
          result = command.execute('wardrobe')

          options = result[:data][:options]
          expect(options.any? { |o| o[:key] == 'retrieve_all' }).to be true
        end
      end

      context 'with items at other locations' do
        let(:other_room) { create(:room, is_vault: true) }
        let!(:other_item) { create(:item, character_instance: character_instance, stored: true, stored_room_id: other_room.id) }

        it 'includes transfer option' do
          result = command.execute('wardrobe')

          options = result[:data][:options]
          expect(options.any? { |o| o[:key] == 'transfer' }).to be true
        end
      end
    end

    describe 'store operations' do
      let!(:item) { create(:item, character_instance: character_instance, name: 'Test Sword', stored: false, worn: false, equipped: false) }

      it 'stores an item' do
        result = command.execute('wardrobe store Test Sword')

        expect(result[:success]).to be true
        expect(result[:message]).to include('store')
        expect(result[:message]).to include('Test Sword')
        expect(item.reload.stored).to be true
      end

      it 'stores all items' do
        create(:item, character_instance: character_instance, name: 'Test Shield', stored: false, worn: false, equipped: false)

        result = command.execute('wardrobe store all')

        expect(result[:success]).to be true
        expect(result[:message]).to include('2 item')
      end

      it 'returns error for already stored item' do
        item.update(stored: true, stored_room_id: room.id)

        result = command.execute('wardrobe store Test Sword')

        expect(result[:success]).to be false
        expect(result[:message]).to include('already stored')
      end

      it 'returns error for worn item' do
        item.update(worn: true)

        result = command.execute('wardrobe store Test Sword')

        expect(result[:success]).to be false
        expect(result[:message]).to include('remove')
      end

      it 'returns error for equipped item' do
        item.update(equipped: true)

        result = command.execute('wardrobe store Test Sword')

        expect(result[:success]).to be false
        expect(result[:message]).to include('unequip')
      end

      it 'returns error for nonexistent item' do
        result = command.execute('wardrobe store NonExistent')

        expect(result[:success]).to be false
        expect(result[:message]).to include('inventory')
      end

      it 'shows store menu without item name' do
        result = command.execute('wardrobe store')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
      end

      describe 'alias handling' do
        it 'handles stash alias' do
          result = command.execute('stash Test Sword')

          expect(result[:success]).to be true
          expect(item.reload.stored).to be true
        end
      end
    end

    describe 'retrieve operations' do
      let!(:stored_item) { create(:item, character_instance: character_instance, name: 'Stored Sword', stored: true, stored_room_id: room.id) }

      it 'retrieves an item' do
        result = command.execute('wardrobe retrieve Stored Sword')

        expect(result[:success]).to be true
        expect(result[:message]).to include('retrieve')
        expect(result[:message]).to include('Stored Sword')
        expect(stored_item.reload.stored).to be false
      end

      it 'retrieves all items' do
        create(:item, character_instance: character_instance, name: 'Stored Shield', stored: true, stored_room_id: room.id)

        result = command.execute('wardrobe retrieve all')

        expect(result[:success]).to be true
        expect(result[:message]).to include('2 item')
      end

      it 'returns error for nonexistent stored item' do
        result = command.execute('wardrobe retrieve NonExistent')

        expect(result[:success]).to be false
        expect(result[:message]).to include('wardrobe')
      end

      it 'returns error when wardrobe is empty' do
        stored_item.update(stored: false)

        result = command.execute('wardrobe retrieve all')

        expect(result[:success]).to be false
        expect(result[:message]).to include('empty')
      end

      it 'shows retrieve menu without item name' do
        result = command.execute('wardrobe retrieve')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
      end

      describe 'alias handling' do
        it 'handles retrieve alias' do
          result = command.execute('retrieve Stored Sword')

          expect(result[:success]).to be true
          expect(stored_item.reload.stored).to be false
        end

        it 'handles fetch alias' do
          result = command.execute('fetch Stored Sword')

          expect(result[:success]).to be true
          expect(stored_item.reload.stored).to be false
        end
      end
    end

    describe 'list operations' do
      context 'with no stored items' do
        it 'shows empty message' do
          result = command.execute('wardrobe list')

          expect(result[:success]).to be true
          expect(result[:message]).to include('empty')
        end
      end

      context 'with stored items' do
        let!(:stored_item) { create(:item, character_instance: character_instance, name: 'Stored Item', stored: true, stored_room_id: room.id) }

        it 'lists stored items' do
          result = command.execute('wardrobe list')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Stored Item')
        end
      end

      context 'with items at other locations' do
        let(:other_room) { create(:room, is_vault: true) }
        let!(:other_item) { create(:item, character_instance: character_instance, name: 'Other Item', stored: true, stored_room_id: other_room.id) }

        it 'mentions items at other locations' do
          result = command.execute('wardrobe list')

          expect(result[:success]).to be true
          expect(result[:message]).to include('other locations')
        end
      end
    end

    describe 'transfer operations' do
      let(:other_room) { create(:room, name: 'Other Location', is_vault: true) }
      let!(:other_item) { create(:item, character_instance: character_instance, name: 'Remote Item', stored: true, stored_room_id: other_room.id) }

      describe 'list transfer locations' do
        it 'shows transfer menu' do
          result = command.execute('wardrobe transfer')

          expect(result[:success]).to be true
          expect(result[:type]).to eq(:quickmenu)
        end

        context 'with no items at other locations' do
          before do
            other_item.update(stored_room_id: room.id)
          end

          it 'shows no items message' do
            result = command.execute('wardrobe transfer')

            expect(result[:success]).to be true
            expect(result[:message]).to include('no items')
          end
        end
      end

      describe 'initiate transfer' do
        it 'starts transfer from location' do
          result = command.execute('wardrobe transfer from Other Location')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Transfer initiated')
          expect(result[:message]).to include('12 hours')
        end

        it 'returns error for nonexistent location' do
          result = command.execute('wardrobe transfer from NonExistent')

          expect(result[:success]).to be false
          expect(result[:message]).to include('No items found')
        end
      end

      describe 'transfer status' do
        context 'with no transfers' do
          before do
            other_item.destroy
          end

          it 'shows no transfers message' do
            result = command.execute('wardrobe status')

            expect(result[:success]).to be true
            expect(result[:message]).to include('No transfers')
          end
        end

        context 'with pending transfer' do
          before do
            other_item.update(
              transfer_started_at: Time.now,
              transfer_destination_room_id: room.id
            )
          end

          it 'shows pending transfers' do
            result = command.execute('wardrobe status')

            expect(result[:success]).to be true
            expect(result[:message]).to include('In Progress')
          end
        end

        context 'with completed transfer' do
          before do
            other_item.update(
              transfer_started_at: Time.now - (13 * 3600), # 13 hours ago
              transfer_destination_room_id: room.id
            )
          end

          it 'completes transfer and shows result' do
            result = command.execute('wardrobe status')

            expect(result[:success]).to be true
            expect(result[:message]).to include('Completed')
          end
        end
      end

      describe 'alias handling' do
        it 'handles transfer alias' do
          result = command.execute('transfer from Other Location')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Transfer initiated')
        end

        it 'handles ship alias' do
          result = command.execute('ship from Other Location')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Transfer initiated')
        end
      end
    end

    describe 'command routing' do
      let!(:item) { create(:item, character_instance: character_instance, name: 'Ambiguous Item', stored: true, stored_room_id: room.id) }

      it 'treats unknown subcommand as item name for retrieve' do
        result = command.execute('wardrobe Ambiguous Item')

        expect(result[:success]).to be true
        expect(result[:message]).to include('retrieve')
      end
    end
  end
end
