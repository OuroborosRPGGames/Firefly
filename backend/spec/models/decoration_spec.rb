# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Decoration do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location) }

  describe 'validations' do
    it 'requires name' do
      decoration = described_class.new(room_id: room.id)
      expect(decoration.valid?).to be false
      expect(decoration.errors[:name]).to include('is not present')
    end

    it 'validates max length of name' do
      decoration = described_class.new(room_id: room.id, name: 'A' * 101)
      expect(decoration.valid?).to be false
      expect(decoration.errors[:name]).not_to be_empty
    end

    it 'is valid with valid attributes' do
      decoration = described_class.new(room_id: room.id, name: 'A painting')
      expect(decoration.valid?).to be true
    end
  end

  describe 'associations' do
    it 'belongs to room' do
      decoration = described_class.create(room_id: room.id, name: 'A painting')
      expect(decoration.room).to eq(room)
    end

    it 'allows nil room' do
      decoration = described_class.create(name: 'Unplaced decoration')
      expect(decoration.room).to be_nil
    end
  end

  describe '#has_image?' do
    let(:decoration) { described_class.create(room_id: room.id, name: 'A painting') }

    it 'returns true when image_url is set' do
      decoration.update(image_url: 'http://example.com/painting.png')
      expect(decoration.has_image?).to be true
    end

    it 'returns false when image_url is nil' do
      expect(decoration.has_image?).to be false
    end

    it 'returns false when image_url is empty' do
      decoration.update(image_url: '')
      expect(decoration.has_image?).to be false
    end
  end

  describe '#display_name' do
    it 'returns the name' do
      decoration = described_class.create(room_id: room.id, name: 'A grand chandelier')
      expect(decoration.display_name).to eq('A grand chandelier')
    end
  end

  describe '.in_room' do
    let!(:my_decoration) { described_class.create(room_id: room.id, name: 'Painting') }
    let(:other_room) { create(:room, location: location) }
    let!(:other_decoration) { described_class.create(room_id: other_room.id, name: 'Statue') }

    it 'returns decorations in the specified room' do
      results = described_class.in_room(room.id).all
      expect(results).to include(my_decoration)
      expect(results).not_to include(other_decoration)
    end
  end

  describe '.ordered' do
    let!(:decoration1) { described_class.create(room_id: room.id, name: 'First', display_order: 2) }
    let!(:decoration2) { described_class.create(room_id: room.id, name: 'Second', display_order: 1) }
    let!(:decoration3) { described_class.create(room_id: room.id, name: 'Third', display_order: 3) }

    it 'returns decorations ordered by display_order' do
      results = described_class.ordered.all
      expect(results.map(&:name)).to eq(%w[Second First Third])
    end
  end
end
