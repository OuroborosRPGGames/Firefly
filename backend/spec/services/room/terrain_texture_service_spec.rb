# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TerrainTextureService do
  let(:world) { create(:world) }
  let(:service) do
    svc = described_class.new(world)
    svc.calculate_dimensions
    svc
  end

  describe '#initialize' do
    it 'stores the world' do
      expect(service.world).to eq(world)
    end
  end

  describe '#generate' do
    context 'when world has no hexes' do
      it 'returns ocean texture' do
        allow(service).to receive(:generate_ocean_texture).and_return('ocean_png')

        result = service.generate

        expect(result).to eq('ocean_png')
      end
    end

    context 'when world has globe hexes covering the sphere' do
      before do
        # Create globe hexes covering the sphere
        latitudes = [-80, -40, 0, 40, 80]
        longitudes = [-180, -90, 0, 90, 180]
        id = 0

        latitudes.each do |lat|
          longitudes.each do |lon|
            create(:world_hex,
                   world: world,
                   globe_hex_id: id,
                   latitude: lat.to_f,
                   longitude: lon.to_f,
                   terrain_type: lat.abs > 60 ? 'tundra' : 'grassy_plains')
            id += 1
          end
        end
      end

      it 'creates a valid PNG texture' do
        result = service.generate

        expect(result).to be_a(String)
        expect(result.bytes[0..3]).to eq([137, 80, 78, 71]) # PNG magic bytes
      end

      it 'renders hexes using latitude/longitude lookup' do
        expect { service.generate }.not_to raise_error
      end
    end

    context 'when world has many hexes and ChunkyPNG is available' do
      let(:service) { described_class.new(world) }

      before do
        # Stub hex count before generate is called (before calculate_dimensions caches)
        allow(world).to receive_message_chain(:world_hexes_dataset, :count).and_return(5_000_000)
        allow(service).to receive(:chunky_png_available?).and_return(true)
        allow(service).to receive(:generate_pixel_by_pixel).and_return('large_world_png')
      end

      it 'uses pixel-by-pixel generation for large worlds' do
        result = service.generate

        expect(result).to eq('large_world_png')
      end
    end
  end

  describe '#chunky_png_available?' do
    it 'returns true when ChunkyPNG can be required' do
      # ChunkyPNG is in the Gemfile, so this should work
      expect(service.chunky_png_available?).to be true
    end
  end

  describe '#generate_from_hexes_chunky' do
    let(:png) { ChunkyPNG::Image.new(service.width, service.height, ChunkyPNG::Color::BLACK) }

    context 'when no hexes exist' do
      it 'returns blank image' do
        result = service.generate_from_hexes_chunky(png)

        expect(result).to be_a(String)
      end
    end

    context 'when hexes exist with latitude/longitude' do
      before do
        create(:world_hex, world: world, globe_hex_id: 0, latitude: 0.0, longitude: 0.0, terrain_type: 'ocean')
        create(:world_hex, world: world, globe_hex_id: 1, latitude: 10.0, longitude: 10.0, terrain_type: 'grassy_plains')
      end

      it 'returns PNG with hex data' do
        result = service.generate_from_hexes_chunky(png)

        expect(result).to be_a(String)
        expect(result.bytes[0..3]).to eq([137, 80, 78, 71]) # PNG magic bytes
      end
    end
  end

  describe '#draw_filled_ellipse' do
    let(:png) { ChunkyPNG::Image.new(100, 100, ChunkyPNG::Color::BLACK) }
    let(:color) { ChunkyPNG::Color.rgb(255, 0, 0) }

    before do
      # draw_filled_ellipse uses @width and @height for wrapping
      service.instance_variable_set(:@width, 100)
      service.instance_variable_set(:@height, 100)
    end

    it 'draws an ellipse on the image' do
      service.draw_filled_ellipse(png, 50, 50, 10, 5, color)

      # Center pixel should be the color
      expect(png[50, 50]).to eq(color)
    end

    it 'handles ellipse at edge of image' do
      # Should not raise error
      expect {
        service.draw_filled_ellipse(png, 0, 0, 10, 5, color)
      }.not_to raise_error
    end
  end

  describe '#color_to_chunky' do
    it 'converts hex color to ChunkyPNG color' do
      color = service.color_to_chunky('#ff0000')

      expect(color).to eq(ChunkyPNG::Color.rgb(255, 0, 0))
    end

    it 'handles lowercase hex' do
      color = service.color_to_chunky('#00ff00')

      expect(color).to eq(ChunkyPNG::Color.rgb(0, 255, 0))
    end
  end

  describe '#terrain_to_chunky' do
    it 'returns correct color for ocean' do
      color = service.terrain_to_chunky('ocean')
      expected = service.color_to_chunky('#2d5f8a')

      expect(color).to eq(expected)
    end

    it 'returns correct color for grassy_plains' do
      color = service.terrain_to_chunky('grassy_plains')
      expected = service.color_to_chunky('#a8b878')

      expect(color).to eq(expected)
    end

    it 'returns unknown color for invalid terrain' do
      color = service.terrain_to_chunky('invalid_terrain')
      expected = service.color_to_chunky('#4a4a4a')

      expect(color).to eq(expected)
    end
  end

  describe '#pixel_to_latlon' do
    it 'converts center pixel to equator/prime meridian' do
      lat, lon = service.pixel_to_latlon(service.width / 2, service.height / 2)

      expect(lat).to be_within(0.1).of(0.0)
      expect(lon).to be_within(0.1).of(0.0)
    end

    it 'converts top-left pixel to north pole / dateline' do
      lat, lon = service.pixel_to_latlon(0, 0)

      expect(lat).to be_within(0.1).of(90.0)
      expect(lon).to be_within(0.1).of(-180.0)
    end

    it 'converts bottom-right pixel to south pole / dateline' do
      lat, lon = service.pixel_to_latlon(service.width - 1, service.height - 1)

      expect(lat).to be_within(0.5).of(-90.0)
      expect(lon).to be_within(0.5).of(180.0)
    end
  end

  describe '#latlon_to_pixel' do
    it 'converts equator/prime meridian to center pixel' do
      x, y = service.latlon_to_pixel(0.0, 0.0)

      expect(x).to eq(service.width / 2)
      expect(y).to eq(service.height / 2)
    end

    it 'converts north pole to top of image' do
      _x, y = service.latlon_to_pixel(90.0, 0.0)

      expect(y).to eq(0)
    end

    it 'converts south pole to bottom of image' do
      _x, y = service.latlon_to_pixel(-90.0, 0.0)

      # Y coordinate is clamped to height - 1 since pixel indices are 0-based
      expect(y).to eq(service.height - 1)
    end
  end

  describe 'TERRAIN_COLORS' do
    it 'has colors for all expected terrain types' do
      expected_terrains = %w[
        ocean lake rocky_coast sandy_coast grassy_plains rocky_plains
        light_forest dense_forest jungle swamp mountain grassy_hills
        rocky_hills tundra desert volcanic urban light_urban unknown
      ]

      expected_terrains.each do |terrain|
        expect(described_class::TERRAIN_COLORS).to have_key(terrain)
      end
    end
  end

  describe 'constants' do
    it 'has correct max dimensions' do
      expect(described_class::MAX_WIDTH).to eq(2448)
      expect(described_class::MAX_HEIGHT).to eq(1224)
    end

    it 'has minimum dimensions' do
      expect(described_class::MIN_WIDTH).to eq(1024)
      expect(described_class::MIN_HEIGHT).to eq(512)
    end

    it 'has target pixels constant' do
      expect(described_class::TARGET_PIXELS).to eq(3_000_000)
    end
  end
end
