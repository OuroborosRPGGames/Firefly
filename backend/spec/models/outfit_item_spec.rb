# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OutfitItem do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality)
  end
  let(:outfit) { create(:outfit, character_instance: character_instance) }
  let(:pattern) { create(:pattern, description: 'a blue shirt') }

  describe 'validations' do
    it 'requires outfit_id' do
      item = described_class.new(pattern_id: pattern.id)
      expect(item.valid?).to be false
      expect(item.errors[:outfit_id]).not_to be_empty
    end

    it 'is valid without pattern_id' do
      item = described_class.new(outfit_id: outfit.id)
      expect(item.valid?).to be true
    end

    it 'is valid with all fields' do
      item = described_class.new(
        outfit_id: outfit.id,
        pattern_id: pattern.id
      )
      expect(item.valid?).to be true
    end
  end

  describe '#before_save' do
    it 'sets display_order to 0 if nil' do
      item = described_class.create(outfit_id: outfit.id)
      expect(item.display_order).to eq(0)
    end

    it 'preserves existing display_order' do
      item = described_class.create(outfit_id: outfit.id, display_order: 5)
      expect(item.display_order).to eq(5)
    end
  end

  describe '#item_name' do
    it 'returns pattern description when pattern exists' do
      item = described_class.create(outfit_id: outfit.id, pattern_id: pattern.id)
      expect(item.item_name).to eq('a blue shirt')
    end

    it 'returns Unknown item when pattern is nil' do
      item = described_class.create(outfit_id: outfit.id)
      expect(item.item_name).to eq('Unknown item')
    end
  end
end
