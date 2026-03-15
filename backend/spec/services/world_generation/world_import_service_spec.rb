# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tempfile'

RSpec.describe WorldGeneration::WorldImportService do
  let(:world) { create(:world) }

  let(:sample_json) do
    {
      'metadata' => {
        'seed' => 42,
        'hex_count' => 2,
        'subdivision_level' => 2
      },
      'hexes' => [
        {
          'id' => '2-0-0',
          'q' => 0, 'r' => 0,
          'lat' => 0.5, 'lon' => -1.2,
          'x' => 0.1, 'y' => 0.2, 'z' => 0.9,
          'elevation' => 500.0,
          'temperature' => 20.0,
          'moisture' => 0.6,
          'terrain_type' => 'grassy_plains',
          'river_edges' => %w[n se],
          'river_width' => 1,
          'lake_id' => nil,
          'plate_id' => 3,
          'features' => []
        },
        {
          'id' => '2-0-1',
          'q' => 0, 'r' => 2,
          'lat' => 0.4, 'lon' => -1.1,
          'x' => 0.2, 'y' => 0.3, 'z' => 0.8,
          'elevation' => -100.0,
          'temperature' => 18.0,
          'moisture' => 1.0,
          'terrain_type' => 'ocean',
          'river_edges' => [],
          'river_width' => 0,
          'lake_id' => nil,
          'plate_id' => 1,
          'features' => []
        }
      ],
      'lakes' => []
    }
  end

  describe '#initialize' do
    it 'stores the world and json_path' do
      service = described_class.new(world, '/tmp/test.json')

      expect(service.instance_variable_get(:@world)).to eq(world)
      expect(service.instance_variable_get(:@json_path)).to eq('/tmp/test.json')
    end
  end

  describe '#import' do
    let(:json_path) { "/tmp/test_import_#{Process.pid}_#{Time.now.to_i}.json" }

    before do
      File.write(json_path, JSON.generate(sample_json))
    end

    after do
      File.delete(json_path) if File.exist?(json_path)
    end

    it 'creates WorldHex records from JSON' do
      service = described_class.new(world, json_path)
      service.import

      expect(WorldHex.where(world_id: world.id).count).to eq(2)
    end

    it 'sets terrain_type correctly' do
      service = described_class.new(world, json_path)
      service.import

      # Find hex by terrain_type since the service imports using globe_hex_id
      hex = WorldHex.where(world_id: world.id, terrain_type: 'grassy_plains').first
      expect(hex.terrain_type).to eq('grassy_plains')
    end

    it 'sets temperature from JSON' do
      service = described_class.new(world, json_path)
      service.import

      hex = WorldHex.where(world_id: world.id, terrain_type: 'grassy_plains').first
      expect(hex.temperature).to eq(20.0)
    end

    it 'sets moisture from JSON' do
      service = described_class.new(world, json_path)
      service.import

      hex = WorldHex.where(world_id: world.id, terrain_type: 'grassy_plains').first
      expect(hex.moisture).to eq(0.6)
    end

    it 'sets elevation from JSON' do
      service = described_class.new(world, json_path)
      service.import

      hex = WorldHex.where(world_id: world.id, terrain_type: 'grassy_plains').first
      # elevation is stored in 'altitude' column
      expect(hex.altitude).to eq(500)
    end

    it 'sets river_edges as array' do
      service = described_class.new(world, json_path)
      service.import

      hex = WorldHex.where(world_id: world.id, terrain_type: 'grassy_plains').first
      expect(hex.river_edges).to eq(%w[n se])
    end

    it 'sets river_width from JSON' do
      service = described_class.new(world, json_path)
      service.import

      hex = WorldHex.where(world_id: world.id, terrain_type: 'grassy_plains').first
      expect(hex.river_width).to eq(1)
    end

    it 'sets plate_id from JSON' do
      service = described_class.new(world, json_path)
      service.import

      hex = WorldHex.where(world_id: world.id, terrain_type: 'grassy_plains').first
      expect(hex.plate_id).to eq(3)
    end

    it 'sets latitude and longitude from JSON' do
      service = described_class.new(world, json_path)
      service.import

      hex = WorldHex.where(world_id: world.id, terrain_type: 'grassy_plains').first
      expect(hex.latitude).to eq(0.5)
      expect(hex.longitude).to eq(-1.2)
    end

    it 'clears existing hexes before importing' do
      # Create an existing hex for this world
      create(:world_hex, world: world, globe_hex_id: 999)
      expect(WorldHex.where(world_id: world.id).count).to eq(1)

      service = described_class.new(world, json_path)
      service.import

      # Old hex should be gone, replaced with 2 from JSON
      expect(WorldHex.where(world_id: world.id).count).to eq(2)
      expect(WorldHex.where(world_id: world.id, globe_hex_id: 999).count).to eq(0)
    end

    it 'does not affect hexes from other worlds' do
      other_world = create(:world)
      create(:world_hex, world: other_world, globe_hex_id: 100)

      service = described_class.new(world, json_path)
      service.import

      expect(WorldHex.where(world_id: other_world.id).count).to eq(1)
    end

    context 'with empty hexes array' do
      let(:empty_json) do
        {
          'metadata' => { 'seed' => 42, 'hex_count' => 0 },
          'hexes' => [],
          'lakes' => []
        }
      end

      it 'handles empty hexes gracefully' do
        File.write(json_path, JSON.generate(empty_json))

        service = described_class.new(world, json_path)
        expect { service.import }.not_to raise_error

        expect(WorldHex.where(world_id: world.id).count).to eq(0)
      end
    end

    context 'with invalid terrain strings from Python' do
      let(:invalid_terrain_json) do
        {
          'metadata' => { 'seed' => 42 },
          'hexes' => [
            {
              'id' => '2-0-0',
              'lat' => 0.5, 'lon' => -1.2,
              'elevation' => 500,
              'terrain_type' => 'volcano'
            },
            {
              'id' => '2-0-1',
              'lat' => 0.4, 'lon' => -1.1,
              'elevation' => 200,
              'terrain_type' => 'rift_valley'
            },
            {
              'id' => '2-0-2',
              'lat' => 0.3, 'lon' => -1.0,
              'elevation' => 100,
              'terrain_type' => 'totally_invalid'
            }
          ]
        }
      end

      it 'normalizes volcano to volcanic' do
        File.write(json_path, JSON.generate(invalid_terrain_json))

        service = described_class.new(world, json_path)
        service.import

        hex = WorldHex.where(world_id: world.id, terrain_type: 'volcanic').first
        expect(hex).not_to be_nil
      end

      it 'normalizes rift_valley to rocky_plains' do
        File.write(json_path, JSON.generate(invalid_terrain_json))

        service = described_class.new(world, json_path)
        service.import

        hex = WorldHex.where(world_id: world.id, terrain_type: 'rocky_plains').first
        expect(hex).not_to be_nil
      end

      it 'falls back to default terrain for unknown types' do
        File.write(json_path, JSON.generate(invalid_terrain_json))

        service = described_class.new(world, json_path)
        service.import

        hex = WorldHex.where(world_id: world.id, terrain_type: WorldHex::DEFAULT_TERRAIN).first
        expect(hex).not_to be_nil
      end
    end

    context 'with missing optional fields' do
      let(:minimal_json) do
        {
          'metadata' => { 'seed' => 42 },
          'hexes' => [
            {
              'id' => '1-0-0',
              'q' => 0, 'r' => 0,
              'terrain_type' => 'grassy_plains'
            }
          ]
        }
      end

      it 'handles missing fields with defaults' do
        File.write(json_path, JSON.generate(minimal_json))

        service = described_class.new(world, json_path)
        service.import

        hex = WorldHex.where(world_id: world.id).first
        expect(hex).not_to be_nil
        expect(hex.terrain_type).to eq('grassy_plains')
        expect(hex.river_width).to eq(0)
        expect(hex.river_edges).to eq([])
      end
    end
  end

  describe 'batch import performance' do
    it 'uses batch insert for efficiency' do
      # Generate 100 hexes to test batching
      many_hexes = (0...100).map do |i|
        {
          'id' => "test-#{i}",
          'q' => i % 10, 'r' => (i / 10) * 2, # r must be even for valid hex coords
          'terrain_type' => 'grassy_plains',
          'elevation' => 0
        }
      end

      json_data = {
        'metadata' => { 'seed' => 1, 'hex_count' => 100 },
        'hexes' => many_hexes,
        'lakes' => []
      }

      json_path = "/tmp/batch_import_#{Process.pid}_#{Time.now.to_i}.json"
      File.write(json_path, JSON.generate(json_data))

      begin
        service = described_class.new(world, json_path)
        service.import

        expect(WorldHex.where(world_id: world.id).count).to eq(100)
      ensure
        File.delete(json_path) if File.exist?(json_path)
      end
    end
  end
end
