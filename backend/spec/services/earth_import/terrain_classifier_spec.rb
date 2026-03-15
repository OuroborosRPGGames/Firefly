# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EarthImport::TerrainClassifier do
  # Create a test lookup file that will be used for most specs
  # This file contains grassy_plains (index 4) as the default terrain for all coordinates
  let(:test_lookup_path) { File.join(Dir.tmpdir, "test_terrain_lookup_#{Process.pid}.bin") }

  # Helper to create a test lookup file with customizable terrain
  # @param terrain_idx [Integer] The terrain index to fill the lookup with (default: 4 = grassy_plains)
  def create_test_lookup_file(path, terrain_idx: 4)
    File.open(path, 'wb') do |f|
      f.write([0x54455252].pack('L<'))  # Magic "TERR"
      f.write([1].pack('L<'))           # Version
      f.write([-90.0].pack('e'))        # lat_min
      f.write([90.0].pack('e'))         # lat_max
      f.write([-180.0].pack('e'))       # lon_min
      f.write([180.0].pack('e'))        # lon_max
      f.write([1.0].pack('e'))          # resolution (1 degree)
      f.write([180].pack('L<'))         # rows
      f.write([360].pack('L<'))         # cols
      f.write([terrain_idx].pack('C') * (180 * 360))  # Fill with terrain
    end
  end

  before do
    create_test_lookup_file(test_lookup_path)
    stub_const('EarthImport::TerrainClassifier::LOOKUP_PATH', test_lookup_path)
  end

  after do
    File.delete(test_lookup_path) if File.exist?(test_lookup_path)
  end

  let(:classifier) { described_class.new }

  describe '#classify' do
    it 'returns ocean for negative elevation' do
      expect(classifier.classify(elevation: -0.5, lat: 0, lon: 0)).to eq('ocean')
    end

    it 'returns tundra for high latitude' do
      expect(classifier.classify(elevation: 0.1, lat: 75, lon: 0)).to eq('tundra')
    end

    it 'returns tundra for very high elevation' do
      expect(classifier.classify(elevation: 0.9, lat: 30, lon: 80)).to eq('tundra')
    end

    it 'returns mountain for high elevation' do
      # 0.25 is above mountain threshold (0.22) but below ice threshold (0.39)
      expect(classifier.classify(elevation: 0.25, lat: 45, lon: 10)).to eq('mountain')
    end

    it 'returns grassy_hills for moderate elevation in temperate regions' do
      expect(classifier.classify(elevation: 0.15, lat: 45, lon: 10)).to eq('grassy_hills')
    end

    it 'returns rocky_hills for moderate elevation in high latitudes' do
      expect(classifier.classify(elevation: 0.15, lat: 55, lon: 10)).to eq('rocky_hills')
    end

    it 'returns sandy_coast for very low elevation in warm latitudes' do
      expect(classifier.classify(elevation: 0.01, lat: 30, lon: 0)).to eq('sandy_coast')
    end

    it 'returns rocky_coast for very low elevation in high latitudes' do
      expect(classifier.classify(elevation: 0.01, lat: 55, lon: 0)).to eq('rocky_coast')
    end

    it 'returns lake for narrow low elevation band' do
      expect(classifier.classify(elevation: 0.017, lat: 40, lon: 0)).to eq('lake')
    end

    it 'returns terrain from lookup for low elevation land' do
      # The test lookup file is filled with grassy_plains (index 4)
      expect(classifier.classify(elevation: 0.04, lat: 40, lon: -100)).to eq('grassy_plains')
    end

    it 'returns valid terrain types' do
      # Test various combinations all return valid types
      test_cases = [
        { elevation: -0.3, lat: 0, lon: 0 },      # ocean
        { elevation: 0.01, lat: 30, lon: 0 },     # sandy_coast
        { elevation: 0.01, lat: 55, lon: 0 },     # rocky_coast
        { elevation: 0.017, lat: 40, lon: 0 },    # lake
        { elevation: 0.1, lat: 80, lon: 0 },      # polar (tundra)
        { elevation: 0.5, lat: 35, lon: 80 },     # high mountain (tundra)
        { elevation: 0.25, lat: 45, lon: 10 },    # mountain
        { elevation: 0.04, lat: 50, lon: 0 },     # temperate (from lookup)
      ]

      test_cases.each do |params|
        result = classifier.classify(**params)
        expect(WorldHex::TERRAIN_TYPES).to include(result),
          "Expected #{result} to be in TERRAIN_TYPES for #{params}"
      end
    end
  end

  describe '#apply_to_grid' do
    let(:grid) { WorldGeneration::GlobeHexGrid.new(nil, subdivisions: 2) }

    before do
      # Set elevations on grid first
      grid.hexes.each { |hex| hex.elevation = 0.1 }
    end

    it 'sets terrain_type on all hexes' do
      classifier.apply_to_grid(grid)

      grid.hexes.each do |hex|
        expect(hex.terrain_type).not_to be_nil
        expect(WorldHex::TERRAIN_TYPES).to include(hex.terrain_type)
      end
    end

    it 'produces variety of terrain types' do
      # Set varied elevations
      grid.hexes.each_with_index do |hex, i|
        hex.elevation = (i % 10) / 10.0 - 0.3  # Range from -0.3 to 0.6
      end

      classifier.apply_to_grid(grid)

      terrain_types = grid.hexes.map(&:terrain_type).uniq
      expect(terrain_types.length).to be > 2
    end
  end

  describe 'lookup-based classification' do
    describe 'LookupMissingError' do
      it 'raises LookupMissingError when lookup file is missing' do
        stub_const('EarthImport::TerrainClassifier::LOOKUP_PATH', '/nonexistent/path.bin')

        expect { described_class.new }.to raise_error(
          EarthImport::TerrainClassifier::LookupMissingError,
          /Terrain lookup file not found.*Run: python scripts\/generate_terrain_lookup\.py/
        )
      end
    end

    describe 'loading binary file' do
      it 'loads the lookup file successfully' do
        expect { described_class.new }.not_to raise_error
      end

      it 'raises error for invalid magic number' do
        # Overwrite the file with invalid magic number
        File.open(test_lookup_path, 'r+b') { |f| f.write([0x00000000].pack('L<')) }
        expect { described_class.new }.to raise_error(/Invalid terrain lookup file/)
      end
    end

    describe '#lookup_terrain' do
      subject(:classifier) { described_class.new }

      it 'returns terrain at coordinates' do
        result = classifier.send(:lookup_terrain, 0, 0)
        expect(result).to eq('grassy_plains')
      end

      it 'clamps coordinates to bounds' do
        expect(classifier.send(:lookup_terrain, 100, 200)).to eq('grassy_plains')
        expect(classifier.send(:lookup_terrain, -100, -200)).to eq('grassy_plains')
      end
    end
  end
end
