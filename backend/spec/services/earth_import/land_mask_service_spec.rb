# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EarthImport::LandMaskService do
  def build_service(**opts)
    allow(described_class).to receive(:require_gdal!)
    allow_any_instance_of(described_class).to receive(:load_land_geometry) do |instance|
      instance.instance_variable_set(:@loaded, true)
      instance.instance_variable_set(:@land_geometries, [])
    end
    allow_any_instance_of(described_class).to receive(:build_raster_cache)

    described_class.new('/tmp/land', **opts)
  end

  describe '.require_gdal!' do
    it 'raises a helpful error when GDAL is unavailable' do
      allow(described_class).to receive(:gdal_available?).and_return(false)

      expect { described_class.require_gdal! }
        .to raise_error(EarthImport::LandMaskService::GdalNotAvailableError, /GDAL Ruby bindings not available/)
    end

    it 'does not raise when GDAL is available' do
      allow(described_class).to receive(:gdal_available?).and_return(true)

      expect { described_class.require_gdal! }.not_to raise_error
    end
  end

  describe '#initialize' do
    it 'chooses resolution from subdivisions map when provided' do
      service = build_service(subdivisions: 8)

      expect(service.instance_variable_get(:@resolution)).to eq(0.05)
      expect(service.instance_variable_get(:@raster_width)).to eq(7200)
      expect(service.instance_variable_get(:@raster_height)).to eq(3600)
    end

    it 'uses explicit resolution over subdivision defaults' do
      service = build_service(subdivisions: 10, resolution: 0.2)

      expect(service.instance_variable_get(:@resolution)).to eq(0.2)
      expect(service.instance_variable_get(:@raster_width)).to eq(1800)
      expect(service.instance_variable_get(:@raster_height)).to eq(900)
    end
  end

  describe '#land? and #ocean?' do
    it 'returns false when service is not loaded' do
      service = build_service
      service.instance_variable_set(:@loaded, false)

      expect(service.land?(lat: 10, lon: 20)).to be false
      expect(service.ocean?(lat: 10, lon: 20)).to be true
    end

    it 'uses raster lookup when rasterized cache is present' do
      service = build_service(rasterize: true)

      service.instance_variable_set(:@rasterized, true)
      service.instance_variable_set(:@raster_width, 4)
      service.instance_variable_set(:@raster_height, 2)
      service.instance_variable_set(:@raster_cache, [
                                    [false, false, false, true],
                                    [true, false, false, false]
                                  ])

      expect(service.land?(lat: 80, lon: -90)).to be true
      expect(service.land?(lat: -80, lon: -180)).to be false
      expect(service.ocean?(lat: -80, lon: -180)).to be true
    end
  end

  describe '#rasterized? and #raster_stats' do
    it 'reports rasterized false when cache is missing' do
      service = build_service(rasterize: true)
      service.instance_variable_set(:@raster_cache, nil)

      expect(service.rasterized?).to be_falsey
      expect(service.raster_stats).to be_nil
    end

    it 'returns stats for a populated raster cache' do
      service = build_service(rasterize: true)
      service.instance_variable_set(:@raster_width, 3)
      service.instance_variable_set(:@raster_height, 2)
      service.instance_variable_set(:@resolution, 1.0)
      service.instance_variable_set(:@raster_cache, [
                                    [true, false, true],
                                    [false, false, true]
                                  ])

      stats = service.raster_stats

      expect(stats[:width]).to eq(3)
      expect(stats[:height]).to eq(2)
      expect(stats[:land_pixels]).to eq(3)
      expect(stats[:ocean_pixels]).to eq(3)
      expect(stats[:land_percentage]).to eq(50.0)
    end
  end

  describe 'private cache loading helpers' do
    it 'leaves cache nil when cache file size mismatches expected dimensions' do
      service = build_service
      service.instance_variable_set(:@raster_width, 8)
      service.instance_variable_set(:@raster_height, 8)

      allow(File).to receive(:binread).with('/tmp/bad_cache.bin').and_return('abc')

      service.send(:load_raster_from_file, '/tmp/bad_cache.bin')

      expect(service.instance_variable_get(:@raster_cache)).to be_nil
    end

    it 'unpacks valid bit-packed raster cache data' do
      service = build_service
      service.instance_variable_set(:@raster_width, 8)
      service.instance_variable_set(:@raster_height, 1)

      # 10100000 => [true, false, true, false, false, false, false, false]
      allow(File).to receive(:binread).with('/tmp/good_cache.bin').and_return([0b1010_0000].pack('C'))

      service.send(:load_raster_from_file, '/tmp/good_cache.bin')
      cache = service.instance_variable_get(:@raster_cache)

      expect(cache[0]).to eq([true, false, true, false, false, false, false, false])
    end
  end
end
