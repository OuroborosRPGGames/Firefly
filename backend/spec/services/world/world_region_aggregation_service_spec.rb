# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldRegionAggregationService do
  let(:world) { create(:world) }

  describe '.aggregate_for_world' do
    context 'when world has no hexes' do
      it 'returns stats with zero hexes' do
        stats = described_class.aggregate_for_world(world)

        expect(stats[:world_id]).to eq(world.id)
        expect(stats[:hexes_counted]).to eq(0)
        expect(stats[:regions_created]).to eq(0)
      end

      it 'clears existing regions' do
        create(:world_region, world: world)

        described_class.aggregate_for_world(world)

        expect(WorldRegion.where(world_id: world.id).count).to eq(0)
      end
    end

    context 'when world has small number of hexes' do
      before do
        # Create a small set of hexes with globe_hex_ids and varied lat/lon
        (1..9).each do |id|
          # Spread hexes across the world with different lat/lon
          lat = -45.0 + (id * 10)  # -35, -25, -15, -5, 5, 15, 25, 35, 45
          lon = -90.0 + (id * 20)  # -70, -50, -30, -10, 10, 30, 50, 70, 90
          create(:world_hex,
                 world: world,
                 globe_hex_id: id,
                 latitude: lat,
                 longitude: lon,
                 terrain_type: %w[ocean grassy_plains mountain].sample)
        end
      end

      it 'aggregates hexes into regions' do
        stats = described_class.aggregate_for_world(world)

        expect(stats[:hexes_counted]).to eq(9)
        expect(stats[:regions_created]).to be > 0
      end

      it 'processes all zoom levels' do
        stats = described_class.aggregate_for_world(world)

        expect(stats[:levels_processed]).to be > 0
      end

      it 'creates regions with correct dominant terrain' do
        # All ocean hexes - update all hexes to ocean
        WorldHex.where(world_id: world.id).update(terrain_type: 'ocean')

        described_class.aggregate_for_world(world)

        # With globe hexes, regions are created based on lat/lon grouping
        region = WorldRegion.where(world_id: world.id).first
        expect(region).not_to be_nil
        expect(region.dominant_terrain).to eq('ocean')
      end

      it 'tracks feature flags from hexes' do
        # Add a road feature using the directional column
        hex = WorldHex.where(world_id: world.id).first
        hex.update(feature_n: 'road')

        described_class.aggregate_for_world(world)

        # At least one region should have has_road = true
        region_with_road = WorldRegion.where(world_id: world.id, has_road: true).first
        expect(region_with_road).not_to be_nil
      end
    end

    context 'when world has large number of hexes' do
      before do
        # We can't actually create 100k+ hexes in tests, so we stub
        allow(WorldHex).to receive(:where).and_call_original
        allow(WorldHex).to receive(:where).with(world_id: world.id).and_return(
          double(
            count: 150_000,
            select: double(first: { min_x: 0, max_x: 1000, min_y: 0, max_y: 1000 }),
            all: []
          )
        )
      end

      it 'uses large world aggregation path' do
        # Mock to avoid actual large world processing
        allow(described_class).to receive(:aggregate_large_world) do |_world, stats|
          stats[:regions_created] = 100
          stats[:levels_processed] = 1
        end

        stats = described_class.aggregate_for_world(world)

        expect(stats[:hexes_counted]).to eq(150_000)
      end
    end

    it 'records timing statistics' do
      # Need at least one hex for full aggregation to run
      create(:world_hex, world: world, globe_hex_id: 1, terrain_type: 'grassy_plains')

      stats = described_class.aggregate_for_world(world)

      expect(stats[:started_at]).to be_a(Time)
      expect(stats[:completed_at]).to be_a(Time)
      expect(stats[:duration_seconds]).to be_a(Numeric)
    end
  end

  describe 'constants' do
    it 'has correct grid size' do
      expect(described_class::GRID_SIZE).to eq(3)
    end

    it 'has correct batch size' do
      expect(described_class::BATCH_SIZE).to eq(1000)
    end

    it 'uses max zoom level from GameConfig' do
      expect(described_class::MAX_LEVEL).to eq(GameConfig::WorldMap::MAX_ZOOM_LEVEL)
    end

    it 'uses min zoom level from GameConfig' do
      expect(described_class::MIN_LEVEL).to eq(GameConfig::WorldMap::MIN_ZOOM_LEVEL)
    end
  end

  describe 'aggregation from children' do
    before do
      # Create some level 3 regions
      create(:world_region, world: world, region_x: 0, region_y: 0, zoom_level: 3,
             dominant_terrain: 'ocean', terrain_composition: { 'ocean' => 100.0 },
             avg_altitude: 0, traversable_percentage: 0.0)
      create(:world_region, world: world, region_x: 1, region_y: 0, zoom_level: 3,
             dominant_terrain: 'grassy_plains', terrain_composition: { 'grassy_plains' => 80.0, 'ocean' => 20.0 },
             avg_altitude: 50, has_road: true, traversable_percentage: 80.0)
      create(:world_region, world: world, region_x: 2, region_y: 0, zoom_level: 3,
             dominant_terrain: 'mountain', terrain_composition: { 'mountain' => 100.0 },
             avg_altitude: 200, traversable_percentage: 100.0)
    end

    it 'aggregates terrain composition from children' do
      # Create a hex to make the aggregation run
      create(:world_hex, world: world, globe_hex_id: 1, terrain_type: 'ocean')

      # Now manually trigger aggregation from children
      described_class.send(:aggregate_level_from_children, world, 2, { regions_created: 0 })

      # Check that level 2 regions were created
      level_2_regions = WorldRegion.where(world_id: world.id, zoom_level: 2).all
      expect(level_2_regions).not_to be_empty
    end

    it 'propagates feature flags from children' do
      stats = { regions_created: 0 }
      described_class.send(:aggregate_level_from_children, world, 2, stats)

      # Parent region should have has_road from child
      parent = WorldRegion.where(world_id: world.id, zoom_level: 2).first
      expect(parent.has_road).to be true
    end

    it 'calculates average altitude from children' do
      stats = { regions_created: 0 }
      described_class.send(:aggregate_level_from_children, world, 2, stats)

      parent = WorldRegion.where(world_id: world.id, zoom_level: 2).first
      # Average of 0, 50, 200 = ~83
      expect(parent.avg_altitude).to be_between(80, 90)
    end
  end

  describe 'terrain sampling' do
    context 'when no hexes at location' do
      it 'returns ocean data' do
        # sample_terrain_at now takes (world, center_lat, center_lon)
        result = described_class.send(:sample_terrain_at, world, 45.0, 90.0)

        expect(result[:dominant]).to eq('ocean')
        expect(result[:composition]).to eq({ 'ocean' => 100.0 })
        expect(result[:traversable_pct]).to eq(0.0)
      end
    end

    context 'when hexes exist at location' do
      before do
        # Create hexes with globe_hex_ids and lat/lon near (0, 0)
        create(:world_hex, world: world, globe_hex_id: 1, latitude: 0.0, longitude: 0.0,
               terrain_type: 'grassy_plains', altitude: 100)
        create(:world_hex, world: world, globe_hex_id: 2, latitude: 1.0, longitude: 1.0,
               terrain_type: 'grassy_plains', altitude: 150)
        create(:world_hex, world: world, globe_hex_id: 3, latitude: -1.0, longitude: -1.0,
               terrain_type: 'ocean', altitude: 0)
      end

      it 'returns correct dominant terrain' do
        # Sample at lat=0, lon=0 (should find all 3 hexes within 5 degree radius)
        result = described_class.send(:sample_terrain_at, world, 0.0, 0.0)

        expect(result[:dominant]).to eq('grassy_plains')
      end

      it 'calculates terrain composition' do
        result = described_class.send(:sample_terrain_at, world, 0.0, 0.0)

        expect(result[:composition]).to have_key('grassy_plains')
        expect(result[:composition]).to have_key('ocean')
      end

      it 'calculates average altitude' do
        result = described_class.send(:sample_terrain_at, world, 0.0, 0.0)

        # Should be average of 100, 150, 0 = ~83
        expect(result[:avg_altitude]).to be_between(80, 90)
      end

      it 'calculates traversable percentage' do
        result = described_class.send(:sample_terrain_at, world, 0.0, 0.0)

        # 2/3 hexes are traversable (grassy_plains)
        expect(result[:traversable_pct]).to be_between(60, 70)
      end
    end

    context 'when hex has features' do
      before do
        # Use directional feature columns and set lat/lon at (0, 0)
        create(:world_hex, world: world, globe_hex_id: 1,
               latitude: 0.0, longitude: 0.0,
               terrain_type: 'grassy_plains',
               feature_n: 'road',
               feature_s: 'river')
      end

      it 'detects road feature' do
        result = described_class.send(:sample_terrain_at, world, 0.0, 0.0)

        expect(result[:has_road]).to be true
      end

      it 'detects river feature' do
        result = described_class.send(:sample_terrain_at, world, 0.0, 0.0)

        expect(result[:has_river]).to be true
      end
    end
  end
end
