# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EarthImport::ElevationMapper do
  describe '#sample' do
    let(:mapper) { described_class.new(raster_path: nil) }

    it 'returns estimated elevation for land areas' do
      # Europe - should be moderate elevation
      elevation = mapper.sample(45.0, 10.0)
      expect(elevation).to be_a(Numeric)
      expect(elevation).to be > 0
    end

    it 'returns negative elevation for ocean areas' do
      # Pacific Ocean
      elevation = mapper.sample(0.0, -160.0)
      expect(elevation).to be < 0
    end

    it 'returns moderate elevation for mountain regions' do
      # Alps region
      elevation = mapper.sample(46.0, 10.0)
      expect(elevation).to be > 500
    end
  end

  describe '#normalize' do
    let(:mapper) { described_class.new(raster_path: nil) }

    it 'normalizes Mount Everest to approximately 1.0' do
      # Mount Everest ~8849m
      normalized = mapper.normalize(8849)
      expect(normalized).to be_within(0.1).of(1.0)
    end

    it 'normalizes sea level to approximately 0.0' do
      normalized = mapper.normalize(0)
      expect(normalized).to be_within(0.1).of(0.0)
    end

    it 'normalizes deep ocean to approximately -1.0' do
      # Mariana Trench ~-11000m
      normalized = mapper.normalize(-11000)
      expect(normalized).to be_within(0.1).of(-1.0)
    end

    it 'handles nil elevation' do
      normalized = mapper.normalize(nil)
      expect(normalized).to eq(0.0)
    end
  end

  describe '#apply_to_grid' do
    let(:mapper) { described_class.new(raster_path: nil) }
    let(:grid) { WorldGeneration::GlobeHexGrid.new(nil, subdivisions: 2) }

    it 'sets elevation on all hexes in grid' do
      mapper.apply_to_grid(grid)

      grid.hexes.each do |hex|
        expect(hex.elevation).not_to be_nil
        expect(hex.elevation).to be_between(-1.0, 1.0)
      end
    end

    it 'produces varied elevation values' do
      mapper.apply_to_grid(grid)

      elevations = grid.hexes.map(&:elevation).uniq
      expect(elevations.length).to be > 1
    end
  end
end
