# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldGeneration::PipelineService do
  # Use small subdivision count (2 = 320 hexes) for fast testing
  # Production uses 5 (~20,000 hexes)
  let(:test_subdivisions) { 2 }
  let(:world) { create(:world) }
  let(:job) do
    WorldGenerationJob.create(
      world_id: world.id,
      job_type: 'random_procedural',
      status: 'pending',
      config: { 'preset' => 'earth_like', 'seed' => 12345, 'subdivisions' => test_subdivisions }
    )
  end
  let(:service) { described_class.new(job) }

  describe 'constants' do
    it 'defines PHASES in correct order' do
      expect(described_class::PHASES).to eq(%w[tectonics elevation climate rivers biomes])
    end

    it 'has DEFAULT_SUBDIVISIONS' do
      expect(described_class::DEFAULT_SUBDIVISIONS).to eq(5)
    end
  end

  describe '#initialize' do
    it 'sets up the job reference' do
      expect(service.instance_variable_get(:@job)).to eq(job)
    end

    it 'loads the preset config' do
      config = service.instance_variable_get(:@config)
      expect(config[:name]).to eq('Earth-like')
    end

    it 'uses seed from job config' do
      expect(service.instance_variable_get(:@seed)).to eq(12345)
    end

    it 'generates random seed when not provided' do
      job_without_seed = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'random_procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'subdivisions' => test_subdivisions }
      )
      svc = described_class.new(job_without_seed)
      expect(svc.instance_variable_get(:@seed)).to be_a(Integer)
    end

    it 'uses subdivisions from config' do
      expect(service.instance_variable_get(:@subdivisions)).to eq(test_subdivisions)
    end

    it 'defaults subdivisions to DEFAULT_SUBDIVISIONS when not provided' do
      job_without_subdivisions = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'random_procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'seed' => 12345 }
      )
      svc = described_class.new(job_without_subdivisions)
      expect(svc.instance_variable_get(:@subdivisions)).to eq(5)
    end

    it 'defaults to earth_like preset when not specified' do
      job_without_preset = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'random_procedural',
        status: 'pending',
        config: { 'seed' => 12345, 'subdivisions' => test_subdivisions }
      )
      svc = described_class.new(job_without_preset)
      config = svc.instance_variable_get(:@config)
      expect(config[:name]).to eq('Earth-like')
    end

    it 'does not have use_flat_grid or world_size instance variables' do
      # These were removed as part of globe-only conversion
      expect(service.instance_variable_defined?(:@use_flat_grid)).to be false
      expect(service.instance_variable_defined?(:@world_size)).to be false
    end

    it 'ignores flat_grid config option' do
      job_with_flat = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'random_procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'flat_grid' => true, 'subdivisions' => test_subdivisions }
      )
      svc = described_class.new(job_with_flat)
      # Should not have @use_flat_grid set
      expect(svc.instance_variable_defined?(:@use_flat_grid)).to be false
    end

    it 'ignores high_res config option (formerly enabled flat grid)' do
      job_with_high_res = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'random_procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'high_res' => true, 'subdivisions' => test_subdivisions }
      )
      svc = described_class.new(job_with_high_res)
      # Should not have @use_flat_grid set
      expect(svc.instance_variable_defined?(:@use_flat_grid)).to be false
    end
  end

  describe 'globe grid only' do
    it 'always uses GlobeHexGrid even if flat_grid config is true' do
      job_with_flat = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'random_procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'flat_grid' => true, 'subdivisions' => test_subdivisions }
      )
      svc = described_class.new(job_with_flat)
      svc.run

      # Should have used GlobeHexGrid, which sets globe_hex_id on all hexes
      job_with_flat.reload
      expect(job_with_flat.status).to eq('completed')

      # Verify globe_hex_id is set (GlobeHexGrid sets this, FlatHexGrid would not)
      hexes = WorldHex.where(world_id: world.id)
      expect(hexes.count).to eq(20 * (4**test_subdivisions))
      expect(hexes.exclude(globe_hex_id: nil).count).to eq(hexes.count)
    end

    it 'always runs aggregate_regions regardless of grid type' do
      expect_any_instance_of(described_class).to receive(:aggregate_regions).and_call_original
      service.run
    end

    it 'always runs generate_texture regardless of grid type' do
      expect_any_instance_of(described_class).to receive(:generate_texture).and_call_original
      service.run
    end
  end

  describe '#run' do
    it 'completes successfully' do
      service.run
      job.reload
      expect(job.status).to eq('completed')
    end

    it 'sets job status to running at start' do
      allow(service).to receive(:run_tectonics_phase) do
        job.reload
        expect(job.status).to eq('running')
        # Mock the grid creation
        service.instance_variable_set(:@grid, double('grid',
          hexes: [],
          each_hex: nil,
          to_db_records: []
        ))
      end
      allow(service).to receive(:run_elevation_phase)
      allow(service).to receive(:run_climate_phase)
      allow(service).to receive(:run_rivers_phase)
      allow(service).to receive(:run_biomes_phase)

      service.run
    end

    it 'sets started_at timestamp' do
      service.run
      job.reload
      expect(job.started_at).not_to be_nil
    end

    it 'updates progress through phases' do
      progress_updates = []
      allow(job).to receive(:update) do |attrs|
        progress_updates << attrs[:progress_percentage] if attrs[:progress_percentage]
        job.values.merge!(attrs)
      end

      service.run

      # Progress should increase through: tectonics (0-20), elevation (20-40),
      # climate (40-60), rivers (60-75), biomes (75-85), saving (85-95+)
      expect(progress_updates).to include(0, 20, 40, 60, 75, 85)
    end

    it 'tracks current phase in config' do
      phases_seen = []
      allow(job).to receive(:update) do |attrs|
        if attrs[:config] && attrs[:config]['phase']
          phases_seen << attrs[:config]['phase']
        end
        job.values.merge!(attrs)
      end

      service.run

      expect(phases_seen).to include('tectonics', 'elevation', 'climate', 'rivers', 'biomes', 'saving')
    end

    it 'records completed phases' do
      service.run
      job.reload
      expect(job.config['phases_complete']).to eq(%w[tectonics elevation climate rivers biomes])
    end

    it 'stores seed in config for reproducibility' do
      service.run
      job.reload
      expect(job.config['seed']).to eq(12345)
    end

    it 'creates WorldHex records' do
      expect { service.run }.to change { WorldHex.where(world_id: world.id).count }
    end

    it 'generates expected number of hexes' do
      service.run
      # 2 subdivisions = 20 * 4^2 = 320 hexes
      expected_count = 20 * (4**test_subdivisions)
      expect(WorldHex.where(world_id: world.id).count).to eq(expected_count)
    end

    it 'generates varied terrain types' do
      service.run
      terrain_types = WorldHex.where(world_id: world.id).select_map(:terrain_type).uniq
      expect(terrain_types.length).to be > 3
    end

    it 'generates hexes with valid terrain types' do
      service.run
      terrain_types = WorldHex.where(world_id: world.id).select_map(:terrain_type).uniq
      terrain_types.each do |terrain|
        expect(WorldHex::TERRAIN_TYPES).to include(terrain)
      end
    end

    it 'sets elevation on hexes' do
      service.run
      hexes_with_elevation = WorldHex.where(world_id: world.id).exclude(elevation: nil).count
      total_hexes = WorldHex.where(world_id: world.id).count
      expect(hexes_with_elevation).to eq(total_hexes)
    end

    it 'updates total_regions and completed_regions' do
      service.run
      job.reload
      expect(job.total_regions).to be > 0
      expect(job.completed_regions).to eq(job.total_regions)
    end
  end

  describe 'phase ordering' do
    it 'runs phases in correct order' do
      phase_order = []

      allow(service).to receive(:run_tectonics_phase).and_wrap_original do |method|
        phase_order << :tectonics
        method.call
      end
      allow(service).to receive(:run_elevation_phase).and_wrap_original do |method|
        phase_order << :elevation
        method.call
      end
      allow(service).to receive(:run_climate_phase).and_wrap_original do |method|
        phase_order << :climate
        method.call
      end
      allow(service).to receive(:run_rivers_phase).and_wrap_original do |method|
        phase_order << :rivers
        method.call
      end
      allow(service).to receive(:run_biomes_phase).and_wrap_original do |method|
        phase_order << :biomes
        method.call
      end

      service.run

      expect(phase_order).to eq(%i[tectonics elevation climate rivers biomes])
    end
  end

  describe 'database write' do
    it 'clears existing hexes before writing new ones' do
      # Create some existing hexes with globe_hex_ids
      create(:world_hex, world: world, globe_hex_id: 1)
      create(:world_hex, world: world, globe_hex_id: 2)
      expect(WorldHex.where(world_id: world.id).count).to eq(2)

      service.run

      # Old hexes should be deleted, new ones created
      expected_count = 20 * (4**test_subdivisions)
      expect(WorldHex.where(world_id: world.id).count).to eq(expected_count)
    end

    it 'performs bulk insert in batches' do
      # With 320 hexes and 1000 batch size, should be 1 batch
      expect(WorldHex).to receive(:multi_insert).at_least(:once)
      service.run
    end

    it 'sets globe_hex_id on WorldHex records' do
      service.run
      hexes_with_globe_id = WorldHex.where(world_id: world.id).exclude(globe_hex_id: nil).count
      total_hexes = WorldHex.where(world_id: world.id).count
      expect(hexes_with_globe_id).to eq(total_hexes)
    end

    it 'sets latitude and longitude on WorldHex records' do
      service.run
      hex = WorldHex.where(world_id: world.id).first
      expect(hex.latitude).not_to be_nil
      expect(hex.longitude).not_to be_nil
      # Valid lat/lon ranges
      expect(hex.latitude).to be_between(-90.0, 90.0)
      expect(hex.longitude).to be_between(-180.0, 180.0)
    end
  end

  describe 'error handling' do
    it 'marks job as failed on error' do
      allow(service).to receive(:run_tectonics_phase).and_raise('Test error')

      expect { service.run }.not_to raise_error

      job.reload
      expect(job.status).to eq('failed')
      expect(job.error_message).to include('Test error')
    end

    it 'stores error details with backtrace' do
      allow(service).to receive(:run_elevation_phase).and_raise(StandardError, 'Elevation failed')

      service.run

      job.reload
      expect(job.error_details).not_to be_nil
    end

    it 'logs error with context' do
      allow(service).to receive(:run_climate_phase).and_raise('Climate simulation error')

      expect { service.run }.to output(/\[WorldGeneration\] Pipeline failed/).to_stderr
    end

    it 'handles empty database records gracefully' do
      # Mock the grid to return empty records during write phase
      # but still allow normal generation to proceed
      original_to_db_records = nil

      allow_any_instance_of(WorldGeneration::GlobeHexGrid).to receive(:to_db_records) do |grid|
        # Return empty array to simulate no records to insert
        []
      end

      # Should complete without error even with no records to insert
      expect { service.run }.not_to raise_error
      job.reload
      expect(job.status).to eq('completed')
      # No hexes should be created when records are empty
      expect(WorldHex.where(world_id: world.id).count).to eq(0)
    end

    it 'handles error in biomes phase after other phases complete' do
      allow(service).to receive(:run_biomes_phase).and_raise('Biome mapping failed')

      service.run

      job.reload
      expect(job.status).to eq('failed')
      # Earlier phases should have completed
      expect(job.config['phases_complete']).to include('tectonics', 'elevation', 'climate', 'rivers')
      expect(job.config['phases_complete']).not_to include('biomes')
    end
  end

  describe 'deterministic generation' do
    it 'produces same results with same seed' do
      # First run
      service.run
      terrain_types_1 = WorldHex.where(world_id: world.id)
                                .order(:globe_hex_id)
                                .select_map(:terrain_type)

      # Clear hexes
      WorldHex.where(world_id: world.id).delete

      # Create new job with same seed
      job2 = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'random_procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'seed' => 12345, 'subdivisions' => test_subdivisions }
      )
      service2 = described_class.new(job2)
      service2.run

      terrain_types_2 = WorldHex.where(world_id: world.id)
                                .order(:globe_hex_id)
                                .select_map(:terrain_type)

      expect(terrain_types_1).to eq(terrain_types_2)
    end

    it 'produces different results with different seeds' do
      # First run with seed 12345
      service.run
      terrain_types_1 = WorldHex.where(world_id: world.id)
                                .order(:globe_hex_id)
                                .select_map(:terrain_type)

      # Clear hexes
      WorldHex.where(world_id: world.id).delete

      # Create new job with different seed
      job2 = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'random_procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'seed' => 99999, 'subdivisions' => test_subdivisions }
      )
      service2 = described_class.new(job2)
      service2.run

      terrain_types_2 = WorldHex.where(world_id: world.id)
                                .order(:globe_hex_id)
                                .select_map(:terrain_type)

      # Results should differ
      expect(terrain_types_1).not_to eq(terrain_types_2)
    end
  end

  describe 'with different presets' do
    %w[pangaea archipelago ice_age waterworld arid].each do |preset|
      context "preset: #{preset}" do
        let(:job) do
          WorldGenerationJob.create(
            world_id: world.id,
            job_type: 'random_procedural',
            status: 'pending',
            config: { 'preset' => preset, 'seed' => 12345, 'subdivisions' => test_subdivisions }
          )
        end

        it 'completes successfully' do
          service.run
          job.reload
          expect(job.status).to eq('completed')
        end

        it 'generates appropriate terrain distribution' do
          service.run

          terrain_counts = WorldHex.where(world_id: world.id)
                                   .group_and_count(:terrain_type)
                                   .to_h { |r| [r[:terrain_type], r[:count]] }
          total = terrain_counts.values.sum

          ocean_ratio = (terrain_counts['ocean'] || 0).to_f / total

          preset_config = WorldGeneration::PresetConfig.for(preset)

          # Ocean coverage should roughly match preset (with some tolerance)
          case preset
          when 'waterworld'
            expect(ocean_ratio).to be > 0.5 # Waterworld has 92% ocean target
          when 'arid'
            expect(ocean_ratio).to be < 0.7 # Arid has 45% ocean target
          when 'archipelago'
            expect(ocean_ratio).to be > 0.5 # Archipelago has 85% ocean target
          end
        end
      end
    end
  end

  describe 'integration with generator components' do
    it 'uses TectonicsGenerator' do
      expect(WorldGeneration::TectonicsGenerator).to receive(:new).and_call_original
      service.run
    end

    it 'uses ElevationGenerator' do
      expect(WorldGeneration::ElevationGenerator).to receive(:new).and_call_original
      service.run
    end

    it 'uses ClimateSimulator' do
      expect(WorldGeneration::ClimateSimulator).to receive(:new).and_call_original
      service.run
    end

    it 'uses RiverGenerator' do
      expect(WorldGeneration::RiverGenerator).to receive(:new).and_call_original
      service.run
    end

    it 'uses BiomeMapper' do
      expect(WorldGeneration::BiomeMapper).to receive(:new).and_call_original
      service.run
    end

    it 'passes sea_level from elevation to climate' do
      # Capture the sea_level passed to ClimateSimulator
      sea_level_used = nil
      allow(WorldGeneration::ClimateSimulator).to receive(:new) do |grid, config, sea_level|
        sea_level_used = sea_level
        WorldGeneration::ClimateSimulator.allocate.tap do |obj|
          obj.instance_variable_set(:@grid, grid)
          obj.instance_variable_set(:@config, config)
          obj.instance_variable_set(:@sea_level, sea_level)
          obj.instance_variable_set(:@ocean_distance_cache, {})
        end
      end

      service.run

      # Sea level should be set (exact value depends on generation)
      expect(sea_level_used).to be_a(Numeric)
    end
  end
end
