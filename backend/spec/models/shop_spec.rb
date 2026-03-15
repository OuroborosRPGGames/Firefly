# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Shop do
  # Factory automatically creates universe -> world -> area -> location -> room hierarchy
  let!(:room) { create(:room) }

  describe 'validations' do
    it 'requires room_id' do
      shop = Shop.new(name: 'Test Shop')
      expect(shop.valid?).to be false
      expect(shop.errors[:room_id]).not_to be_empty
    end

    it 'creates valid shop with required fields' do
      shop = Shop.new(room_id: room.id, name: 'Valid Shop')
      expect(shop.valid?).to be true
    end
  end

  describe 'associations' do
    let!(:shop) { Shop.create(room_id: room.id, name: 'Test Shop', free_items: true) }

    it 'belongs to a room' do
      expect(shop.room).to eq(room)
    end

    it 'has many shop_items' do
      expect(shop).to respond_to(:shop_items)
    end
  end

  describe '#display_name' do
    context 'when name is set' do
      let(:shop) { Shop.new(room_id: room.id, name: 'My Shop', sname: 'legacy_name') }

      it 'returns name' do
        expect(shop.display_name).to eq('My Shop')
      end
    end

    context 'when only sname is set' do
      let(:shop) { Shop.new(room_id: room.id, sname: 'Legacy Shop') }

      it 'returns sname' do
        expect(shop.display_name).to eq('Legacy Shop')
      end
    end

    context 'when neither is set' do
      let(:shop) { Shop.new(room_id: room.id) }

      it 'returns "Shop"' do
        expect(shop.display_name).to eq('Shop')
      end
    end
  end

  describe '#available_items' do
    let!(:shop) { Shop.create(room_id: room.id, name: 'Test Shop') }

    context 'when shop has items' do
      let!(:pattern) { create(:pattern) }
      let!(:item) { ShopItem.create(shop_id: shop.id, pattern_id: pattern.id, price: 100, stock: 5) }

      it 'returns items with positive stock' do
        expect(shop.available_items).to include(item)
      end

      context 'when item is out of stock' do
        before { item.update(stock: 0) }

        it 'excludes out of stock items' do
          expect(shop.available_items).not_to include(item)
        end
      end

      context 'when item has unlimited stock (-1)' do
        before { item.update(stock: -1) }

        it 'includes unlimited stock items' do
          expect(shop.available_items).to include(item)
        end
      end
    end
  end

  describe '#in_stock?' do
    let!(:shop) { Shop.create(room_id: room.id, name: 'Test Shop') }
    let!(:pattern) { create(:pattern) }

    context 'when item exists with stock' do
      before { ShopItem.create(shop_id: shop.id, pattern_id: pattern.id, price: 100, stock: 5) }

      it 'returns true' do
        expect(shop.in_stock?(pattern.id)).to be true
      end
    end

    context 'when item exists with zero stock' do
      before { ShopItem.create(shop_id: shop.id, pattern_id: pattern.id, price: 100, stock: 0) }

      it 'returns false' do
        expect(shop.in_stock?(pattern.id)).to be false
      end
    end

    context 'when item does not exist' do
      it 'returns false' do
        expect(shop.in_stock?(999999)).to be false
      end
    end

    context 'when item has unlimited stock' do
      before { ShopItem.create(shop_id: shop.id, pattern_id: pattern.id, price: 100, stock: -1) }

      it 'returns true' do
        expect(shop.in_stock?(pattern.id)).to be true
      end
    end
  end

  describe '#price_for' do
    let!(:shop) { Shop.create(room_id: room.id, name: 'Test Shop', free_items: false) }
    let!(:pattern) { create(:pattern) }

    context 'when item exists' do
      before { ShopItem.create(shop_id: shop.id, pattern_id: pattern.id, price: 250, stock: 1) }

      it 'returns the item price' do
        expect(shop.price_for(pattern.id)).to eq(250)
      end
    end

    context 'when shop has free_items' do
      before do
        shop.update(free_items: true)
        ShopItem.create(shop_id: shop.id, pattern_id: pattern.id, price: 250, stock: 1)
      end

      it 'returns 0' do
        expect(shop.price_for(pattern.id)).to eq(0)
      end
    end

    context 'when item does not exist' do
      it 'returns nil' do
        expect(shop.price_for(999999)).to be_nil
      end
    end
  end

  describe '#decrement_stock' do
    let!(:shop) { Shop.create(room_id: room.id, name: 'Test Shop') }
    let!(:pattern) { create(:pattern) }
    let!(:item) { ShopItem.create(shop_id: shop.id, pattern_id: pattern.id, price: 100, stock: 5) }

    context 'when item has stock' do
      it 'decreases stock by 1' do
        expect { shop.decrement_stock(pattern.id) }.to change { item.reload.stock }.by(-1)
      end

      it 'returns true' do
        expect(shop.decrement_stock(pattern.id)).to be true
      end
    end

    context 'when item has unlimited stock' do
      before { item.update(stock: -1) }

      it 'does not change stock' do
        expect { shop.decrement_stock(pattern.id) }.not_to change { item.reload.stock }
      end

      it 'returns true' do
        expect(shop.decrement_stock(pattern.id)).to be true
      end
    end

    context 'when item is out of stock' do
      before { item.update(stock: 0) }

      it 'returns false' do
        expect(shop.decrement_stock(pattern.id)).to be false
      end
    end

    context 'when item does not exist' do
      it 'returns false' do
        expect(shop.decrement_stock(999999)).to be false
      end
    end
  end
end
