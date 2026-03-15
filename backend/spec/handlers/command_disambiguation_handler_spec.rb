# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CommandDisambiguationHandler do
  let(:room) { create(:room) }
  let(:character) { create(:character) }
  let(:char_instance) { create(:character_instance, character: character, current_room: room) }

  before do
    allow(BroadcastService).to receive(:to_room)
    allow(BroadcastService).to receive(:to_character)
  end

  describe '.process_response' do
    context 'with invalid selection' do
      it 'returns error for invalid index' do
        interaction_data = { context: { action: 'get', match_ids: [1, 2] } }

        result = described_class.process_response(char_instance, interaction_data, '5')

        expect(result[:success]).to be false
        expect(result[:message]).to eq('Invalid selection')
      end
    end

    context 'with unknown action' do
      it 'returns error for unknown action' do
        interaction_data = { context: { action: 'unknown_action', match_ids: [1] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Unknown action')
      end
    end

    # Item commands
    context 'with get action' do
      let(:item) { create(:item, :in_room, room: room) }

      it 'picks up the selected item' do
        interaction_data = { context: { action: 'get', match_ids: [item.id] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('pick up')
        expect(result[:data][:item_id]).to eq(item.id)
      end

      it 'returns error when item not found' do
        interaction_data = { context: { action: 'get', match_ids: [99999] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to eq('Item not found')
      end
    end

    context 'with drop action' do
      let(:item) { create(:item, character_instance: char_instance) }

      it 'drops the selected item' do
        interaction_data = { context: { action: 'drop', match_ids: [item.id] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('drop')
        expect(result[:data][:item_id]).to eq(item.id)
      end
    end

    context 'with wear action' do
      let(:item) { create(:item, character_instance: char_instance) }

      before do
        allow(Item).to receive(:[]).with(item.id).and_return(item)
      end

      context 'when item is wearable' do
        before do
          allow(item).to receive(:wearable?).and_return(true)
          allow(item).to receive(:wear!)
        end

        it 'wears the selected item' do
          interaction_data = { context: { action: 'wear', match_ids: [item.id] } }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be true
          expect(result[:message]).to include('put on')
        end
      end

      context 'when item is not wearable' do
        before do
          allow(item).to receive(:wearable?).and_return(false)
        end

        it 'returns error' do
          interaction_data = { context: { action: 'wear', match_ids: [item.id] } }

          result = described_class.process_response(char_instance, interaction_data, '1')

          expect(result[:success]).to be false
          expect(result[:message]).to include('not wearable')
        end
      end
    end

    context 'with hold action' do
      let(:item) { create(:item, character_instance: char_instance) }

      before do
        allow(item).to receive(:hold!)
        allow(Item).to receive(:[]).with(item.id).and_return(item)
      end

      it 'holds the selected item' do
        interaction_data = { context: { action: 'hold', match_ids: [item.id] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('hold')
      end
    end

    context 'with pocket action' do
      let(:item) { create(:item, character_instance: char_instance) }

      before do
        allow(item).to receive(:pocket!)
        allow(Item).to receive(:[]).with(item.id).and_return(item)
      end

      it 'pockets the selected item' do
        interaction_data = { context: { action: 'pocket', match_ids: [item.id] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('pocket')
      end
    end

    context 'with show action' do
      let(:item) { create(:item, character_instance: char_instance, description: 'A shiny sword') }

      it 'shows the selected item' do
        interaction_data = { context: { action: 'show', match_ids: [item.id] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('show')
      end
    end

    context 'with remove action' do
      let(:item) { create(:item, character_instance: char_instance) }

      before do
        allow(item).to receive(:remove!)
        allow(Item).to receive(:[]).with(item.id).and_return(item)
      end

      it 'removes the selected item' do
        interaction_data = { context: { action: 'remove', match_ids: [item.id] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('remove')
      end
    end

    context 'with eat action' do
      let(:item) { create(:item, character_instance: char_instance) }

      before do
        allow(item).to receive(:consume!)
        allow(Item).to receive(:[]).with(item.id).and_return(item)
      end

      it 'eats the selected item' do
        interaction_data = { context: { action: 'eat', match_ids: [item.id] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('eat')
      end
    end

    context 'with drink action' do
      let(:item) { create(:item, character_instance: char_instance) }

      before do
        allow(item).to receive(:consume!)
        allow(Item).to receive(:[]).with(item.id).and_return(item)
      end

      it 'drinks the selected item' do
        interaction_data = { context: { action: 'drink', match_ids: [item.id] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('drink')
      end
    end

    context 'with smoke action' do
      let(:item) { create(:item, character_instance: char_instance) }

      before do
        allow(item).to receive(:consume!)
        allow(Item).to receive(:[]).with(item.id).and_return(item)
      end

      it 'smokes the selected item' do
        interaction_data = { context: { action: 'smoke', match_ids: [item.id] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('smoke')
      end
    end

    # Character commands
    context 'with follow action' do
      let(:target) { create(:character_instance, current_room: room) }

      before do
        allow(MovementService).to receive(:start_following).and_return(
          double(success: true, message: 'You are now following.')
        )
      end

      it 'follows the selected character' do
        interaction_data = { context: { action: 'follow', match_ids: [target.id] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:data][:target_id]).to eq(target.id)
      end

      it 'returns error when target not found' do
        interaction_data = { context: { action: 'follow', match_ids: [99999] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to eq('Character not found')
      end
    end

    context 'with lead action' do
      let(:target) { create(:character_instance, current_room: room) }

      before do
        allow(MovementService).to receive(:grant_follow_permission).and_return(
          double(success: true, message: 'Permission granted.')
        )
      end

      it 'grants lead permission to selected character' do
        interaction_data = { context: { action: 'lead', match_ids: [target.id] } }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:data][:target_id]).to eq(target.id)
      end
    end

    context 'with whisper action' do
      let(:target) { create(:character_instance, current_room: room) }

      it 'whispers to the selected character' do
        interaction_data = {
          context: {
            action: 'whisper',
            match_ids: [target.id],
            message: 'Hello there!'
          }
        }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('whisper')
        expect(BroadcastService).to have_received(:to_character).with(target, anything)
      end

      it 'returns error when no message' do
        interaction_data = {
          context: {
            action: 'whisper',
            match_ids: [target.id],
            message: ''
          }
        }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to eq('No message to whisper')
      end
    end

    # Give command with multi-step disambiguation
    context 'with give action' do
      let(:item) { create(:item, character_instance: char_instance) }
      let(:target) { create(:character_instance, current_room: room) }

      it 'completes give when target_id is in context' do
        interaction_data = {
          context: {
            action: 'give',
            match_ids: [item.id],
            step: 'item',
            target_id: target.id
          }
        }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('give')
      end

      it 'completes give when selecting target' do
        interaction_data = {
          context: {
            action: 'give',
            match_ids: [target.id],
            step: 'target',
            item_id: item.id
          }
        }

        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('give')
      end
    end
  end

  # Shop commands
    context 'with buy action' do
      let(:universe) { create(:universe) }
      let(:currency) { create(:currency, universe: universe) }
      let(:wallet) { create(:wallet, character_instance: char_instance, currency: currency, balance: 100) }
      let(:shop) { create(:shop, room: room) }
      let(:stock_item) { create(:shop_item, shop: shop, price: 50) }

      before do
        allow(shop).to receive(:currency).and_return(currency)
        allow(shop).to receive(:location).and_return(
          double(zone: double(world: double(universe: universe)))
        )
        allow(Shop).to receive(:[]).with(shop.id).and_return(shop)
      end

      it 'buys the item when affordable' do
        allow(shop).to receive(:stock_items_dataset).and_return(double(first: stock_item))
        allow(char_instance).to receive(:wallets_dataset).and_return(double(first: wallet))
        allow(wallet).to receive(:subtract).with(50)
        created_item = create(:item, character_instance: char_instance)
        allow(stock_item).to receive(:create_item_for).with(char_instance).and_return(created_item)
        allow(currency).to receive(:format_amount).with(50).and_return('50 gold')

        interaction_data = { context: { action: 'buy', match_ids: [stock_item.id], shop_id: shop.id } }
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('buy')
      end

      it 'returns error when item not in shop' do
        allow(shop).to receive(:stock_items_dataset).and_return(double(first: nil))

        interaction_data = { context: { action: 'buy', match_ids: [99999], shop_id: shop.id } }
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to eq('Item not found in shop')
      end

      it 'returns error when cannot afford' do
        allow(shop).to receive(:stock_items_dataset).and_return(double(first: stock_item))
        poor_wallet = double('Wallet', balance: 10)
        allow(char_instance).to receive(:wallets_dataset).and_return(double(first: poor_wallet))

        interaction_data = { context: { action: 'buy', match_ids: [stock_item.id], shop_id: shop.id } }
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to include("can't afford")
      end

      it 'returns error when shop not found' do
        allow(Shop).to receive(:[]).with(99999).and_return(nil)

        interaction_data = { context: { action: 'buy', match_ids: [stock_item.id], shop_id: 99999 } }
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to eq('Item not found in shop')
      end
    end

    context 'with preview action' do
      let(:shop) { create(:shop, room: room) }
      let(:stock_item) { create(:shop_item, shop: shop) }

      before do
        allow(Shop).to receive(:[]).with(shop.id).and_return(shop)
      end

      it 'previews the stock item' do
        allow(shop).to receive(:stock_items_dataset).and_return(double(first: stock_item))
        allow(stock_item).to receive(:name).and_return('Fancy Hat')
        allow(stock_item).to receive(:description).and_return('A very fancy hat')

        interaction_data = { context: { action: 'preview', match_ids: [stock_item.id], shop_id: shop.id } }
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Fancy Hat')
        expect(result[:data][:name]).to eq('Fancy Hat')
      end

      it 'returns error when item not found in shop' do
        allow(shop).to receive(:stock_items_dataset).and_return(double(first: nil))

        interaction_data = { context: { action: 'preview', match_ids: [99999], shop_id: shop.id } }
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to eq('Item not found in shop')
      end
    end

    # Card/Deck commands
    context 'with fabricate_deck action' do
      let(:deck_pattern) { create(:deck_pattern, creator: character) }

      it 'creates deck when character is creator' do
        deck = double('Deck', id: 1, remaining_count: 52)
        allow(DeckPattern).to receive(:[]).with(deck_pattern.id).and_return(deck_pattern)
        allow(deck_pattern).to receive(:create_deck_for).with(char_instance).and_return(deck)

        interaction_data = { context: { action: 'fabricate_deck', match_ids: [deck_pattern.id] } }
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
        expect(result[:message]).to include(deck_pattern.name)
        expect(result[:data][:pattern_id]).to eq(deck_pattern.id)
      end

      it 'creates deck when pattern is public' do
        other_creator = create(:character)
        public_pattern = create(:deck_pattern, creator: other_creator, is_public: true)
        deck = double('Deck', id: 1, remaining_count: 52)
        allow(DeckPattern).to receive(:[]).with(public_pattern.id).and_return(public_pattern)
        allow(public_pattern).to receive(:create_deck_for).with(char_instance).and_return(deck)

        interaction_data = { context: { action: 'fabricate_deck', match_ids: [public_pattern.id] } }
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
      end

      it 'returns error when pattern not found' do
        allow(DeckPattern).to receive(:[]).with(99999).and_return(nil)

        interaction_data = { context: { action: 'fabricate_deck', match_ids: [99999] } }
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to eq('Deck pattern not found')
      end

      it 'returns error when no access to private pattern' do
        other_creator = create(:character)
        private_pattern = create(:deck_pattern, creator: other_creator, is_public: false)
        allow(DeckPattern).to receive(:[]).with(private_pattern.id).and_return(private_pattern)
        allow(DeckOwnership).to receive(:where).with(
          character_id: character.id,
          deck_pattern_id: private_pattern.id
        ).and_return(double(any?: false))

        interaction_data = { context: { action: 'fabricate_deck', match_ids: [private_pattern.id] } }
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to include("don't have access")
      end
    end

    # Piercing handling for wear
    context 'with wear action for piercings' do
      let(:item) { create(:item, character_instance: char_instance) }

      before do
        allow(Item).to receive(:[]).with(item.id).and_return(item)
      end

      it 'requires position for piercing items' do
        allow(item).to receive(:wearable?).and_return(true)
        allow(item).to receive(:piercing?).and_return(true)

        interaction_data = { context: { action: 'wear', match_ids: [item.id] } }
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to include('body position')
      end

      it 'wears piercing at specified position' do
        allow(item).to receive(:wearable?).and_return(true)
        allow(item).to receive(:piercing?).and_return(true)
        allow(item).to receive(:wear!).with(position: 'left ear').and_return(true)

        interaction_data = { context: { action: 'wear', match_ids: [item.id], position: 'left ear' } }
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be true
      end

      it 'returns error from wear! for piercings' do
        allow(item).to receive(:wearable?).and_return(true)
        allow(item).to receive(:piercing?).and_return(true)
        allow(item).to receive(:wear!).with(position: 'ear').and_return('Position already occupied')

        interaction_data = { context: { action: 'wear', match_ids: [item.id], position: 'ear' } }
        result = described_class.process_response(char_instance, interaction_data, '1')

        expect(result[:success]).to be false
        expect(result[:message]).to eq('Position already occupied')
      end
    end

  describe 'response helpers' do
    it 'returns consistent success structure' do
      item = create(:item, :in_room, room: room)
      interaction_data = { context: { action: 'get', match_ids: [item.id] } }

      result = described_class.process_response(char_instance, interaction_data, '1')

      expect(result).to include(:success, :message, :data)
      expect(result[:success]).to be true
    end

    it 'returns consistent error structure' do
      interaction_data = { context: { action: 'get', match_ids: [99999] } }

      result = described_class.process_response(char_instance, interaction_data, '1')

      expect(result).to include(:success, :message, :error)
      expect(result[:success]).to be false
    end
  end
end
