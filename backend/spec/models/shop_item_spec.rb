# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ShopItem do
  # Factory automatically creates universe -> world -> area -> location -> room hierarchy
  let!(:room) { create(:room) }
  let!(:shop) { Shop.create(room_id: room.id, name: 'Test Shop', free_items: false) }
  let!(:pattern) { create(:pattern) }

  describe 'validations' do
    it 'requires shop_id' do
      item = ShopItem.new(pattern_id: pattern.id, price: 100)
      expect(item.valid?).to be false
      expect(item.errors[:shop_id]).not_to be_empty
    end

    it 'creates valid item with required fields' do
      item = ShopItem.new(shop_id: shop.id, pattern_id: pattern.id, price: 100)
      expect(item.valid?).to be true
    end

    it 'allows negative stock for unlimited' do
      item = ShopItem.new(shop_id: shop.id, pattern_id: pattern.id, price: 100, stock: -1)
      expect(item.valid?).to be true
    end
  end

  describe 'associations' do
    let!(:item) { ShopItem.create(shop_id: shop.id, pattern_id: pattern.id, price: 100, stock: 5) }

    it 'belongs to a shop' do
      expect(item.shop).to eq(shop)
    end

    it 'belongs to a pattern' do
      expect(item.pattern).to eq(pattern)
    end
  end

  describe '#available?' do
    context 'with positive stock' do
      let(:item) { ShopItem.new(shop_id: shop.id, pattern_id: pattern.id, price: 100, stock: 5) }

      it 'returns true' do
        expect(item.available?).to be true
      end
    end

    context 'with zero stock' do
      let(:item) { ShopItem.new(shop_id: shop.id, pattern_id: pattern.id, price: 100, stock: 0) }

      it 'returns false' do
        expect(item.available?).to be false
      end
    end

    context 'with unlimited stock (-1)' do
      let(:item) { ShopItem.new(shop_id: shop.id, pattern_id: pattern.id, price: 100, stock: -1) }

      it 'returns true' do
        expect(item.available?).to be true
      end
    end

    context 'with nil stock' do
      let(:item) { ShopItem.new(shop_id: shop.id, pattern_id: pattern.id, price: 100, stock: nil) }

      it 'returns true (treats nil as unlimited)' do
        expect(item.available?).to be true
      end
    end
  end

  describe '#unlimited_stock?' do
    context 'with stock of -1' do
      let(:item) { ShopItem.new(stock: -1) }

      it 'returns true' do
        expect(item.unlimited_stock?).to be true
      end
    end

    context 'with nil stock' do
      let(:item) { ShopItem.new(stock: nil) }

      it 'returns true' do
        expect(item.unlimited_stock?).to be true
      end
    end

    context 'with positive stock' do
      let(:item) { ShopItem.new(stock: 5) }

      it 'returns false' do
        expect(item.unlimited_stock?).to be false
      end
    end

    context 'with zero stock' do
      let(:item) { ShopItem.new(stock: 0) }

      it 'returns false' do
        expect(item.unlimited_stock?).to be false
      end
    end
  end

  describe '#effective_price' do
    context 'when shop has free_items false' do
      let!(:item) { ShopItem.create(shop_id: shop.id, pattern_id: pattern.id, price: 250, stock: 1) }

      it 'returns the item price' do
        expect(item.effective_price).to eq(250)
      end
    end

    context 'when shop has free_items true' do
      before { shop.update(free_items: true) }
      let!(:item) { ShopItem.create(shop_id: shop.id, pattern_id: pattern.id, price: 250, stock: 1) }

      it 'returns 0' do
        expect(item.effective_price).to eq(0)
      end
    end

    context 'when price is nil' do
      let!(:item) { ShopItem.create(shop_id: shop.id, pattern_id: pattern.id, price: nil, stock: 1) }

      it 'returns 0' do
        expect(item.effective_price).to eq(0)
      end
    end
  end

  describe 'pattern_id column' do
    it 'supports pattern_id for new records' do
      item = ShopItem.create(shop_id: shop.id, pattern_id: pattern.id, price: 100, stock: 1)
      expect(item.pattern_id).to eq(pattern.id)
    end
  end
end
