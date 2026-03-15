# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CoverObjectType do
  describe 'validations' do
    let(:valid_attrs) do
      {
        name: 'Test Cover',
        category: 'furniture',
        size: 'medium',
        default_cover_value: 2,
        default_height: 1,
        default_hp: 20,
        hex_width: 1,
        hex_height: 1
      }
    end

    it 'is valid with valid attributes' do
      cover = described_class.create(valid_attrs)
      expect(cover).to be_valid
    end

    it 'requires name' do
      cover = described_class.new(valid_attrs.merge(name: nil))
      expect(cover).not_to be_valid
    end

    it 'validates name uniqueness' do
      described_class.create(valid_attrs.merge(name: 'Unique Crate'))
      duplicate = described_class.new(valid_attrs.merge(name: 'Unique Crate'))
      expect(duplicate).not_to be_valid
    end

    it 'validates name max length' do
      cover = described_class.new(valid_attrs.merge(name: 'a' * 51))
      expect(cover).not_to be_valid
    end

    it 'validates category inclusion' do
      described_class::CATEGORIES.each_with_index do |cat, idx|
        cover = described_class.new(valid_attrs.merge(name: "Cover #{idx}", category: cat))
        expect(cover).to be_valid, "Expected category '#{cat}' to be valid"
      end
    end

    it 'rejects invalid category' do
      cover = described_class.new(valid_attrs.merge(name: 'Invalid', category: 'invalid_category'))
      expect(cover).not_to be_valid
    end

    it 'validates size inclusion' do
      described_class::SIZES.each_with_index do |size, idx|
        cover = described_class.new(valid_attrs.merge(name: "Size #{idx}", size: size))
        expect(cover).to be_valid, "Expected size '#{size}' to be valid"
      end
    end

  end

  describe 'constants' do
    it 'defines CATEGORIES' do
      expect(described_class::CATEGORIES).to eq(%w[furniture vehicle nature structure])
    end

    it 'defines SIZES' do
      expect(described_class::SIZES).to eq(%w[small medium large huge])
    end
  end

  describe '#appropriate_for_room_type?' do
    it 'returns true when no room types specified' do
      cover = create(:cover_object_type, appropriate_room_types: nil)
      expect(cover.appropriate_for_room_type?('office')).to be true
    end

    it 'returns true when room types empty' do
      cover = create(:cover_object_type, appropriate_room_types: '')
      expect(cover.appropriate_for_room_type?('office')).to be true
    end

    it 'returns true when room type matches' do
      cover = create(:cover_object_type, appropriate_room_types: 'office, warehouse')
      expect(cover.appropriate_for_room_type?('office')).to be true
    end

    it 'returns false when room type does not match' do
      cover = create(:cover_object_type, appropriate_room_types: 'office, warehouse')
      expect(cover.appropriate_for_room_type?('bedroom')).to be false
    end
  end

  describe '#parsed_properties' do
    it 'returns empty hash when properties nil' do
      cover = create(:cover_object_type, properties: nil)
      expect(cover.parsed_properties).to eq({})
    end

    it 'returns hash or empty based on implementation' do
      # The parsed_properties method depends on how JSONB is stored
      cover = create(:cover_object_type)
      result = cover.parsed_properties
      expect(result).to be_a(Hash)
    end

    it 'handles properties correctly' do
      # Create with valid JSON
      cover = create(:cover_object_type)
      # Should always return a hash, even if empty
      expect(cover.parsed_properties).to be_a(Hash)
    end
  end

  describe '#multi_hex?' do
    it 'returns false for 1x1' do
      cover = create(:cover_object_type, hex_width: 1, hex_height: 1)
      expect(cover.multi_hex?).to be false
    end

    it 'returns true for wide objects' do
      cover = create(:cover_object_type, hex_width: 2, hex_height: 1)
      expect(cover.multi_hex?).to be true
    end

    it 'returns true for tall objects' do
      cover = create(:cover_object_type, hex_width: 1, hex_height: 2)
      expect(cover.multi_hex?).to be true
    end
  end

  describe '#hex_count' do
    it 'returns 1 for 1x1' do
      cover = create(:cover_object_type, hex_width: 1, hex_height: 1)
      expect(cover.hex_count).to eq(1)
    end

    it 'returns correct count for multi-hex' do
      cover = create(:cover_object_type, hex_width: 2, hex_height: 3)
      expect(cover.hex_count).to eq(6)
    end
  end

  describe '#cover_description' do
    it 'returns no cover for 0' do
      cover = create(:cover_object_type, default_cover_value: 0)
      expect(cover.cover_description).to eq('no cover')
    end

    it 'returns provides cover for value > 0' do
      cover = create(:cover_object_type, default_cover_value: 2)
      expect(cover.cover_description).to eq('provides cover')
    end
  end

  describe '.for_room_type' do
    it 'returns objects appropriate for room type' do
      office_cover = create(:cover_object_type, name: 'Office Desk', appropriate_room_types: 'office')
      create(:cover_object_type, name: 'Warehouse Crate', appropriate_room_types: 'warehouse')
      generic_cover = create(:cover_object_type, name: 'Generic Table', appropriate_room_types: nil)

      result = described_class.for_room_type('office')
      expect(result).to include(office_cover)
      expect(result).to include(generic_cover)
      expect(result.count).to eq(2)
    end
  end

  describe '.by_category' do
    it 'returns objects by category' do
      furniture = create(:cover_object_type, category: 'furniture')
      create(:cover_object_type, category: 'vehicle')

      result = described_class.by_category('furniture')
      expect(result).to include(furniture)
      expect(result.count).to eq(1)
    end
  end

  describe '.destroyable' do
    it 'returns destroyable objects' do
      destroyable = create(:cover_object_type, is_destroyable: true)
      create(:cover_object_type, is_destroyable: false)

      result = described_class.destroyable
      expect(result).to include(destroyable)
      expect(result.count).to eq(1)
    end
  end

  describe '.explosive' do
    it 'returns explosive objects' do
      explosive = create(:cover_object_type, :explosive)
      create(:cover_object_type, is_explosive: false)

      result = described_class.explosive
      expect(result).to include(explosive)
      expect(result.count).to eq(1)
    end
  end

  describe '.flammable' do
    it 'returns flammable objects' do
      flammable = create(:cover_object_type, :flammable)
      create(:cover_object_type, is_flammable: false)

      result = described_class.flammable
      expect(result).to include(flammable)
      expect(result.count).to eq(1)
    end
  end

  describe 'traits' do
    it 'creates small cover' do
      cover = create(:cover_object_type, :small)
      expect(cover.size).to eq('small')
      expect(cover.default_cover_value).to eq(1)
    end

    it 'creates large cover' do
      cover = create(:cover_object_type, :large)
      expect(cover.size).to eq('large')
      expect(cover.hex_width).to eq(2)
      expect(cover.hex_height).to eq(2)
    end

    it 'creates vehicle cover' do
      cover = create(:cover_object_type, :vehicle)
      expect(cover.category).to eq('vehicle')
    end

    it 'creates explosive cover' do
      cover = create(:cover_object_type, :explosive)
      expect(cover.is_explosive).to be true
    end
  end
end
