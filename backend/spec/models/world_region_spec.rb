# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldRegion do
  let(:world) { create(:world) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      region = described_class.create(
        world: world,
        region_x: 0,
        region_y: 0,
        zoom_level: 0
      )
      expect(region).to be_valid
    end

    it 'requires world_id' do
      region = described_class.new(region_x: 0, region_y: 0, zoom_level: 0)
      expect(region).not_to be_valid
    end

    it 'requires region_x' do
      region = described_class.new(world: world, region_y: 0, zoom_level: 0)
      expect(region).not_to be_valid
    end

    it 'requires region_y' do
      region = described_class.new(world: world, region_x: 0, zoom_level: 0)
      expect(region).not_to be_valid
    end

    it 'requires zoom_level' do
      region = described_class.new(world: world, region_x: 0, region_y: 0)
      expect(region).not_to be_valid
    end

    it 'validates zoom_level is within range' do
      (0..7).each do |level|
        region = described_class.new(world: world, region_x: 0, region_y: 0, zoom_level: level)
        expect(region).to be_valid, "Expected zoom_level #{level} to be valid"
      end
    end

    it 'rejects zoom_level below minimum' do
      region = described_class.new(world: world, region_x: 0, region_y: 0, zoom_level: -1)
      expect(region).not_to be_valid
    end

    it 'rejects zoom_level above maximum' do
      region = described_class.new(world: world, region_x: 0, region_y: 0, zoom_level: 8)
      expect(region).not_to be_valid
    end

    it 'validates dominant_terrain inclusion when present' do
      WorldHex::TERRAIN_TYPES.each do |terrain|
        region = described_class.new(world: world, region_x: 0, region_y: 0, zoom_level: 0, dominant_terrain: terrain)
        expect(region).to be_valid, "Expected dominant_terrain '#{terrain}' to be valid"
      end
    end
  end

  describe 'associations' do
    it 'belongs to world' do
      region = create(:world_region, world: world)
      expect(region.world).to eq(world)
    end
  end

  describe 'constants' do
    it 'defines ZOOM_LEVELS' do
      expect(described_class::ZOOM_LEVELS).to include(0 => 'world', 7 => 'hex')
    end

    it 'defines MAX_ZOOM_LEVEL in GameConfig' do
      expect(GameConfig::WorldMap::MAX_ZOOM_LEVEL).to eq(7)
    end

    it 'defines MIN_ZOOM_LEVEL in GameConfig' do
      expect(GameConfig::WorldMap::MIN_ZOOM_LEVEL).to eq(0)
    end

    it 'defines GRID_SIZE in GameConfig' do
      expect(GameConfig::WorldMap::GRID_SIZE).to eq(3)
    end

    it 'defines TERRAIN_COLORS' do
      expect(described_class::TERRAIN_COLORS).to include('ocean', 'grassy_plains', 'mountain')
    end
  end

  describe '#zoom_level_name' do
    it 'returns name for zoom level 0' do
      region = create(:world_region, world: world, zoom_level: 0)
      expect(region.zoom_level_name).to eq('world')
    end

    it 'returns name for zoom level 7' do
      region = create(:world_region, world: world, zoom_level: 7)
      expect(region.zoom_level_name).to eq('hex')
    end

    it 'returns unknown for invalid zoom level' do
      region = build(:world_region, world: world, zoom_level: 0)
      # Bypass validation to set invalid zoom_level
      region.save
      region.this.update(zoom_level: 99)
      region.refresh
      expect(region.zoom_level_name).to eq('unknown')
    end
  end

  describe '#terrain_color' do
    it 'returns color for known terrain' do
      region = create(:world_region, world: world, dominant_terrain: 'ocean')
      expect(region.terrain_color).to eq('#2d5f8a')
    end

    it 'returns default gray for unknown terrain' do
      region = described_class.new(world: world, region_x: 0, region_y: 0, zoom_level: 0)
      expect(region.terrain_color).to eq('#808080')
    end
  end

  describe '#children' do
    it 'returns empty array at max zoom level' do
      region = create(:world_region, world: world, zoom_level: 7)
      expect(region.children).to eq([])
    end

    it 'returns child regions at deeper zoom level' do
      parent = described_class.create(world: world, region_x: 0, region_y: 0, zoom_level: 0)
      child = described_class.create(world: world, region_x: 0, region_y: 0, zoom_level: 1)

      expect(parent.children).to include(child)
    end
  end

  describe '#parent' do
    it 'returns nil at min zoom level' do
      region = create(:world_region, world: world, zoom_level: 0)
      expect(region.parent).to be_nil
    end

    it 'returns parent region at shallower zoom level' do
      parent = described_class.create(world: world, region_x: 0, region_y: 0, zoom_level: 0)
      child = described_class.create(world: world, region_x: 0, region_y: 0, zoom_level: 1)

      expect(child.parent).to eq(parent)
    end

    it 'calculates correct parent coordinates' do
      # Child at region_x: 3, region_y: 4 at zoom level 2
      # Parent should be at region_x: 1, region_y: 1 at zoom level 1 (3/3=1, 4/3=1)
      parent = described_class.create(world: world, region_x: 1, region_y: 1, zoom_level: 1)
      child = described_class.create(world: world, region_x: 3, region_y: 4, zoom_level: 2)

      expect(child.parent).to eq(parent)
    end
  end

  describe '#hexes' do
    it 'returns empty array at non-max zoom level' do
      region = create(:world_region, world: world, zoom_level: 0)
      expect(region.hexes).to eq([])
    end

    it 'returns empty array at zoom level 6' do
      region = create(:world_region, world: world, zoom_level: 6)
      expect(region.hexes).to eq([])
    end

    it 'returns hexes at max zoom level 7' do
      # At zoom level 7, there are 3^7 = 2187 regions per axis
      # Each region covers: 180/2187 ~= 0.082 degrees lat, 360/2187 ~= 0.165 degrees lon
      # Region (1093, 1093) covers approximately lat -0.04 to 0.04, lon -0.08 to 0.08
      region = create(:world_region, world: world, region_x: 1093, region_y: 1093, zoom_level: 7)

      # Create a hex within that region's bounds (near lat=0, lon=0)
      hex = create(:world_hex, world: world, globe_hex_id: 1,
                   latitude: 0.0, longitude: 0.0)

      # Note: The hexes method returns hexes based on lat/lon bounding boxes
      expect(region.hexes).to include(hex)
    end
  end

  describe '#to_api_hash' do
    it 'returns hash with expected keys' do
      region = create(:world_region, world: world)
      result = region.to_api_hash

      expect(result).to include(
        :id, :world_id, :region_x, :region_y, :zoom_level, :zoom_level_name,
        :dominant_terrain, :terrain_color, :avg_altitude, :terrain_composition,
        :has_road, :has_river, :has_railway, :traversable_percentage,
        :is_generated, :is_modified
      )
    end
  end

  describe '#recalculate_aggregates!' do
    context 'at max zoom level (from hexes)' do
      # Use a region that covers lat/lon around (0, 0) for easy testing
      # At zoom level 7, 3^7 = 2187 regions per axis
      # Region (1093, 1093) covers lat -0.04 to 0.04, lon -0.08 to 0.08
      let(:region) { create(:world_region, world: world, region_x: 1093, region_y: 1093, zoom_level: 7) }

      # Helper to create hexes within this region's lat/lon bounds (around 0,0)
      def create_hex_in_region(attrs = {})
        create(:world_hex, { world: world, latitude: 0.0, longitude: 0.0 }.merge(attrs))
      end

      it 'does not modify region when no hexes exist' do
        original_terrain = region.dominant_terrain
        region.recalculate_aggregates!
        region.refresh
        # Region keeps its original value when no hexes to aggregate
        expect(region.dominant_terrain).to eq(original_terrain)
      end

      it 'calculates dominant terrain from hexes' do
        # Create hexes with different terrain types, all at lat=0, lon=0
        create_hex_in_region(globe_hex_id: 1, terrain_type: 'dense_forest')
        create_hex_in_region(globe_hex_id: 2, latitude: 0.001, terrain_type: 'dense_forest')
        create_hex_in_region(globe_hex_id: 3, latitude: 0.002, terrain_type: 'grassy_plains')

        region.recalculate_aggregates!
        region.refresh

        expect(region.dominant_terrain).to eq('dense_forest')
      end

      it 'calculates terrain composition percentages' do
        create_hex_in_region(globe_hex_id: 1, terrain_type: 'dense_forest')
        create_hex_in_region(globe_hex_id: 2, latitude: 0.001, terrain_type: 'ocean')

        region.recalculate_aggregates!
        region.refresh

        expect(region.terrain_composition['dense_forest']).to eq(50.0)
        expect(region.terrain_composition['ocean']).to eq(50.0)
      end

      it 'calculates average altitude' do
        create_hex_in_region(globe_hex_id: 1, altitude: 100)
        create_hex_in_region(globe_hex_id: 2, latitude: 0.001, altitude: 200)

        region.recalculate_aggregates!
        region.refresh

        expect(region.avg_altitude).to eq(150)
      end

      it 'calculates traversable percentage' do
        create_hex_in_region(globe_hex_id: 1, traversable: true)
        create_hex_in_region(globe_hex_id: 2, latitude: 0.001, traversable: false)

        region.recalculate_aggregates!
        region.refresh

        expect(region.traversable_percentage).to eq(50.0)
      end

      it 'detects road features' do
        create_hex_in_region(globe_hex_id: 1, feature_n: 'road')

        region.recalculate_aggregates!
        region.refresh

        expect(region.has_road).to be true
      end

      it 'detects river features' do
        create_hex_in_region(globe_hex_id: 1, feature_ne: 'river')

        region.recalculate_aggregates!
        region.refresh

        expect(region.has_river).to be true
      end

      it 'detects railway features' do
        create_hex_in_region(globe_hex_id: 1, feature_s: 'railway')

        region.recalculate_aggregates!
        region.refresh

        expect(region.has_railway).to be true
      end

      it 'detects highway as road feature' do
        create_hex_in_region(globe_hex_id: 1, feature_se: 'highway')

        region.recalculate_aggregates!
        region.refresh

        expect(region.has_road).to be true
      end

      it 'detects canal as river feature' do
        create_hex_in_region(globe_hex_id: 1, feature_sw: 'canal')

        region.recalculate_aggregates!
        region.refresh

        expect(region.has_river).to be true
      end
    end

    context 'at non-max zoom level (from children)' do
      let(:parent) { create(:world_region, world: world, region_x: 0, region_y: 0, zoom_level: 0) }

      it 'does not modify region when no children exist' do
        original_terrain = parent.dominant_terrain
        parent.recalculate_aggregates!
        parent.refresh
        # Parent keeps its original value when no children to aggregate
        expect(parent.dominant_terrain).to eq(original_terrain)
      end

      it 'calculates dominant terrain from children' do
        # Create child regions with different dominant terrain
        create(:world_region, world: world, region_x: 0, region_y: 0, zoom_level: 1,
               dominant_terrain: 'dense_forest', terrain_composition: { 'dense_forest' => 100.0 })
        create(:world_region, world: world, region_x: 1, region_y: 0, zoom_level: 1,
               dominant_terrain: 'dense_forest', terrain_composition: { 'dense_forest' => 100.0 })
        create(:world_region, world: world, region_x: 2, region_y: 0, zoom_level: 1,
               dominant_terrain: 'ocean', terrain_composition: { 'ocean' => 100.0 })

        parent.recalculate_aggregates!
        parent.refresh

        expect(parent.dominant_terrain).to eq('dense_forest')
      end

      it 'aggregates feature flags from children' do
        create(:world_region, world: world, region_x: 0, region_y: 0, zoom_level: 1,
               has_road: true, has_river: false, has_railway: false,
               terrain_composition: { 'grassy_plains' => 100.0 })
        create(:world_region, world: world, region_x: 1, region_y: 0, zoom_level: 1,
               has_road: false, has_river: true, has_railway: true,
               terrain_composition: { 'grassy_plains' => 100.0 })

        parent.recalculate_aggregates!
        parent.refresh

        expect(parent.has_road).to be true
        expect(parent.has_river).to be true
        expect(parent.has_railway).to be true
      end

      it 'calculates average altitude from children' do
        create(:world_region, world: world, region_x: 0, region_y: 0, zoom_level: 1,
               avg_altitude: 100, terrain_composition: { 'grassy_plains' => 100.0 })
        create(:world_region, world: world, region_x: 1, region_y: 0, zoom_level: 1,
               avg_altitude: 200, terrain_composition: { 'grassy_plains' => 100.0 })

        parent.recalculate_aggregates!
        parent.refresh

        expect(parent.avg_altitude).to eq(150)
      end

      it 'calculates traversable percentage from children' do
        create(:world_region, world: world, region_x: 0, region_y: 0, zoom_level: 1,
               traversable_percentage: 80.0, terrain_composition: { 'grassy_plains' => 100.0 })
        create(:world_region, world: world, region_x: 1, region_y: 0, zoom_level: 1,
               traversable_percentage: 40.0, terrain_composition: { 'grassy_plains' => 100.0 })

        parent.recalculate_aggregates!
        parent.refresh

        expect(parent.traversable_percentage).to eq(60.0)
      end

      it 'normalizes terrain composition from children' do
        create(:world_region, world: world, region_x: 0, region_y: 0, zoom_level: 1,
               terrain_composition: { 'dense_forest' => 50.0, 'grassy_plains' => 50.0 })
        create(:world_region, world: world, region_x: 1, region_y: 0, zoom_level: 1,
               terrain_composition: { 'ocean' => 100.0 })

        parent.recalculate_aggregates!
        parent.refresh

        # Total input percentages: forest=50, plain=50, ocean=100 = 200 total
        # Normalized: forest=25%, plain=25%, ocean=50%
        expect(parent.terrain_composition['dense_forest']).to eq(25.0)
        expect(parent.terrain_composition['grassy_plains']).to eq(25.0)
        expect(parent.terrain_composition['ocean']).to eq(50.0)
      end
    end
  end

  describe '.at_zoom_level' do
    it 'returns regions at specified zoom level' do
      region0 = described_class.create(world: world, region_x: 0, region_y: 0, zoom_level: 0)
      region1 = described_class.create(world: world, region_x: 0, region_y: 0, zoom_level: 1)

      result = described_class.at_zoom_level(world, 0)
      expect(result).to include(region0)
      expect(result).not_to include(region1)
    end
  end

  describe '.get_view' do
    it 'returns 3x3 grid of regions at zoom level 0' do
      # Create 9 regions for zoom level 0
      (0...3).each do |x|
        (0...3).each do |y|
          described_class.create(world: world, region_x: x, region_y: y, zoom_level: 0)
        end
      end

      result = described_class.region_view(world, 1, 1, 0)
      expect(result.count).to eq(9)
    end

    it 'returns 3x3 grid centered on coordinates at non-zero zoom level' do
      # Create regions at zoom level 1 around center (5, 5)
      (4..6).each do |x|
        (4..6).each do |y|
          described_class.create(world: world, region_x: x, region_y: y, zoom_level: 1)
        end
      end

      result = described_class.region_view(world, 5, 5, 1)
      expect(result.count).to eq(9)
      expect(result.map(&:region_x).uniq.sort).to eq([4, 5, 6])
      expect(result.map(&:region_y).uniq.sort).to eq([4, 5, 6])
    end

    it 'returns fewer regions when at edge of map' do
      # Create only some regions
      described_class.create(world: world, region_x: 0, region_y: 0, zoom_level: 1)
      described_class.create(world: world, region_x: 1, region_y: 0, zoom_level: 1)
      described_class.create(world: world, region_x: 0, region_y: 1, zoom_level: 1)
      described_class.create(world: world, region_x: 1, region_y: 1, zoom_level: 1)

      # Center on 0,0 which would query -1..1, but only 0 and 1 exist
      result = described_class.region_view(world, 0, 0, 1)
      expect(result.count).to eq(4)
    end
  end

  describe '.create_initial_regions' do
    it 'creates 9 regions at zoom level 0' do
      described_class.create_initial_regions(world)
      count = described_class.where(world_id: world.id, zoom_level: 0).count
      expect(count).to eq(9)
    end

    it 'does not duplicate regions on second call' do
      described_class.create_initial_regions(world)
      described_class.create_initial_regions(world)
      count = described_class.where(world_id: world.id, zoom_level: 0).count
      expect(count).to eq(9)
    end
  end
end
