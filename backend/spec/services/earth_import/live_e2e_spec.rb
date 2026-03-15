# frozen_string_literal: true

require 'spec_helper'

# Live end-to-end test that uses actual data files (terrain_lookup.bin).
# These tests are slower and depend on external files, so they're tagged.
#
# Run with: bundle exec rspec spec/services/earth_import/live_e2e_spec.rb
RSpec.describe 'Earth Import Live E2E', type: :integration do
  let(:world) { create(:world, name: 'Earth E2E Test') }

  # Skip if terrain lookup file doesn't exist
  before do
    lookup_path = File.join(__dir__, '../../../data/terrain_lookup.bin')
    skip "Terrain lookup file not found. Run: ruby scripts/generate_terrain_lookup.rb" unless File.exist?(lookup_path)
  end

  describe 'full pipeline with real terrain classifier' do
    before do
      # Mock only the network-dependent services (downloaders)
      allow_any_instance_of(EarthImport::DataDownloader).to receive(:download_natural_earth).and_return({
        coastlines: '/tmp/mock',
        lakes: '/tmp/mock',
        land: '/tmp/mock',
        land_cover: '/tmp/mock'
      })
      allow_any_instance_of(EarthImport::DataDownloader).to receive(:download_hydrosheds).and_return({
        rivers: '/tmp/mock'
      })
      allow_any_instance_of(EarthImport::RiverTracer).to receive(:load_from_shapefile).and_return([])

      # Mock the LandMaskService with realistic ocean distribution (~70%)
      mock_land_mask = instance_double(EarthImport::LandMaskService, loaded?: true)
      allow(mock_land_mask).to receive(:ocean?) do |lat:, lon:|
        # Real Earth-like distribution
        # Oceans dominate in southern hemisphere and Pacific
        if lon > -180 && lon < -100 # Pacific
          lat < 0 || lat > 50 || rand >= 0.15
        elsif lon > -30 && lon < 60 # Atlantic/Europe/Africa
          rand >= 0.35
        else
          rand >= 0.25
        end
      end
      allow(EarthImport::LandMaskService).to receive(:new).and_return(mock_land_mask)
      allow(EarthImport::LandMaskService).to receive(:gdal_available?).and_return(true)

      # Use REAL terrain classifier (this is the point of this test!)
      # It will use the terrain_lookup.bin file we generated
    end

    it 'imports Earth with realistic terrain from lookup file' do
      job = WorldGenerationJob.create(
        world: world,
        job_type: 'earth_import',
        status: 'pending',
        config: Sequel.pg_json({ 'subdivisions' => 2 })
      )

      service = EarthImport::PipelineService.new(job)
      service.run

      # Verify job completed
      job.reload
      expect(job.status).to eq('completed')

      # Verify hexes created (320 for 2 subdivisions)
      hexes = WorldHex.where(world_id: world.id)
      expect(hexes.count).to eq(320)

      # Verify terrain variety - should have multiple terrain types
      terrain_counts = {}
      hexes.select(:terrain_type).group_and_count(:terrain_type).all.each do |row|
        terrain_counts[row[:terrain_type]] = row[:count]
      end

      puts "\nTerrain distribution:"
      terrain_counts.sort_by { |_, v| -v }.each do |terrain, count|
        pct = (count.to_f / 320 * 100).round(1)
        puts "  #{terrain}: #{count} (#{pct}%)"
      end

      # Should have ocean (sea level hexes)
      expect(terrain_counts.keys).to include('ocean'),
                                      "Expected ocean terrain, got: #{terrain_counts.keys.join(', ')}"

      # Should have at least 3 different terrain types
      expect(terrain_counts.keys.length).to be >= 3,
                                             "Expected at least 3 terrain types, got: #{terrain_counts.keys.join(', ')}"

      # Should have some land terrain (not 100% ocean)
      land_count = terrain_counts.reject { |k, _| k == 'ocean' }.values.sum
      expect(land_count).to be > 0, 'Expected some land terrain'
    end

    it 'classifies terrain based on latitude and biome lookup' do
      job = WorldGenerationJob.create(
        world: world,
        job_type: 'earth_import',
        status: 'pending',
        config: Sequel.pg_json({ 'subdivisions' => 3 })  # 1280 hexes for better distribution
      )

      service = EarthImport::PipelineService.new(job)
      service.run

      # Get all hexes with their coordinates
      hexes = WorldHex.where(world_id: world.id).all

      # Group by latitude bands
      polar_hexes = hexes.select { |h| h.latitude && h.latitude.abs > 60 }
      temperate_hexes = hexes.select { |h| h.latitude && h.latitude.abs > 23.5 && h.latitude.abs <= 60 }
      tropical_hexes = hexes.select { |h| h.latitude && h.latitude.abs <= 23.5 }

      puts "\nLatitude band analysis:"
      puts "  Polar (>60): #{polar_hexes.length} hexes"
      puts "  Temperate (23.5-60): #{temperate_hexes.length} hexes"
      puts "  Tropical (0-23.5): #{tropical_hexes.length} hexes"

      # Polar regions should have tundra (unless all ocean)
      if polar_hexes.any? { |h| h.terrain_type != 'ocean' }
        polar_land_types = polar_hexes.reject { |h| h.terrain_type == 'ocean' }.map(&:terrain_type)
        expect(polar_land_types).to include('tundra'),
                                    "Expected tundra in polar land, got: #{polar_land_types.uniq.join(', ')}"
      end

      # Temperate should have forests or grasslands (if any land)
      temperate_types = %w[dense_forest light_forest grassy_plains grassy_hills rocky_hills desert]
      if temperate_hexes.any? { |h| h.terrain_type != 'ocean' }
        temperate_land = temperate_hexes.reject { |h| h.terrain_type == 'ocean' }.map(&:terrain_type).uniq
        expect(temperate_land & temperate_types).not_to be_empty,
                                                        "Expected temperate terrain, got: #{temperate_land.join(', ')}"
      end

      # Tropical should have jungle or forests (if any land)
      tropical_types = %w[jungle dense_forest light_forest grassy_plains swamp]
      if tropical_hexes.any? { |h| h.terrain_type != 'ocean' }
        tropical_land = tropical_hexes.reject { |h| h.terrain_type == 'ocean' }.map(&:terrain_type).uniq
        expect(tropical_land & tropical_types).not_to be_empty,
                                                      "Expected tropical terrain, got: #{tropical_land.join(', ')}"
      end
    end

    it 'handles larger grid sizes' do
      # Test with 4 subdivisions (5120 hexes) - still reasonable for test
      job = WorldGenerationJob.create(
        world: world,
        job_type: 'earth_import',
        status: 'pending',
        config: Sequel.pg_json({ 'subdivisions' => 4 })
      )

      start_time = Time.now
      service = EarthImport::PipelineService.new(job)
      service.run
      elapsed = Time.now - start_time

      job.reload
      expect(job.status).to eq('completed')

      hexes = WorldHex.where(world_id: world.id)
      expect(hexes.count).to eq(5120)

      puts "\nLarger grid performance:"
      puts "  Hexes: 5120"
      puts "  Time: #{elapsed.round(2)}s"
      puts "  Rate: #{(5120 / elapsed).round(0)} hexes/sec"
    end
  end
end
