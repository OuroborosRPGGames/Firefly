# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Outfit do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }
  let(:outfit) { create(:outfit, character_instance: character_instance) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(outfit).to be_valid
    end

    it 'requires character_instance_id' do
      outfit = build(:outfit, character_instance: nil)
      expect(outfit).not_to be_valid
    end

    it 'requires name' do
      outfit = build(:outfit, character_instance: character_instance, name: nil)
      expect(outfit).not_to be_valid
    end

    it 'validates max length of name' do
      outfit = build(:outfit, character_instance: character_instance, name: 'x' * 101)
      expect(outfit).not_to be_valid
    end

    it 'validates uniqueness of name per character_instance' do
      create(:outfit, character_instance: character_instance, name: 'Casual')
      duplicate = build(:outfit, character_instance: character_instance, name: 'Casual')
      expect(duplicate).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to character_instance' do
      expect(outfit.character_instance).to eq(character_instance)
    end

    it 'has many outfit_items' do
      expect(outfit).to respond_to(:outfit_items)
    end
  end

  describe '#items' do
    it 'returns outfit items dataset' do
      expect(outfit.items).to respond_to(:all)
    end
  end

  describe '#item_count' do
    it 'returns 0 for empty outfit' do
      expect(outfit.item_count).to eq(0)
    end
  end
end
