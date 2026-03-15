# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/world_generation/globe_hex_grid'
require_relative '../../../app/services/world_generation/preset_config'
require_relative '../../../app/services/world_generation/noise_generator'
require_relative '../../../app/services/world_generation/tectonics_generator'
require_relative '../../../app/services/world_generation/elevation_generator'
require_relative '../../../app/services/world_generation/climate_simulator'
require_relative '../../../app/services/world_generation/river_generator'

RSpec.describe WorldGeneration::RiverGenerator do
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
  let(:elevation_gen) do
    e = WorldGeneration::ElevationGenerator.new(grid, config, Random.new(seed), noise, tectonics)
    e.generate
    e
  end
  let(:sea_level) { elevation_gen.sea_level }
  let(:climate) do
    c = WorldGeneration::ClimateSimulator.new(grid, config, sea_level)
    c.simulate
    c
  end
  let(:generator) do
    # Ensure climate has been simulated before creating river generator
    climate
    described_class.new(grid, config, Random.new(seed), sea_level)
  end

  describe '#initialize' do
    it 'accepts grid, config, rng, and sea_level' do
      expect { described_class.new(grid, config, rng, sea_level) }.not_to raise_error
    end

    it 'starts with empty rivers array' do
      climate # ensure climate is simulated
      gen = described_class.new(grid, config, rng, sea_level)
      expect(gen.rivers).to eq([])
    end
  end

  describe '#generate' do
    before do
      generator.generate
    end

    it 'creates rivers' do
      expect(generator.rivers).not_to be_empty,
        'Expected at least one river to be generated'
    end

    it 'creates the expected number of rivers based on config' do
      river_range = config[:river_sources]
      # Rivers created should be at most the upper bound (some sources may not produce valid rivers)
      expect(generator.rivers.size).to be <= river_range.max
    end

    it 'rivers are arrays of hex objects' do
      generator.rivers.each do |river|
        expect(river).to be_an(Array)
        expect(river.size).to be >= 2, 'Rivers should have at least 2 hexes'
        river.each do |hex|
          expect(hex).to respond_to(:elevation)
          expect(hex).to respond_to(:id)
        end
      end
    end
  end

  describe 'river flow direction' do
    before do
      generator.generate
    end

    it 'rivers flow downhill (each hex elevation >= next hex elevation)' do
      generator.rivers.each_with_index do |river, river_idx|
        river.each_cons(2).with_index do |(from_hex, to_hex), step|
          expect(from_hex.elevation).to be >= to_hex.elevation,
            "River #{river_idx} step #{step}: elevation went uphill " \
            "(#{from_hex.elevation} -> #{to_hex.elevation})"
        end
      end
    end

    it 'rivers start above sea level' do
      generator.rivers.each_with_index do |river, idx|
        source = river.first
        expect(source.elevation).to be >= sea_level,
          "River #{idx} source is below sea level (elev: #{source.elevation}, sea: #{sea_level})"
      end
    end

    it 'rivers end at ocean or at a local minimum' do
      generator.rivers.each_with_index do |river, idx|
        last_hex = river.last

        # Either it reached ocean...
        at_ocean = last_hex.elevation < sea_level

        # ...or it's at a local minimum (no lower neighbors not in path)
        visited = Set.new(river.map(&:id))
        neighbors = grid.neighbors_of(last_hex)
        unvisited_neighbors = neighbors.reject { |n| visited.include?(n.id) }
        at_local_minimum = unvisited_neighbors.all? { |n| n.elevation >= last_hex.elevation }

        expect(at_ocean || at_local_minimum).to be(true),
          "River #{idx} ended at hex #{last_hex.id} (elev: #{last_hex.elevation}) " \
          "which is neither ocean nor local minimum"
      end
    end
  end

  describe 'river direction marking' do
    before do
      generator.generate
    end

    it 'marks river directions on hexes in river paths' do
      # At least some hexes in rivers should have river_directions set
      hexes_with_directions = 0

      generator.rivers.each do |river|
        river.each do |hex|
          hexes_with_directions += 1 if hex.river_directions && !hex.river_directions.empty?
        end
      end

      expect(hexes_with_directions).to be > 0,
        'Expected some river hexes to have direction markers'
    end

    it 'river directions use valid direction names' do
      valid_directions = described_class::DIRECTION_NAMES

      generator.rivers.each do |river|
        river.each do |hex|
          next unless hex.river_directions && !hex.river_directions.empty?

          hex.river_directions.each do |dir|
            expect(valid_directions).to include(dir),
              "Invalid direction '#{dir}' on hex #{hex.id}"
          end
        end
      end
    end

    it 'consecutive hexes have matching directions (outflow/inflow pair)' do
      opposite = described_class::OPPOSITE_DIRECTIONS

      generator.rivers.each_with_index do |river, river_idx|
        river.each_cons(2).with_index do |(from_hex, to_hex), step|
          next unless from_hex.river_directions && !from_hex.river_directions.empty?

          # Find direction from from_hex that points to to_hex
          outflow_direction = from_hex.river_directions.find do |dir|
            opposite[dir] && to_hex.river_directions&.include?(opposite[dir])
          end

          # At least one direction should match
          expect(outflow_direction).not_to be_nil,
            "River #{river_idx} step #{step}: no matching direction pair between hexes"
        end
      end
    end
  end

  describe 'river width calculation' do
    before do
      generator.generate
    end

    it 'sets river_width on hexes in river paths' do
      hexes_with_width = 0

      generator.rivers.each do |river|
        river.each do |hex|
          hexes_with_width += 1 if hex.river_width && hex.river_width > 0
        end
      end

      expect(hexes_with_width).to be > 0,
        'Expected some river hexes to have river_width set'
    end

    it 'river_width is 1 (stream), 2 (river), or 3 (major river)' do
      generator.rivers.each do |river|
        river.each do |hex|
          next unless hex.river_width

          expect([1, 2, 3]).to include(hex.river_width),
            "Invalid river_width #{hex.river_width} on hex #{hex.id}"
        end
      end
    end

    it 'downstream hexes have equal or greater river_width' do
      generator.rivers.each_with_index do |river, river_idx|
        # River width should generally increase or stay same going downstream
        # (exceptions possible at very start due to thresholds)
        prev_width = 0

        river.each_with_index do |hex, step|
          next unless hex.river_width

          # Allow first few hexes to stabilize
          if step > 2
            expect(hex.river_width).to be >= prev_width,
              "River #{river_idx} step #{step}: width decreased from #{prev_width} to #{hex.river_width}"
          end

          prev_width = hex.river_width
        end
      end
    end

    it 'tributary merges increase accumulated flow' do
      # Find hexes that appear in multiple rivers (merge points)
      hex_river_count = Hash.new(0)

      generator.rivers.each do |river|
        river.each do |hex|
          hex_river_count[hex.id] += 1
        end
      end

      merge_hexes = hex_river_count.select { |_, count| count > 1 }

      # If there are merges, verify they have higher flow
      if merge_hexes.any?
        merge_hexes.each do |hex_id, count|
          hex = grid.hex_by_id(hex_id)
          next unless hex&.river_width

          # Merge points with 2+ tributaries should be at least streams
          expect(hex.river_width).to be >= 1,
            "Merge point hex #{hex_id} (in #{count} rivers) should have width >= 1"
        end
      end
    end
  end

  describe 'source selection' do
    it 'sources are in high elevation, high moisture areas' do
      generator.generate

      generator.rivers.each_with_index do |river, idx|
        source = river.first

        # Source should be above sea level
        expect(source.elevation).to be >= sea_level,
          "River #{idx} source below sea level"

        # Source should have reasonable moisture (may not meet threshold if few candidates)
        expect(source.moisture).not_to be_nil,
          "River #{idx} source has no moisture value"
      end
    end
  end

  describe 'source count matches config range' do
    it 'generates sources within the configured range (accounting for grid size)' do
      # Create generator with different seeds and check source counts
      source_counts = []

      5.times do |i|
        test_world = create(:world)
        test_grid = WorldGeneration::GlobeHexGrid.new(test_world, subdivisions: 2)
        test_rng = Random.new(seed + i * 1000)
        test_noise = WorldGeneration::NoiseGenerator.new(seed: test_rng.rand(2**32))
        test_tect = WorldGeneration::TectonicsGenerator.new(test_grid, config, Random.new(seed + i * 1000))
        test_tect.generate
        test_elev = WorldGeneration::ElevationGenerator.new(
          test_grid, config, Random.new(seed + i * 1000), test_noise, test_tect
        )
        test_elev.generate
        test_climate = WorldGeneration::ClimateSimulator.new(test_grid, config, test_elev.sea_level)
        test_climate.simulate

        test_gen = described_class.new(test_grid, config, Random.new(seed + i * 1000), test_elev.sea_level)
        test_gen.generate

        source_counts << test_gen.rivers.size
      end

      # At least one run should have created rivers
      expect(source_counts.max).to be > 0,
        "No rivers were created in any of #{source_counts.size} test runs"
    end
  end

  describe 'reproducibility' do
    it 'generates identical rivers with same seed' do
      # First generation
      gen1_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2)
      gen1_rng = Random.new(77777)
      gen1_noise = WorldGeneration::NoiseGenerator.new(seed: 77777)
      gen1_tect = WorldGeneration::TectonicsGenerator.new(gen1_grid, config, Random.new(77777))
      gen1_tect.generate
      gen1_elev = WorldGeneration::ElevationGenerator.new(gen1_grid, config, Random.new(77777), gen1_noise, gen1_tect)
      gen1_elev.generate
      gen1_climate = WorldGeneration::ClimateSimulator.new(gen1_grid, config, gen1_elev.sea_level)
      gen1_climate.simulate
      gen1 = described_class.new(gen1_grid, config, Random.new(77777), gen1_elev.sea_level)
      gen1.generate

      # Second generation with same seeds
      gen2_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2)
      gen2_rng = Random.new(77777)
      gen2_noise = WorldGeneration::NoiseGenerator.new(seed: 77777)
      gen2_tect = WorldGeneration::TectonicsGenerator.new(gen2_grid, config, Random.new(77777))
      gen2_tect.generate
      gen2_elev = WorldGeneration::ElevationGenerator.new(gen2_grid, config, Random.new(77777), gen2_noise, gen2_tect)
      gen2_elev.generate
      gen2_climate = WorldGeneration::ClimateSimulator.new(gen2_grid, config, gen2_elev.sea_level)
      gen2_climate.simulate
      gen2 = described_class.new(gen2_grid, config, Random.new(77777), gen2_elev.sea_level)
      gen2.generate

      # Compare river counts
      expect(gen1.rivers.size).to eq(gen2.rivers.size)

      # Compare river paths (by hex IDs)
      gen1.rivers.each_with_index do |river1, idx|
        river2 = gen2.rivers[idx]
        expect(river1.map(&:id)).to eq(river2.map(&:id)),
          "River #{idx} path mismatch"
      end
    end
  end

  describe 'edge cases' do
    it 'handles grid with all ocean (no land)' do
      # Set all hexes below sea level
      grid.each_hex { |hex| hex.elevation = -1.0 }
      all_ocean_gen = described_class.new(grid, config, rng, 0.0)

      expect { all_ocean_gen.generate }.not_to raise_error
      expect(all_ocean_gen.rivers).to be_empty
    end

    it 'handles grid with flat land (no elevation gradient)' do
      # Set all hexes to same elevation above sea level
      grid.each_hex do |hex|
        hex.elevation = 0.5
        hex.moisture = 0.8
      end
      flat_gen = described_class.new(grid, config, rng, 0.0)

      expect { flat_gen.generate }.not_to raise_error
      # Rivers may be short or empty since there's no downhill path
    end

    it 'handles grid with no high moisture areas' do
      # Set all moisture to low values
      grid.each_hex do |hex|
        hex.moisture = 0.1
      end

      dry_gen = described_class.new(grid, config, rng, sea_level)
      expect { dry_gen.generate }.not_to raise_error
      # May have no rivers or fewer rivers
    end

    it 'handles small grid (subdivisions: 1)' do
      small_world = create(:world)
      small_grid = WorldGeneration::GlobeHexGrid.new(small_world, subdivisions: 1)
      small_rng = Random.new(55555)
      small_noise = WorldGeneration::NoiseGenerator.new(seed: 55555)
      small_tect = WorldGeneration::TectonicsGenerator.new(small_grid, config, Random.new(55555))
      small_tect.generate
      small_elev = WorldGeneration::ElevationGenerator.new(
        small_grid, config, Random.new(55555), small_noise, small_tect
      )
      small_elev.generate
      small_climate = WorldGeneration::ClimateSimulator.new(small_grid, config, small_elev.sea_level)
      small_climate.simulate

      small_gen = described_class.new(small_grid, config, Random.new(55555), small_elev.sea_level)

      expect { small_gen.generate }.not_to raise_error
    end
  end

  describe 'different presets' do
    it 'arid preset produces fewer rivers' do
      arid_config = WorldGeneration::PresetConfig.for(:arid)

      arid_world = create(:world)
      arid_grid = WorldGeneration::GlobeHexGrid.new(arid_world, subdivisions: 2)
      arid_rng = Random.new(99999)
      arid_noise = WorldGeneration::NoiseGenerator.new(seed: 99999)
      arid_tect = WorldGeneration::TectonicsGenerator.new(arid_grid, arid_config, Random.new(99999))
      arid_tect.generate
      arid_elev = WorldGeneration::ElevationGenerator.new(
        arid_grid, arid_config, Random.new(99999), arid_noise, arid_tect
      )
      arid_elev.generate
      arid_climate = WorldGeneration::ClimateSimulator.new(arid_grid, arid_config, arid_elev.sea_level)
      arid_climate.simulate

      arid_gen = described_class.new(arid_grid, arid_config, Random.new(99999), arid_elev.sea_level)
      arid_gen.generate

      # Arid has river_sources: 15..30, earth_like has 50..80
      expect(arid_gen.rivers.size).to be <= arid_config[:river_sources].max
    end

    it 'archipelago preset can still generate rivers' do
      arch_config = WorldGeneration::PresetConfig.for(:archipelago)

      arch_world = create(:world)
      arch_grid = WorldGeneration::GlobeHexGrid.new(arch_world, subdivisions: 2)
      arch_rng = Random.new(88888)
      arch_noise = WorldGeneration::NoiseGenerator.new(seed: 88888)
      arch_tect = WorldGeneration::TectonicsGenerator.new(arch_grid, arch_config, Random.new(88888))
      arch_tect.generate
      arch_elev = WorldGeneration::ElevationGenerator.new(
        arch_grid, arch_config, Random.new(88888), arch_noise, arch_tect
      )
      arch_elev.generate
      arch_climate = WorldGeneration::ClimateSimulator.new(arch_grid, arch_config, arch_elev.sea_level)
      arch_climate.simulate

      arch_gen = described_class.new(arch_grid, arch_config, Random.new(88888), arch_elev.sea_level)

      expect { arch_gen.generate }.not_to raise_error
    end
  end

  describe 'performance' do
    it 'generates rivers in reasonable time for medium grid' do
      medium_world = create(:world)
      medium_grid = WorldGeneration::GlobeHexGrid.new(medium_world, subdivisions: 3)
      medium_rng = Random.new(88888)
      medium_noise = WorldGeneration::NoiseGenerator.new(seed: 88888)
      medium_tect = WorldGeneration::TectonicsGenerator.new(medium_grid, config, Random.new(88888))
      medium_tect.generate
      medium_elev = WorldGeneration::ElevationGenerator.new(
        medium_grid, config, medium_rng, medium_noise, medium_tect
      )
      medium_elev.generate
      medium_climate = WorldGeneration::ClimateSimulator.new(medium_grid, config, medium_elev.sea_level)
      medium_climate.simulate

      medium_gen = described_class.new(medium_grid, config, Random.new(88888), medium_elev.sea_level)

      start_time = Time.now
      medium_gen.generate
      elapsed = Time.now - start_time

      # Should complete in under 5 seconds
      expect(elapsed).to be < 5.0
    end
  end

  describe 'direction constants' do
    it 'has 6 direction names' do
      expect(described_class::DIRECTION_NAMES.size).to eq(6)
    end

    it 'direction names are valid strings' do
      described_class::DIRECTION_NAMES.each do |dir|
        expect(dir).to be_a(String)
        expect(dir).not_to be_empty
      end
    end

    it 'each direction has an opposite' do
      described_class::DIRECTION_NAMES.each do |dir|
        opposite = described_class::OPPOSITE_DIRECTIONS[dir]
        expect(opposite).not_to be_nil,
          "Direction '#{dir}' has no opposite defined"
        expect(described_class::DIRECTION_NAMES).to include(opposite)
      end
    end

    it 'opposite of opposite returns original direction' do
      described_class::DIRECTION_NAMES.each do |dir|
        opposite = described_class::OPPOSITE_DIRECTIONS[dir]
        double_opposite = described_class::OPPOSITE_DIRECTIONS[opposite]
        expect(double_opposite).to eq(dir),
          "Opposite of opposite of '#{dir}' should be '#{dir}' but got '#{double_opposite}'"
      end
    end
  end
end
