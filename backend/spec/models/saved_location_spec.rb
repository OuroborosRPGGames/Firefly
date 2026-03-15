# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SavedLocation do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:character) { create(:character) }
  let(:saved_location) { create(:saved_location, character: character, room: room) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(saved_location).to be_valid
    end

    it 'requires character_id' do
      saved_location = build(:saved_location, character: nil, room: room)
      expect(saved_location).not_to be_valid
    end

    it 'requires room_id' do
      saved_location = build(:saved_location, character: character, room: nil)
      expect(saved_location).not_to be_valid
    end

    it 'requires location_name' do
      saved_location = build(:saved_location, character: character, room: room, location_name: nil)
      expect(saved_location).not_to be_valid
    end

    it 'validates max length of location_name' do
      saved_location = build(:saved_location, character: character, room: room, location_name: 'x' * 101)
      expect(saved_location).not_to be_valid
    end

    it 'validates uniqueness of location_name per character' do
      create(:saved_location, character: character, room: room, location_name: 'Home')
      duplicate = build(:saved_location, character: character, room: room, location_name: 'Home')
      expect(duplicate).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to character' do
      expect(saved_location.character).to eq(character)
    end

    it 'belongs to room' do
      expect(saved_location.room).to eq(room)
    end
  end

  describe '#name' do
    it 'returns location_name' do
      saved_location = create(:saved_location, character: character, room: room, location_name: 'My Spot')
      expect(saved_location.name).to eq('My Spot')
    end
  end

  describe '#name=' do
    it 'sets name column' do
      saved_location = build(:saved_location, character: character, room: room)
      saved_location.name = 'New Name'
      # Database column is 'name', not 'location_name'
      expect(saved_location[:name]).to eq('New Name')
    end
  end

  describe '.find_by_name' do
    let!(:saved) { create(:saved_location, character: character, room: room, location_name: 'Home') }

    it 'finds by exact name (case-insensitive)' do
      result = described_class.find_by_name(character, 'home')
      expect(result).to eq(saved)
    end

    it 'returns nil if not found' do
      result = described_class.find_by_name(character, 'nowhere')
      expect(result).to be_nil
    end
  end

  describe '.for_character' do
    let!(:saved1) { create(:saved_location, character: character, room: room, location_name: 'Alpha') }
    let!(:saved2) { create(:saved_location, character: character, room: room, location_name: 'Beta') }
    let!(:other) { create(:saved_location, room: room, location_name: 'Other') }

    it 'returns saved locations for the character' do
      results = described_class.for_character(character).all
      expect(results).to include(saved1, saved2)
      expect(results).not_to include(other)
    end

    it 'orders by location_name' do
      results = described_class.for_character(character).all
      expect(results.first).to eq(saved1) # Alpha comes before Beta
    end
  end

  describe '#location_path' do
    it 'returns the room full path' do
      allow(room).to receive(:full_path).and_return('World > Area > Room')
      expect(saved_location.location_path).to eq('World > Area > Room')
    end
  end
end
