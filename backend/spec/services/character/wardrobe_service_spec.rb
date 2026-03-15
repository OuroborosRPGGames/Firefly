# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WardrobeService do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:room) { create(:room) }
  let(:instance) { create(:character_instance, character: character, current_room: room) }
  let(:service) { described_class.new(instance) }

  describe 'constants' do
    it 'defines PATTERN_CREATE_COST_MULTIPLIER' do
      expect(described_class::PATTERN_CREATE_COST_MULTIPLIER).to eq(0.5)
    end

    it 'defines TAB_CATEGORIES' do
      expect(described_class::TAB_CATEGORIES).to include('clothing', 'jewelry', 'consumables', 'weapons', 'other')
    end

    it 'defines CLOTHING_SUBCATEGORY_MAP' do
      expect(described_class::CLOTHING_SUBCATEGORY_MAP).to include('tops', 'bottoms', 'dresses')
    end

    it 'defines JEWELRY_SUBCATEGORY_MAP' do
      expect(described_class::JEWELRY_SUBCATEGORY_MAP).to include('necklaces', 'rings', 'bracelets', 'piercings')
    end

    it 'defines SUBCATEGORY_REVERSE_MAP' do
      expect(described_class::SUBCATEGORY_REVERSE_MAP['Top']).to eq('tops')
      expect(described_class::SUBCATEGORY_REVERSE_MAP['Pants']).to eq('bottoms')
      expect(described_class::SUBCATEGORY_REVERSE_MAP['Skirt']).to eq('bottoms')
      expect(described_class::SUBCATEGORY_REVERSE_MAP['Ring']).to eq('rings')
    end
  end

  describe '#initialize' do
    it 'accepts a character_instance' do
      expect(service.instance_variable_get(:@ci)).to eq(instance)
      expect(service.instance_variable_get(:@room)).to eq(room)
    end
  end

  describe '#vault_accessible?' do
    context 'when room is nil' do
      it 'returns false' do
        # Use a mock since CharacterInstance validates current_room_id presence
        instance_no_room = double('CharacterInstance', current_room: nil, character: character)
        svc = described_class.new(instance_no_room)
        expect(svc.vault_accessible?).to be false
      end
    end

    context 'when room has vault access' do
      before do
        allow(room).to receive(:vault_accessible?).with(character).and_return(true)
      end

      it 'returns true' do
        expect(service.vault_accessible?).to be true
      end
    end

    context 'when room does not have vault access' do
      before do
        allow(room).to receive(:vault_accessible?).with(character).and_return(false)
      end

      it 'returns false' do
        expect(service.vault_accessible?).to be false
      end
    end
  end

  describe '#items_by_category' do
    let!(:top_uot) { create(:unified_object_type, category: 'Top') }
    let!(:ring_uot) { create(:unified_object_type, category: 'Ring') }
    let!(:pants_uot) { create(:unified_object_type, category: 'Pants') }

    let!(:top_pattern) { create(:pattern, unified_object_type: top_uot) }
    let!(:ring_pattern) { create(:pattern, unified_object_type: ring_uot) }
    let!(:pants_pattern) { create(:pattern, unified_object_type: pants_uot) }

    let!(:top_item) do
      create(:item, character_instance: instance, pattern: top_pattern, stored: true, stored_room_id: room.id, name: 'Top Item')
    end
    let!(:ring_item) do
      create(:item, character_instance: instance, pattern: ring_pattern, stored: true, stored_room_id: room.id, name: 'Ring Item')
    end
    let!(:pants_item) do
      create(:item, character_instance: instance, pattern: pants_pattern, stored: true, stored_room_id: room.id, name: 'Pants Item')
    end

    it 'filters by tab category' do
      result = service.items_by_category('clothing')

      expect(result.map(&:id)).to include(top_item.id, pants_item.id)
      expect(result.map(&:id)).not_to include(ring_item.id)
    end

    it 'filters by subcategory' do
      result = service.items_by_category('clothing', 'tops')

      expect(result.map(&:id)).to contain_exactly(top_item.id)
    end

    it 'excludes in-transit items' do
      top_item.update(transfer_started_at: Time.now, transfer_destination_room_id: room.id)

      result = service.items_by_category('clothing')

      expect(result.map(&:id)).not_to include(top_item.id)
    end

    it 'completes ready transfers before returning items' do
      source_room = create(:room)
      top_item.update(
        stored_room_id: source_room.id,
        transfer_started_at: Time.now - (Item::TRANSFER_DURATION_HOURS * 3600) - 60,
        transfer_destination_room_id: room.id
      )

      result = service.items_by_category('clothing')
      refreshed = top_item.refresh

      expect(result.map(&:id)).to include(top_item.id)
      expect(refreshed.transfer_started_at).to be_nil
      expect(refreshed.stored_room_id).to eq(room.id)
      expect(refreshed.transfer_destination_room_id).to be_nil
    end
  end

  describe '#eligible_patterns' do
    let(:pattern_ids) { [1, 2, 3] }
    let(:objects_dataset) { double('Dataset') }
    let(:patterns_dataset) { double('PatternsDataset') }

    before do
      allow(instance).to receive(:objects_dataset).and_return(objects_dataset)
      allow(objects_dataset).to receive(:exclude).with(pattern_id: nil).and_return(objects_dataset)
      allow(objects_dataset).to receive(:select_map).with(:pattern_id).and_return(pattern_ids)
      allow(Pattern).to receive(:where).and_return(patterns_dataset)
      allow(patterns_dataset).to receive(:eager).with(:unified_object_type).and_return(patterns_dataset)
      allow(patterns_dataset).to receive(:order).and_return([])
    end

    it 'returns patterns from owned items' do
      service.eligible_patterns
      expect(Pattern).to have_received(:where)
    end
  end

  describe '#fetch_item' do
    let(:item) { double('Item', name: 'Test Item') }
    let(:stored_items) { double('Dataset') }

    context 'without vault access' do
      before do
        allow(room).to receive(:vault_accessible?).with(character).and_return(false)
      end

      it 'returns error' do
        result = service.fetch_item(1)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('No vault access')
      end
    end

    context 'with vault access' do
      before do
        allow(room).to receive(:vault_accessible?).with(character).and_return(true)
        allow(Item).to receive(:available_stored_items_for).with(instance).and_return(stored_items)
      end

      context 'when item exists' do
        before do
          allow(stored_items).to receive(:where).with(id: 1).and_return(double(first: item))
          allow(item).to receive(:retrieve!)
        end

        it 'retrieves the item and returns success' do
          expect(item).to receive(:retrieve!)

          result = service.fetch_item(1)

          expect(result[:success]).to be true
          expect(result[:message]).to include('Test Item')
        end
      end

      context 'when item does not exist' do
        before do
          allow(stored_items).to receive(:where).with(id: 999).and_return(double(first: nil))
        end

        it 'returns error' do
          result = service.fetch_item(999)

          expect(result[:success]).to be false
          expect(result[:error]).to eq('Item not found')
        end
      end
    end
  end

  describe '#fetch_and_wear' do
    let(:item) { double('Item', name: 'Test Shirt') }
    let(:stored_items) { double('Dataset') }

    before do
      allow(room).to receive(:vault_accessible?).with(character).and_return(true)
      allow(Item).to receive(:available_stored_items_for).with(instance).and_return(stored_items)
      allow(stored_items).to receive(:where).with(id: 1).and_return(double(first: item))
      allow(item).to receive(:retrieve!)
    end

    context 'when item supports wearing' do
      before do
        allow(item).to receive(:respond_to?).with(:piercing?).and_return(true)
        allow(item).to receive(:respond_to?).with(:wear!).and_return(true)
        allow(item).to receive(:piercing?).and_return(false)
        allow(item).to receive(:wear!).and_return(true)
      end

      it 'fetches and wears the item' do
        expect(item).to receive(:wear!)

        result = service.fetch_and_wear(1)

        expect(result[:success]).to be true
        expect(result[:worn]).to be true
      end
    end

    context 'when item does not support wearing' do
      before do
        allow(item).to receive(:respond_to?).with(:piercing?).and_return(false)
        allow(item).to receive(:respond_to?).with(:wear!).and_return(false)
      end

      it 'just fetches the item' do
        result = service.fetch_and_wear(1)

        expect(result[:success]).to be true
        expect(result[:worn]).to be_nil
      end
    end

    context 'when item is a piercing' do
      before do
        allow(item).to receive(:respond_to?).with(:piercing?).and_return(true)
        allow(item).to receive(:respond_to?).with(:wear!).and_return(true)
        allow(item).to receive(:piercing?).and_return(true)
      end

      context 'when character has no pierced positions' do
        before do
          allow(instance).to receive(:pierced_positions).and_return([])
        end

        it 'returns error about needing piercing holes' do
          result = service.fetch_and_wear(1)

          expect(result[:success]).to be false
          expect(result[:error]).to include("don't have any piercing holes")
        end
      end

      context 'when character has one pierced position' do
        before do
          allow(instance).to receive(:pierced_positions).and_return(['ear'])
          allow(item).to receive(:wear!).with(position: 'ear').and_return(true)
        end

        it 'auto-selects the single position' do
          result = service.fetch_and_wear(1)

          expect(result[:success]).to be true
          expect(result[:worn]).to be true
          expect(result[:position]).to eq('ear')
        end
      end

      context 'when character has multiple pierced positions' do
        before do
          allow(instance).to receive(:pierced_positions).and_return(['left ear', 'right ear', 'nose'])
        end

        it 'returns needs_position flag with available positions' do
          result = service.fetch_and_wear(1)

          expect(result[:success]).to be false
          expect(result[:needs_position]).to be true
          expect(result[:positions]).to eq(['left ear', 'right ear', 'nose'])
        end
      end

      context 'when wear! returns an error' do
        before do
          allow(instance).to receive(:pierced_positions).and_return(['ear'])
          allow(item).to receive(:wear!).with(position: 'ear').and_return('Position already occupied')
        end

        it 'returns the wear! error message' do
          result = service.fetch_and_wear(1)

          expect(result[:success]).to be false
          expect(result[:error]).to eq('Position already occupied')
        end
      end
    end
  end

  describe '#create_from_pattern' do
    let(:pattern) { double('Pattern', id: 1, price: 100) }
    let(:wallet) { double('Wallet', balance: 200) }
    let(:new_item) { double('Item', name: 'New Item') }

    before do
      allow(room).to receive(:vault_accessible?).with(character).and_return(true)
      allow(Pattern).to receive(:[]).with(1).and_return(pattern)
    end

    context 'without vault access' do
      before do
        allow(room).to receive(:vault_accessible?).with(character).and_return(false)
      end

      it 'returns error' do
        result = service.create_from_pattern(1)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('No vault access')
      end
    end

    context 'when pattern not found' do
      before do
        allow(Pattern).to receive(:[]).with(999).and_return(nil)
      end

      it 'returns error' do
        result = service.create_from_pattern(999)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('Pattern not found')
      end
    end

    context 'when pattern not accessible' do
      let(:objects_dataset) { double('Dataset') }

      before do
        allow(instance).to receive(:objects_dataset).and_return(objects_dataset)
        allow(objects_dataset).to receive(:where).with(pattern_id: pattern.id).and_return(double(any?: false))
      end

      it 'returns error' do
        result = service.create_from_pattern(1)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('You do not have access to this pattern')
      end
    end

    context 'when creating with cost' do
      let(:objects_dataset) { double('Dataset') }

      before do
        allow(instance).to receive(:objects_dataset).and_return(objects_dataset)
        allow(objects_dataset).to receive(:where).with(pattern_id: pattern.id).and_return(double(any?: true))
        allow(instance).to receive(:wallets).and_return([wallet])
      end

      context 'with sufficient funds' do
        before do
          allow(wallet).to receive(:remove).with(50).and_return(true)
          allow(pattern).to receive(:instantiate).with(character_instance: instance).and_return(new_item)
        end

        it 'creates item at half cost' do
          expect(wallet).to receive(:remove).with(50)

          result = service.create_from_pattern(1)

          expect(result[:success]).to be true
          expect(result[:cost]).to eq(50)
        end
      end

      context 'with insufficient funds' do
        let(:poor_wallet) { double('Wallet', balance: 10) }

        before do
          allow(instance).to receive(:wallets).and_return([poor_wallet])
        end

        it 'returns error' do
          result = service.create_from_pattern(1)

          expect(result[:success]).to be false
          expect(result[:error]).to include('Insufficient funds')
        end
      end

      context 'with no wallet' do
        before do
          allow(instance).to receive(:wallets).and_return([])
        end

        it 'returns error' do
          result = service.create_from_pattern(1)

          expect(result[:success]).to be false
          expect(result[:error]).to eq('No wallet found')
        end
      end
    end

    context 'when creating free item' do
      let(:free_pattern) { double('Pattern', id: 2, price: 0) }
      let(:objects_dataset) { double('Dataset') }

      before do
        allow(Pattern).to receive(:[]).with(2).and_return(free_pattern)
        allow(instance).to receive(:objects_dataset).and_return(objects_dataset)
        allow(objects_dataset).to receive(:where).with(pattern_id: free_pattern.id).and_return(double(any?: true))
        allow(free_pattern).to receive(:instantiate).with(character_instance: instance).and_return(new_item)
      end

      it 'creates item without payment' do
        result = service.create_from_pattern(2)

        expect(result[:success]).to be true
        expect(result[:cost]).to eq(0)
      end
    end
  end

  describe '#trash_item' do
    let(:item) { double('Item', name: 'Trash Me', id: 1) }
    let(:stored_items) { double('Dataset') }

    context 'without vault access' do
      before do
        allow(room).to receive(:vault_accessible?).with(character).and_return(false)
      end

      it 'returns error' do
        result = service.trash_item(1)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('No vault access')
      end
    end

    context 'with vault access' do
      before do
        allow(room).to receive(:vault_accessible?).with(character).and_return(true)
        allow(Item).to receive(:available_stored_items_for).with(instance).and_return(stored_items)
      end

      context 'when item exists' do
        before do
          allow(stored_items).to receive(:where).with(id: 1).and_return(double(first: item))
          allow(item).to receive(:destroy)
        end

        it 'destroys the item and returns success' do
          expect(item).to receive(:destroy)

          result = service.trash_item(1)

          expect(result[:success]).to be true
          expect(result[:message]).to include('Trash Me')
        end
      end

      context 'when item does not exist' do
        before do
          allow(stored_items).to receive(:where).with(id: 999).and_return(double(first: nil))
        end

        it 'returns error' do
          result = service.trash_item(999)

          expect(result[:success]).to be false
          expect(result[:error]).to eq('Item not found')
        end
      end
    end
  end

  describe 'transfer synchronization' do
    let(:source_room) { create(:room) }

    before do
      allow(room).to receive(:vault_accessible?).with(character).and_return(true)
    end

    it 'does not fetch items that are still in transit' do
      item = create(
        :item,
        character_instance: instance,
        stored: true,
        stored_room_id: source_room.id,
        transfer_started_at: Time.now,
        transfer_destination_room_id: room.id
      )

      result = service.fetch_item(item.id)

      expect(result[:success]).to be false
      expect(result[:error]).to eq('Item not found')
    end

    it 'auto-completes ready transfers when listing active transfers' do
      item = create(
        :item,
        character_instance: instance,
        stored: true,
        stored_room_id: source_room.id,
        transfer_started_at: Time.now - (Item::TRANSFER_DURATION_HOURS * 3600) - 60,
        transfer_destination_room_id: room.id
      )

      transfers = service.active_transfers
      refreshed = item.refresh

      expect(transfers).to eq([])
      expect(refreshed.transfer_started_at).to be_nil
      expect(refreshed.stored_room_id).to eq(room.id)
      expect(refreshed.transfer_destination_room_id).to be_nil
    end
  end

  describe '#overview' do
    it 'returns vault accessibility' do
      allow(room).to receive(:vault_accessible?).with(character).and_return(true)

      result = service.overview

      expect(result[:vault_accessible]).to be true
    end

    it 'returns false when no vault access' do
      allow(room).to receive(:vault_accessible?).with(character).and_return(false)

      result = service.overview

      expect(result[:vault_accessible]).to be false
    end
  end
end
