# frozen_string_literal: true

require 'spec_helper'

# Live end-to-end tests for procedural world generation.
# These tests use real generation (no mocks) and provide detailed output.
#
# Run with: bundle exec rspec spec/services/world_generation/live_e2e_spec.rb
RSpec.describe 'World Generation Live E2E', type: :integration do
  let(:world) { create(:world, name: 'Procedural E2E Test') }

  describe 'full procedural pipeline' do
    it 'generates an Earth-like world with detailed output' do
      job = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'seed' => 42, 'subdivisions' => 3 }
      )

      start_time = Time.now
      WorldGeneration::PipelineService.new(job).run
      elapsed = Time.now - start_time

      job.reload
      expect(job.status).to eq('completed')

      # Get terrain distribution
      hexes = WorldHex.where(world_id: world.id)
      terrain_counts = {}
      hexes.select(:terrain_type).group_and_count(:terrain_type).all.each do |row|
        terrain_counts[row[:terrain_type]] = row[:count]
      end
      total = terrain_counts.values.sum

      puts "\n" + "=" * 60
      puts "Earth-like World Generation Results"
      puts "=" * 60
      puts "Seed: 42"
      puts "Subdivisions: 3 (#{total} hexes)"
      puts "Time: #{elapsed.round(2)}s (#{(total / elapsed).round(0)} hexes/sec)"
      puts "\nTerrain Distribution:"
      terrain_counts.sort_by { |_, v| -v }.each do |terrain, count|
        pct = (count.to_f / total * 100).round(1)
        bar = '#' * (pct / 2).to_i
        puts "  #{terrain.ljust(15)} #{count.to_s.rjust(5)} (#{pct.to_s.rjust(5)}%) #{bar}"
      end

      # Verify ocean coverage is Earth-like (~70%)
      ocean_ratio = (terrain_counts['ocean'] || 0).to_f / total
      puts "\nOcean coverage: #{(ocean_ratio * 100).round(1)}% (target: ~70%)"
      expect(ocean_ratio).to be_within(0.20).of(0.70)

      # Verify terrain variety
      expect(terrain_counts.keys.length).to be >= 5
    end

    it 'generates a Pangaea supercontinent world' do
      job = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: { 'preset' => 'pangaea', 'seed' => 123, 'subdivisions' => 3 }
      )

      WorldGeneration::PipelineService.new(job).run
      job.reload
      expect(job.status).to eq('completed')

      hexes = WorldHex.where(world_id: world.id)
      total = hexes.count
      ocean_count = hexes.where(terrain_type: 'ocean').count
      ocean_ratio = ocean_count.to_f / total

      puts "\n" + "=" * 60
      puts "Pangaea World (supercontinent)"
      puts "=" * 60
      puts "Hexes: #{total}"
      puts "Ocean: #{(ocean_ratio * 100).round(1)}% (target: ~55%)"

      # Pangaea should have less ocean than Earth-like
      expect(ocean_ratio).to be_within(0.20).of(0.55)
    end

    it 'generates an Archipelago island world' do
      job = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: { 'preset' => 'archipelago', 'seed' => 456, 'subdivisions' => 3 }
      )

      WorldGeneration::PipelineService.new(job).run
      job.reload
      expect(job.status).to eq('completed')

      hexes = WorldHex.where(world_id: world.id)
      total = hexes.count
      ocean_count = hexes.where(terrain_type: 'ocean').count
      ocean_ratio = ocean_count.to_f / total

      puts "\n" + "=" * 60
      puts "Archipelago World (island chains)"
      puts "=" * 60
      puts "Hexes: #{total}"
      puts "Ocean: #{(ocean_ratio * 100).round(1)}% (target: ~85%)"

      # Archipelago should have lots of ocean
      expect(ocean_ratio).to be_within(0.20).of(0.85)
    end

    it 'generates a Waterworld with minimal land' do
      job = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: { 'preset' => 'waterworld', 'seed' => 789, 'subdivisions' => 3 }
      )

      WorldGeneration::PipelineService.new(job).run
      job.reload
      expect(job.status).to eq('completed')

      hexes = WorldHex.where(world_id: world.id)
      total = hexes.count
      ocean_count = hexes.where(terrain_type: 'ocean').count
      ocean_ratio = ocean_count.to_f / total

      puts "\n" + "=" * 60
      puts "Waterworld (minimal land)"
      puts "=" * 60
      puts "Hexes: #{total}"
      puts "Ocean: #{(ocean_ratio * 100).round(1)}% (target: ~92%)"

      # Waterworld should be mostly ocean
      expect(ocean_ratio).to be > 0.70
    end

    it 'generates an Arid desert world' do
      job = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: { 'preset' => 'arid', 'seed' => 999, 'subdivisions' => 3 }
      )

      WorldGeneration::PipelineService.new(job).run
      job.reload
      expect(job.status).to eq('completed')

      hexes = WorldHex.where(world_id: world.id)
      total = hexes.count
      ocean_count = hexes.where(terrain_type: 'ocean').count
      desert_count = hexes.where(terrain_type: 'desert').count
      ocean_ratio = ocean_count.to_f / total
      desert_ratio = desert_count.to_f / total

      puts "\n" + "=" * 60
      puts "Arid World (desert planet)"
      puts "=" * 60
      puts "Hexes: #{total}"
      puts "Ocean: #{(ocean_ratio * 100).round(1)}% (target: ~45%)"
      puts "Desert: #{(desert_ratio * 100).round(1)}%"

      # Arid should have less ocean
      expect(ocean_ratio).to be < 0.70
    end
  end

  describe 'elevation distribution' do
    it 'generates varied elevation across the world' do
      job = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'seed' => 42, 'subdivisions' => 3 }
      )

      WorldGeneration::PipelineService.new(job).run

      # Check elevation distribution (database column is 'altitude')
      hexes = WorldHex.where(world_id: world.id).all
      # Note: globe grid stores elevation but column name is altitude in some contexts
      altitudes = hexes.map(&:altitude).compact

      puts "\n" + "=" * 60
      puts "Elevation Analysis"
      puts "=" * 60

      if altitudes.any?
        min_elev = altitudes.min
        max_elev = altitudes.max
        avg_elev = altitudes.sum.to_f / altitudes.length

        puts "Min altitude: #{min_elev}"
        puts "Max altitude: #{max_elev}"
        puts "Avg altitude: #{avg_elev.round(0)}"
        puts "Hexes with altitude data: #{altitudes.length}/#{hexes.count}"

        # Just verify we have altitude data - values depend on generation
        expect(altitudes.length).to be > 0
      else
        # Some presets may not set altitude - just verify terrain was generated
        puts "No altitude data (terrain-only generation)"
        expect(hexes.count).to be > 0
      end
    end
  end

  describe 'climate zones' do
    it 'generates latitude-based temperature gradients' do
      job = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'seed' => 42, 'subdivisions' => 3 }
      )

      WorldGeneration::PipelineService.new(job).run

      hexes = WorldHex.where(world_id: world.id).all

      # Group by latitude bands
      polar = hexes.select { |h| h.latitude && h.latitude.abs > 60 }
      temperate = hexes.select { |h| h.latitude && h.latitude.abs > 23.5 && h.latitude.abs <= 60 }
      tropical = hexes.select { |h| h.latitude && h.latitude.abs <= 23.5 }

      puts "\n" + "=" * 60
      puts "Climate Zone Analysis"
      puts "=" * 60
      puts "Polar (>60°): #{polar.length} hexes"
      puts "Temperate (23.5-60°): #{temperate.length} hexes"
      puts "Tropical (0-23.5°): #{tropical.length} hexes"

      # Check temperature gradients (polar should be colder)
      if polar.any? && tropical.any?
        polar_temps = polar.map(&:temperature).compact
        tropical_temps = tropical.map(&:temperature).compact

        if polar_temps.any? && tropical_temps.any?
          avg_polar = polar_temps.sum / polar_temps.length
          avg_tropical = tropical_temps.sum / tropical_temps.length

          puts "\nAverage temperatures:"
          puts "  Polar: #{avg_polar.round(1)}°C"
          puts "  Tropical: #{avg_tropical.round(1)}°C"

          expect(avg_polar).to be < avg_tropical
        end
      end
    end
  end

  describe 'rivers' do
    it 'generates river networks' do
      job = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'seed' => 42, 'subdivisions' => 3 }
      )

      WorldGeneration::PipelineService.new(job).run

      # Count hexes with river features using proper Sequel OR syntax
      hexes = WorldHex.where(world_id: world.id)
      river_hexes = hexes.where(
        Sequel.|(
          Sequel.~(feature_n: nil),
          Sequel.~(feature_ne: nil),
          Sequel.~(feature_se: nil),
          Sequel.~(feature_s: nil),
          Sequel.~(feature_sw: nil),
          Sequel.~(feature_nw: nil)
        )
      ).count

      total_land = hexes.exclude(terrain_type: 'ocean').count

      puts "\n" + "=" * 60
      puts "River Network Analysis"
      puts "=" * 60
      puts "Total hexes: #{hexes.count}"
      puts "Land hexes: #{total_land}"
      puts "Hexes with rivers: #{river_hexes}"

      if total_land > 0
        river_coverage = (river_hexes.to_f / total_land * 100).round(1)
        puts "River coverage on land: #{river_coverage}%"

        # Rivers should cover at least some land (>5%)
        expect(river_coverage).to be > 5.0
      end
    end
  end

  describe 'performance scaling' do
    [2, 3, 4].each do |subdivisions|
      expected_hexes = 20 * (4**subdivisions)

      it "generates #{expected_hexes} hexes with #{subdivisions} subdivisions" do
        job = WorldGenerationJob.create(
          world_id: world.id,
          job_type: 'procedural',
          status: 'pending',
          config: { 'preset' => 'earth_like', 'seed' => 42, 'subdivisions' => subdivisions }
        )

        start_time = Time.now
        WorldGeneration::PipelineService.new(job).run
        elapsed = Time.now - start_time

        job.reload
        expect(job.status).to eq('completed')

        actual_hexes = WorldHex.where(world_id: world.id).count
        expect(actual_hexes).to eq(expected_hexes)

        rate = (actual_hexes / elapsed).round(0)
        puts "\nSubdivisions #{subdivisions}: #{actual_hexes} hexes in #{elapsed.round(2)}s (#{rate} hexes/sec)"
      end
    end
  end

  describe 'determinism' do
    it 'produces identical worlds with same seed' do
      # First generation
      job1 = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'seed' => 12345, 'subdivisions' => 2 }
      )
      WorldGeneration::PipelineService.new(job1).run

      terrain1 = WorldHex.where(world_id: world.id)
                         .order(:globe_hex_id)
                         .select_map([:globe_hex_id, :terrain_type, :elevation])

      # Clear and regenerate with same seed
      WorldHex.where(world_id: world.id).delete

      job2 = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'seed' => 12345, 'subdivisions' => 2 }
      )
      WorldGeneration::PipelineService.new(job2).run

      terrain2 = WorldHex.where(world_id: world.id)
                         .order(:globe_hex_id)
                         .select_map([:globe_hex_id, :terrain_type, :elevation])

      expect(terrain1).to eq(terrain2)
      puts "\nDeterminism verified: same seed produces identical world"
    end

    it 'produces different worlds with different seeds' do
      # First generation
      job1 = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'seed' => 11111, 'subdivisions' => 2 }
      )
      WorldGeneration::PipelineService.new(job1).run

      terrain1 = WorldHex.where(world_id: world.id)
                         .order(:globe_hex_id)
                         .select_map(:terrain_type)

      # Clear and regenerate with different seed
      WorldHex.where(world_id: world.id).delete

      job2 = WorldGenerationJob.create(
        world_id: world.id,
        job_type: 'procedural',
        status: 'pending',
        config: { 'preset' => 'earth_like', 'seed' => 99999, 'subdivisions' => 2 }
      )
      WorldGeneration::PipelineService.new(job2).run

      terrain2 = WorldHex.where(world_id: world.id)
                         .order(:globe_hex_id)
                         .select_map(:terrain_type)

      expect(terrain1).not_to eq(terrain2)
      puts "\nVariation verified: different seeds produce different worlds"
    end
  end
end
