# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/world_generation/globe_hex_grid'
require_relative '../../../app/services/world_generation/preset_config'
require_relative '../../../app/services/world_generation/noise_generator'
require_relative '../../../app/services/world_generation/tectonics_generator'
require_relative '../../../app/services/world_generation/elevation_generator'

RSpec.describe WorldGeneration::ElevationGenerator do
  let(:world) { create(:world) }
  # Use subdivisions: 2 for 320 hexes (fast enough for tests, enough for meaningful results)
  let(:grid) { WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2) }
  let(:config) { WorldGeneration::PresetConfig.for(:earth_like) }
  let(:seed) { 12345 }
  let(:rng) { Random.new(seed) }
  let(:noise) { WorldGeneration::NoiseGenerator.new(seed: rng.rand(2**32)) }
  let(:tectonics) do
    t = WorldGeneration::TectonicsGenerator.new(grid, config, Random.new(seed))
    t.generate
    t
  end
  let(:generator) { described_class.new(grid, config, rng, noise, tectonics) }

  describe '#initialize' do
    it 'starts with sea_level at 0.0' do
      expect(generator.sea_level).to eq(0.0)
    end
  end

  describe '#generate' do
    before { generator.generate }

    it 'assigns elevation to every hex' do
      grid.each_hex do |hex|
        expect(hex.elevation).not_to be_nil,
          "Hex #{hex.id} at (#{hex.lat}, #{hex.lon}) has no elevation"
      end
    end

    it 'produces varied elevations (not all the same value)' do
      elevations = []
      grid.each_hex { |hex| elevations << hex.elevation }

      unique_elevations = elevations.uniq
      expect(unique_elevations.size).to be > 10,
        "Expected varied elevations, got only #{unique_elevations.size} unique values"
    end

    it 'produces elevations in reasonable range (roughly -1 to +2)' do
      min_elev = Float::INFINITY
      max_elev = -Float::INFINITY

      grid.each_hex do |hex|
        min_elev = hex.elevation if hex.elevation < min_elev
        max_elev = hex.elevation if hex.elevation > max_elev
      end

      expect(min_elev).to be >= -2.0
      expect(max_elev).to be <= 3.0
      expect(max_elev - min_elev).to be > 0.5,
        "Elevation range too narrow: #{min_elev} to #{max_elev}"
    end

    it 'sets sea_level to a non-zero value' do
      # After generation, sea_level should be calculated
      expect(generator.sea_level).not_to eq(0.0)
    end
  end

  describe 'tectonic influence' do
    before { generator.generate }

    it 'continental plates have higher average elevation than oceanic plates' do
      continental_elevations = []
      oceanic_elevations = []

      grid.each_hex do |hex|
        plate_id = hex.plate_id
        next if plate_id.nil?

        plate = tectonics.plates[plate_id]
        next if plate.nil?

        if plate[:continental]
          continental_elevations << hex.elevation
        else
          oceanic_elevations << hex.elevation
        end
      end

      # Skip if we don't have both types
      next if continental_elevations.empty? || oceanic_elevations.empty?

      continental_avg = continental_elevations.sum / continental_elevations.size
      oceanic_avg = oceanic_elevations.sum / oceanic_elevations.size

      expect(continental_avg).to be > oceanic_avg,
        "Continental avg (#{continental_avg}) should be higher than oceanic avg (#{oceanic_avg})"
    end
  end

  describe 'boundary effects' do
    before { generator.generate }

    it 'convergent boundaries have higher elevation than average' do
      # Get convergent boundary hexes
      convergent_hex_ids = Set.new
      tectonics.plate_boundaries.each do |_key, boundary|
        if boundary[:type] == :convergent
          boundary[:hexes].each { |hex| convergent_hex_ids.add(hex.id) }
        end
      end

      # Skip if no convergent boundaries (unlikely but possible)
      next if convergent_hex_ids.empty?

      # Calculate average elevations
      all_elevations = []
      convergent_elevations = []

      grid.each_hex do |hex|
        all_elevations << hex.elevation
        convergent_elevations << hex.elevation if convergent_hex_ids.include?(hex.id)
      end

      overall_avg = all_elevations.sum / all_elevations.size
      convergent_avg = convergent_elevations.sum / convergent_elevations.size

      expect(convergent_avg).to be > overall_avg,
        "Convergent boundary avg (#{convergent_avg}) should be higher than overall avg (#{overall_avg})"
    end
  end

  describe 'sea level calculation' do
    it 'sets sea_level to match ocean coverage target within 10%' do
      generator.generate

      ocean_coverage_target = config[:ocean_coverage]
      below_sea_level = 0
      total = 0

      grid.each_hex do |hex|
        total += 1
        below_sea_level += 1 if hex.elevation < generator.sea_level
      end

      actual_coverage = below_sea_level.to_f / total
      tolerance = 0.10

      expect(actual_coverage).to be_within(tolerance).of(ocean_coverage_target),
        "Ocean coverage #{actual_coverage} should be within #{tolerance} of #{ocean_coverage_target}"
    end

    it 'works with different ocean coverage presets' do
      # Test with waterworld preset (92% ocean)
      waterworld_config = WorldGeneration::PresetConfig.for(:waterworld)
      waterworld_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2)
      waterworld_rng = Random.new(54321)
      waterworld_noise = WorldGeneration::NoiseGenerator.new(seed: waterworld_rng.rand(2**32))
      waterworld_tectonics = WorldGeneration::TectonicsGenerator.new(
        waterworld_grid, waterworld_config, Random.new(54321)
      )
      waterworld_tectonics.generate

      waterworld_gen = described_class.new(
        waterworld_grid, waterworld_config, waterworld_rng, waterworld_noise, waterworld_tectonics
      )
      waterworld_gen.generate

      below_sea = 0
      total = 0
      waterworld_grid.each_hex do |hex|
        total += 1
        below_sea += 1 if hex.elevation < waterworld_gen.sea_level
      end

      actual_coverage = below_sea.to_f / total
      expected_coverage = waterworld_config[:ocean_coverage]

      expect(actual_coverage).to be_within(0.10).of(expected_coverage)
    end

    it 'works with arid preset (45% ocean)' do
      arid_config = WorldGeneration::PresetConfig.for(:arid)
      arid_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2)
      arid_rng = Random.new(99999)
      arid_noise = WorldGeneration::NoiseGenerator.new(seed: arid_rng.rand(2**32))
      arid_tectonics = WorldGeneration::TectonicsGenerator.new(
        arid_grid, arid_config, Random.new(99999)
      )
      arid_tectonics.generate

      arid_gen = described_class.new(
        arid_grid, arid_config, arid_rng, arid_noise, arid_tectonics
      )
      arid_gen.generate

      below_sea = 0
      total = 0
      arid_grid.each_hex do |hex|
        total += 1
        below_sea += 1 if hex.elevation < arid_gen.sea_level
      end

      actual_coverage = below_sea.to_f / total
      expected_coverage = arid_config[:ocean_coverage]

      expect(actual_coverage).to be_within(0.10).of(expected_coverage)
    end
  end

  describe 'reproducibility' do
    it 'generates identical elevations with same seed' do
      # First generation
      grid1 = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2)
      rng1 = Random.new(77777)
      noise1 = WorldGeneration::NoiseGenerator.new(seed: 77777)
      tect1 = WorldGeneration::TectonicsGenerator.new(grid1, config, Random.new(77777))
      tect1.generate
      gen1 = described_class.new(grid1, config, rng1, noise1, tect1)
      gen1.generate

      # Second generation with same seeds
      grid2 = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2)
      rng2 = Random.new(77777)
      noise2 = WorldGeneration::NoiseGenerator.new(seed: 77777)
      tect2 = WorldGeneration::TectonicsGenerator.new(grid2, config, Random.new(77777))
      tect2.generate
      gen2 = described_class.new(grid2, config, rng2, noise2, tect2)
      gen2.generate

      # Compare sea levels
      expect(gen1.sea_level).to eq(gen2.sea_level)

      # Compare elevations
      grid1.hexes.each_with_index do |hex1, idx|
        hex2 = grid2.hexes[idx]
        expect(hex1.elevation).to eq(hex2.elevation),
          "Hex #{idx} elevation mismatch: #{hex1.elevation} vs #{hex2.elevation}"
      end
    end
  end

  describe 'mountain intensity' do
    it 'higher mountain_intensity produces higher convergent boundary elevations' do
      # Low intensity
      low_config = config.merge(mountain_intensity: 0.5)
      low_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2)
      low_tect = WorldGeneration::TectonicsGenerator.new(low_grid, low_config, Random.new(11111))
      low_tect.generate
      low_noise = WorldGeneration::NoiseGenerator.new(seed: 11111)
      low_gen = described_class.new(low_grid, low_config, Random.new(11111), low_noise, low_tect)
      low_gen.generate

      # High intensity
      high_config = config.merge(mountain_intensity: 2.0)
      high_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2)
      high_tect = WorldGeneration::TectonicsGenerator.new(high_grid, high_config, Random.new(11111))
      high_tect.generate
      high_noise = WorldGeneration::NoiseGenerator.new(seed: 11111)
      high_gen = described_class.new(high_grid, high_config, Random.new(11111), high_noise, high_tect)
      high_gen.generate

      # Find max elevation at convergent boundaries for each
      low_max = -Float::INFINITY
      high_max = -Float::INFINITY

      low_tect.plate_boundaries.each do |_, boundary|
        next unless boundary[:type] == :convergent
        boundary[:hexes].each do |hex|
          low_max = hex.elevation if hex.elevation > low_max
        end
      end

      high_tect.plate_boundaries.each do |_, boundary|
        next unless boundary[:type] == :convergent
        boundary[:hexes].each do |hex|
          high_max = hex.elevation if hex.elevation > high_max
        end
      end

      # Skip if no convergent boundaries
      next if low_max == -Float::INFINITY || high_max == -Float::INFINITY

      expect(high_max).to be > low_max,
        "High intensity max (#{high_max}) should exceed low intensity max (#{low_max})"
    end
  end

  describe 'erosion smoothing' do
    # This is tested implicitly - erosion should produce values that are
    # less extreme than pure noise + tectonic influence would suggest.
    # Hard to test directly without access to pre-erosion values.

    it 'produces smooth gradients between hexes' do
      generator.generate

      # Check that elevation differences between neighbors are reasonable
      max_diff = 0.0
      grid.each_hex do |hex|
        grid.neighbors_of(hex).each do |neighbor|
          diff = (hex.elevation - neighbor.elevation).abs
          max_diff = diff if diff > max_diff
        end
      end

      # After erosion, max difference should be moderate
      # (without erosion, differences could be very large at boundaries)
      expect(max_diff).to be < 2.0,
        "Maximum neighbor elevation difference #{max_diff} is too large"
    end
  end

  describe 'performance' do
    it 'generates elevation in reasonable time for medium grid' do
      medium_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 3)
      medium_rng = Random.new(88888)
      medium_noise = WorldGeneration::NoiseGenerator.new(seed: 88888)
      medium_tect = WorldGeneration::TectonicsGenerator.new(medium_grid, config, Random.new(88888))
      medium_tect.generate

      medium_gen = described_class.new(medium_grid, config, medium_rng, medium_noise, medium_tect)

      start_time = Time.now
      medium_gen.generate
      elapsed = Time.now - start_time

      # Should complete in under 5 seconds
      expect(elapsed).to be < 5.0
    end
  end

  describe 'edge cases' do
    it 'handles single plate (no boundaries)' do
      single_config = {
        plate_count: 1..1,
        continental_ratio: 1.0,
        ocean_coverage: 0.5,
        mountain_intensity: 1.0
      }
      single_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 1)
      single_tect = WorldGeneration::TectonicsGenerator.new(single_grid, single_config, Random.new(1))
      single_tect.generate
      single_noise = WorldGeneration::NoiseGenerator.new(seed: 1)
      single_gen = described_class.new(single_grid, single_config, Random.new(1), single_noise, single_tect)

      expect { single_gen.generate }.not_to raise_error

      # All hexes should have elevation
      single_grid.each_hex do |hex|
        expect(hex.elevation).not_to be_nil
      end
    end

    it 'handles 0% ocean coverage' do
      no_ocean_config = config.merge(ocean_coverage: 0.0)
      no_ocean_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 1)
      no_ocean_tect = WorldGeneration::TectonicsGenerator.new(no_ocean_grid, no_ocean_config, Random.new(2))
      no_ocean_tect.generate
      no_ocean_noise = WorldGeneration::NoiseGenerator.new(seed: 2)
      no_ocean_gen = described_class.new(no_ocean_grid, no_ocean_config, Random.new(2), no_ocean_noise, no_ocean_tect)
      no_ocean_gen.generate

      # Sea level should be at or below minimum elevation
      min_elev = Float::INFINITY
      no_ocean_grid.each_hex { |hex| min_elev = hex.elevation if hex.elevation < min_elev }

      expect(no_ocean_gen.sea_level).to be <= min_elev
    end

    it 'handles 100% ocean coverage' do
      all_ocean_config = config.merge(ocean_coverage: 1.0)
      all_ocean_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 1)
      all_ocean_tect = WorldGeneration::TectonicsGenerator.new(all_ocean_grid, all_ocean_config, Random.new(3))
      all_ocean_tect.generate
      all_ocean_noise = WorldGeneration::NoiseGenerator.new(seed: 3)
      all_ocean_gen = described_class.new(all_ocean_grid, all_ocean_config, Random.new(3), all_ocean_noise, all_ocean_tect)
      all_ocean_gen.generate

      # Sea level should be at or above maximum elevation
      max_elev = -Float::INFINITY
      all_ocean_grid.each_hex { |hex| max_elev = hex.elevation if hex.elevation > max_elev }

      expect(all_ocean_gen.sea_level).to be >= max_elev
    end
  end
end
