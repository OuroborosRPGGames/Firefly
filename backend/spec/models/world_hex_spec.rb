# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldHex do
  let(:world) { create(:world) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      hex = described_class.create(
        world: world,
        globe_hex_id: 1,
        terrain_type: 'grassy_plains',
        latitude: 0.0,
        longitude: 0.0
      )
      expect(hex).to be_valid
    end

    it 'requires world_id' do
      hex = described_class.new(globe_hex_id: 1, terrain_type: 'grassy_plains')
      expect(hex).not_to be_valid
    end

    it 'requires globe_hex_id' do
      hex = described_class.new(world: world, terrain_type: 'grassy_plains')
      expect(hex).not_to be_valid
    end

    it 'validates uniqueness of world_id, globe_hex_id combination' do
      described_class.create(world: world, globe_hex_id: 1, terrain_type: 'grassy_plains')
      duplicate = described_class.new(world: world, globe_hex_id: 1, terrain_type: 'dense_forest')
      expect(duplicate).not_to be_valid
    end

    it 'validates terrain_type inclusion' do
      described_class::TERRAIN_TYPES.each do |terrain|
        hex = described_class.new(world: world, globe_hex_id: 1, terrain_type: terrain)
        expect(hex).to be_valid, "Expected terrain_type '#{terrain}' to be valid"
      end
    end

    it 'rejects invalid terrain_type' do
      hex = described_class.new(world: world, globe_hex_id: 1, terrain_type: 'lava')
      expect(hex).not_to be_valid
    end

    # Note: Integer validation is handled by PostgreSQL at the database level
    # Sequel passes values directly to the database, so type coercion happens there
  end

  describe 'associations' do
    it 'belongs to world' do
      hex = create(:world_hex, world: world)
      expect(hex.world).to eq(world)
    end
  end

  describe 'constants' do
    it 'defines TERRAIN_TYPES' do
      expect(described_class::TERRAIN_TYPES).to include('ocean', 'lake', 'grassy_plains', 'urban', 'dense_forest', 'mountain')
    end

    it 'defines FEATURE_TYPES' do
      expect(described_class::FEATURE_TYPES).to include('road', 'river', 'railway')
    end

    it 'defines DIRECTIONS' do
      expect(described_class::DIRECTIONS).to eq(%w[n ne se s sw nw])
    end

    it 'defines default values' do
      expect(described_class::DEFAULT_TERRAIN).to eq('grassy_plains')
      expect(described_class::DEFAULT_ELEVATION).to eq(0)
    end
  end

  describe '#linear_features' do
    it 'returns empty hash when no features' do
      hex = create(:world_hex, world: world)
      expect(hex.linear_features).to eq({})
    end
  end

  describe '#has_linear_features?' do
    it 'returns false when no features' do
      hex = create(:world_hex, world: world)
      expect(hex.has_linear_features?).to be false
    end
  end

  describe '#directional_features' do
    it 'returns empty hash when no features' do
      hex = create(:world_hex, world: world)
      expect(hex.directional_features).to eq({})
    end
  end

  describe '#has_directional_features?' do
    it 'returns false when no directional features' do
      hex = create(:world_hex, world: world)
      expect(hex.has_directional_features?).to be false
    end
  end

  describe '#has_road?' do
    it 'returns false when no roads' do
      hex = create(:world_hex, world: world)
      expect(hex.has_road?).to be false
    end
  end

  describe '#has_river?' do
    it 'returns false when no rivers' do
      hex = create(:world_hex, world: world)
      expect(hex.has_river?).to be false
    end
  end

  describe '#has_railway?' do
    it 'returns false when no railways' do
      hex = create(:world_hex, world: world)
      expect(hex.has_railway?).to be false
    end
  end

  describe '#movement_cost' do
    it 'returns 10 for ocean' do
      hex = create(:world_hex, :ocean, world: world)
      expect(hex.movement_cost).to eq(10)
    end

    it 'returns 4 for mountain' do
      hex = create(:world_hex, :mountain, world: world)
      expect(hex.movement_cost).to eq(4)
    end

    it 'returns 2 for dense_forest' do
      hex = create(:world_hex, :forest, world: world)
      expect(hex.movement_cost).to eq(2)
    end

    it 'returns 1 for grassy_plains' do
      hex = create(:world_hex, world: world, terrain_type: 'grassy_plains')
      expect(hex.movement_cost).to eq(1)
    end

    it 'returns 1 for urban' do
      hex = create(:world_hex, :urban, world: world)
      expect(hex.movement_cost).to eq(1)
    end
  end

  describe '#blocks_sight?' do
    it 'returns true for dense_forest' do
      hex = create(:world_hex, :forest, world: world)
      expect(hex.blocks_sight?).to be true
    end

    it 'returns true for mountain' do
      hex = create(:world_hex, :mountain, world: world)
      expect(hex.blocks_sight?).to be true
    end

    it 'returns true for urban' do
      hex = create(:world_hex, :urban, world: world)
      expect(hex.blocks_sight?).to be true
    end

    it 'returns false for grassy_plains' do
      hex = create(:world_hex, world: world, terrain_type: 'grassy_plains')
      expect(hex.blocks_sight?).to be false
    end
  end

  describe '#terrain_description' do
    it 'returns description for each terrain type' do
      hex = create(:world_hex, world: world, terrain_type: 'dense_forest')
      expect(hex.terrain_description).to eq('Dense forest')
    end
  end

  describe '#altitude' do
    it 'returns elevation value as altitude for backward compatibility' do
      hex = create(:world_hex, world: world)
      expect(hex.altitude).to eq(WorldHex::DEFAULT_ELEVATION)
    end
  end

  describe '#traversable' do
    it 'returns default when column does not exist' do
      hex = create(:world_hex, world: world)
      expect(hex.traversable).to eq(WorldHex::DEFAULT_TRAVERSABLE)
    end
  end

  describe '#to_api_hash' do
    it 'returns hash with expected keys for globe hexes' do
      hex = create(:world_hex, world: world, globe_hex_id: 42, latitude: 45.0, longitude: -122.0)
      result = hex.to_api_hash

      expect(result).to include(
        :id, :world_id, :globe_hex_id, :latitude, :longitude, :terrain_type, :altitude,
        :traversable, :directional_features, :linear_features,
        :movement_cost, :blocks_sight, :has_road, :has_river, :has_railway
      )
    end
  end

  describe '.terrain_at' do
    it 'returns terrain type of existing hex by globe_hex_id' do
      described_class.create(world: world, globe_hex_id: 100, terrain_type: 'dense_forest')
      expect(described_class.terrain_at(world, 100)).to eq('dense_forest')
    end

    it 'returns default terrain for non-existent hex' do
      expect(described_class.terrain_at(world, 999)).to eq('grassy_plains')
    end
  end

  describe '.traversable_at?' do
    it 'returns true for existing hex' do
      described_class.create(world: world, globe_hex_id: 100, terrain_type: 'ocean')
      expect(described_class.traversable_at?(world, 100)).to eq(WorldHex::DEFAULT_TRAVERSABLE)
    end

    it 'returns true (default) for non-existent hex' do
      expect(described_class.traversable_at?(world, 999)).to be true
    end
  end

  describe '.set_hex_details' do
    it 'creates new hex with attributes' do
      hex = described_class.set_hex_details(world, 100, terrain_type: 'mountain')
      expect(hex.terrain_type).to eq('mountain')
    end

    it 'updates existing hex' do
      described_class.create(world: world, globe_hex_id: 100, terrain_type: 'grassy_plains')
      hex = described_class.set_hex_details(world, 100, terrain_type: 'dense_forest')
      expect(hex.terrain_type).to eq('dense_forest')
    end
  end

  describe '.traversable_in_region' do
    before do
      # Create hexes with varying traversability and lat/lon positions
      described_class.create(world: world, globe_hex_id: 1, latitude: 0.0, longitude: 0.0, terrain_type: 'grassy_plains', traversable: true)
      described_class.create(world: world, globe_hex_id: 2, latitude: 1.0, longitude: 1.0, terrain_type: 'grassy_plains', traversable: true)
      described_class.create(world: world, globe_hex_id: 3, latitude: 2.0, longitude: 2.0, terrain_type: 'mountain', traversable: false)
      described_class.create(world: world, globe_hex_id: 4, latitude: 1.5, longitude: 1.5, terrain_type: 'grassy_plains', traversable: true)
      described_class.create(world: world, globe_hex_id: 5, latitude: 10.0, longitude: 10.0, terrain_type: 'ocean', traversable: false)
    end

    it 'returns only traversable hexes in the lat/lon region' do
      result = described_class.traversable_in_region(world, min_lat: -1.0, max_lat: 3.0, min_lon: -1.0, max_lon: 3.0)
      expect(result.count).to eq(3)
    end

    it 'respects region boundaries' do
      result = described_class.traversable_in_region(world, min_lat: 0.0, max_lat: 1.0, min_lon: 0.0, max_lon: 1.0)
      expect(result.count).to eq(2)
    end
  end

  describe '.count_traversable' do
    it 'returns count of traversable hexes' do
      described_class.create(world: world, globe_hex_id: 1, terrain_type: 'grassy_plains', traversable: true)
      described_class.create(world: world, globe_hex_id: 2, terrain_type: 'grassy_plains', traversable: true)
      described_class.create(world: world, globe_hex_id: 3, terrain_type: 'mountain', traversable: false)

      expect(described_class.count_traversable(world)).to eq(2)
    end

    it 'returns 0 when no traversable hexes' do
      described_class.create(world: world, globe_hex_id: 1, terrain_type: 'ocean', traversable: false)

      expect(described_class.count_traversable(world)).to eq(0)
    end
  end

  describe '.set_traversable_in_region' do
    before do
      described_class.create(world: world, globe_hex_id: 1, latitude: 0.0, longitude: 0.0, terrain_type: 'grassy_plains', traversable: true)
      described_class.create(world: world, globe_hex_id: 2, latitude: 1.0, longitude: 1.0, terrain_type: 'grassy_plains', traversable: true)
      described_class.create(world: world, globe_hex_id: 3, latitude: 10.0, longitude: 10.0, terrain_type: 'mountain', traversable: true)
    end

    it 'updates traversability for hexes in lat/lon region' do
      count = described_class.set_traversable_in_region(world, min_lat: -1.0, max_lat: 2.0, min_lon: -1.0, max_lon: 2.0, traversable: false)

      expect(count).to eq(2)
      expect(described_class.where(world: world, globe_hex_id: 1).first.traversable).to be false
      expect(described_class.where(world: world, globe_hex_id: 2).first.traversable).to be false
      # Hex outside region should be unchanged
      expect(described_class.where(world: world, globe_hex_id: 3).first.traversable).to be true
    end
  end

  describe '.set_all_traversable' do
    before do
      described_class.create(world: world, globe_hex_id: 1, terrain_type: 'grassy_plains', traversable: true)
      described_class.create(world: world, globe_hex_id: 2, terrain_type: 'ocean', traversable: false)
      described_class.create(world: world, globe_hex_id: 3, terrain_type: 'mountain', traversable: true)
    end

    it 'sets all hexes to traversable' do
      count = described_class.set_all_traversable(world, traversable: true)

      expect(count).to eq(3)
      described_class.where(world: world).each do |hex|
        expect(hex.traversable).to be true
      end
    end

    it 'sets all hexes to non-traversable' do
      count = described_class.set_all_traversable(world, traversable: false)

      expect(count).to eq(3)
      described_class.where(world: world).each do |hex|
        expect(hex.traversable).to be false
      end
    end
  end
end
