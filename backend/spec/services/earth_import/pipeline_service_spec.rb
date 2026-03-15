# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EarthImport::PipelineService do
  let(:world) { create(:world) }
  let(:job) do
    WorldGenerationJob.create(
      world: world,
      job_type: 'earth_import',
      status: 'pending',
      config: Sequel.pg_json({ 'subdivisions' => 2 })
    )
  end
  let(:service) { described_class.new(job) }

  describe '#run' do
    before do
      # Mock the downloader to avoid real downloads
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

      # Mock the LandMaskService to avoid needing actual GDAL/shapefiles
      mock_land_mask = instance_double(EarthImport::LandMaskService, loaded?: true)
      allow(mock_land_mask).to receive(:ocean?) { |lat:, lon:| lat.abs >= 60 || rand >= 0.3 }
      allow(EarthImport::LandMaskService).to receive(:new).and_return(mock_land_mask)
      allow(EarthImport::LandMaskService).to receive(:gdal_available?).and_return(true)

      # Mock the TerrainClassifier to avoid needing the terrain_lookup.bin file
      mock_classifier = instance_double(EarthImport::TerrainClassifier)
      allow(mock_classifier).to receive(:classify) do |elevation:, lat:, lon:|
        if elevation.nil? || elevation < 0
          'ocean'
        elsif lat.abs > 66
          'ice'
        elsif elevation > 0.22
          'mountain'
        elsif elevation > 0.055
          'grassy_hills'
        else
          'grassy_plains'
        end
      end
      allow(mock_classifier).to receive(:apply_to_grid) do |grid, progress_callback: nil, &block|
        callback = progress_callback || block
        total = grid.hexes.length
        grid.hexes.each_with_index do |hex, i|
          lat_deg = hex.lat * 180.0 / Math::PI
          lon_deg = hex.lon * 180.0 / Math::PI
          hex.terrain_type = mock_classifier.classify(
            elevation: hex.elevation || 0,
            lat: lat_deg,
            lon: lon_deg
          )
          callback&.call(i, total) if (i % 100).zero?
        end
      end
      allow(EarthImport::TerrainClassifier).to receive(:new).and_return(mock_classifier)
    end

    it 'sets job status to running then completed' do
      service.run
      expect(job.reload.status).to eq('completed')
    end

    it 'creates WorldHex records' do
      service.run
      expect(WorldHex.where(world_id: world.id).count).to be > 0
    end

    it 'sets varied terrain types' do
      service.run

      terrain_types = WorldHex.where(world_id: world.id).distinct.select_map(:terrain_type)
      expect(terrain_types.length).to be > 1
    end

    it 'updates progress through phases' do
      progress_values = []

      original_update = job.method(:update)
      allow(job).to receive(:update) do |attrs|
        progress_values << attrs[:progress_percentage] if attrs[:progress_percentage]
        original_update.call(attrs)
      end

      service.run

      # Should have progress updates from 0 to 100
      expect(progress_values).to include(0.0)
      expect(progress_values.max).to be >= 90.0
    end

    it 'sets started_at and completed_at timestamps' do
      service.run
      job.reload

      expect(job.started_at).not_to be_nil
      expect(job.completed_at).not_to be_nil
      expect(job.completed_at).to be >= job.started_at
    end
  end

  describe 'error handling' do
    it 'marks job as failed on error' do
      allow_any_instance_of(EarthImport::DataDownloader).to receive(:download_natural_earth)
        .and_raise(EarthImport::DownloadError, 'Network error')

      expect { service.run }.to raise_error(EarthImport::DownloadError)
      expect(job.reload.status).to eq('failed')
      expect(job.error_message).to include('Network error')
    end

    it 'logs error details in error_message' do
      allow_any_instance_of(EarthImport::DataDownloader).to receive(:download_natural_earth)
        .and_raise(StandardError, 'Something went wrong')

      expect { service.run }.to raise_error(StandardError)
      expect(job.reload.error_message).to include('StandardError')
      expect(job.error_message).to include('Something went wrong')
    end
  end

  describe 'grid generation' do
    before do
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

      # Mock the LandMaskService to avoid needing actual GDAL/shapefiles
      mock_land_mask = instance_double(EarthImport::LandMaskService, loaded?: true)
      allow(mock_land_mask).to receive(:ocean?) { |lat:, lon:| lat.abs >= 60 || rand >= 0.3 }
      allow(EarthImport::LandMaskService).to receive(:new).and_return(mock_land_mask)
      allow(EarthImport::LandMaskService).to receive(:gdal_available?).and_return(true)

      # Mock the TerrainClassifier to avoid needing the terrain_lookup.bin file
      mock_classifier = instance_double(EarthImport::TerrainClassifier)
      allow(mock_classifier).to receive(:classify) do |elevation:, lat:, lon:|
        if elevation.nil? || elevation < 0
          'ocean'
        elsif lat.abs > 66
          'ice'
        elsif elevation > 0.22
          'mountain'
        elsif elevation > 0.055
          'grassy_hills'
        else
          'grassy_plains'
        end
      end
      allow(mock_classifier).to receive(:apply_to_grid) do |grid, progress_callback: nil, &block|
        callback = progress_callback || block
        total = grid.hexes.length
        grid.hexes.each_with_index do |hex, i|
          lat_deg = hex.lat * 180.0 / Math::PI
          lon_deg = hex.lon * 180.0 / Math::PI
          hex.terrain_type = mock_classifier.classify(
            elevation: hex.elevation || 0,
            lat: lat_deg,
            lon: lon_deg
          )
          callback&.call(i, total) if (i % 100).zero?
        end
      end
      allow(EarthImport::TerrainClassifier).to receive(:new).and_return(mock_classifier)
    end

    it 'uses subdivisions from job config' do
      # With 2 subdivisions, we get 20 * 4^2 = 320 hexes
      service.run
      expect(WorldHex.where(world_id: world.id).count).to eq(320)
    end

    it 'uses default subdivisions when not specified' do
      job.update(config: Sequel.pg_json({}))
      # Default is 6 subdivisions = 20 * 4^6 = 81,920 hexes
      # This would be too slow for tests, so we check that the grid is created
      expect { service.run }.not_to raise_error
    end
  end

  describe 'database writing' do
    before do
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

      # Mock the LandMaskService to avoid needing actual GDAL/shapefiles
      mock_land_mask = instance_double(EarthImport::LandMaskService, loaded?: true)
      allow(mock_land_mask).to receive(:ocean?) { |lat:, lon:| lat.abs >= 60 || rand >= 0.3 }
      allow(EarthImport::LandMaskService).to receive(:new).and_return(mock_land_mask)
      allow(EarthImport::LandMaskService).to receive(:gdal_available?).and_return(true)

      # Mock the TerrainClassifier to avoid needing the terrain_lookup.bin file
      mock_classifier = instance_double(EarthImport::TerrainClassifier)
      allow(mock_classifier).to receive(:classify) do |elevation:, lat:, lon:|
        if elevation.nil? || elevation < 0
          'ocean'
        elsif lat.abs > 66
          'ice'
        elsif elevation > 0.22
          'mountain'
        elsif elevation > 0.055
          'grassy_hills'
        else
          'grassy_plains'
        end
      end
      allow(mock_classifier).to receive(:apply_to_grid) do |grid, progress_callback: nil, &block|
        callback = progress_callback || block
        total = grid.hexes.length
        grid.hexes.each_with_index do |hex, i|
          lat_deg = hex.lat * 180.0 / Math::PI
          lon_deg = hex.lon * 180.0 / Math::PI
          hex.terrain_type = mock_classifier.classify(
            elevation: hex.elevation || 0,
            lat: lat_deg,
            lon: lon_deg
          )
          callback&.call(i, total) if (i % 100).zero?
        end
      end
      allow(EarthImport::TerrainClassifier).to receive(:new).and_return(mock_classifier)
    end

    it 'clears existing hexes before inserting new ones' do
      # Create some pre-existing hexes using raw insert to avoid model validation issues
      DB[:world_hexes].insert(
        world_id: world.id,
        globe_hex_id: 999_999,
        terrain_type: 'ocean',
        elevation: 0
      )

      old_count = WorldHex.where(world_id: world.id).count
      expect(old_count).to eq(1)

      service.run

      # Should have replaced with new hexes
      new_count = WorldHex.where(world_id: world.id).count
      expect(new_count).to eq(320) # 2 subdivisions
    end

    it 'stores latitude and longitude on hexes' do
      service.run

      hex = WorldHex.where(world_id: world.id).first
      expect(hex.latitude).to be_between(-90, 90)
      expect(hex.longitude).to be_between(-180, 180)
    end

    it 'stores elevation on hexes' do
      service.run

      # At least some hexes should have non-zero elevation
      hexes_with_elevation = WorldHex.where(world_id: world.id).exclude(elevation: 0).count
      expect(hexes_with_elevation).to be > 0
    end
  end
end
