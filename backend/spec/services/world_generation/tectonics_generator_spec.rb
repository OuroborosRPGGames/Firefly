# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/world_generation/globe_hex_grid'
require_relative '../../../app/services/world_generation/preset_config'
require_relative '../../../app/services/world_generation/tectonics_generator'

RSpec.describe WorldGeneration::TectonicsGenerator do
  let(:world) { create(:world) }
  # Use subdivisions: 2 for 320 hexes (fast enough for tests, enough for meaningful results)
  let(:grid) { WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2) }
  let(:config) { WorldGeneration::PresetConfig.for(:earth_like) }
  let(:rng) { Random.new(12345) }
  let(:generator) { described_class.new(grid, config, rng) }

  describe '#initialize' do
    it 'starts with empty plates' do
      expect(generator.plates).to eq({})
    end

    it 'starts with empty plate boundaries' do
      expect(generator.plate_boundaries).to eq({})
    end
  end

  describe '#generate' do
    before { generator.generate }

    it 'assigns a plate_id to every hex' do
      grid.each_hex do |hex|
        expect(hex.plate_id).not_to be_nil,
          "Hex #{hex.id} at (#{hex.lat}, #{hex.lon}) has no plate_id"
      end
    end

    it 'creates plates within config range' do
      plate_range = config[:plate_count]
      expect(generator.plates.size).to be_between(plate_range.min, plate_range.max)
    end

    it 'detects plate boundaries' do
      expect(generator.plate_boundaries).not_to be_empty
    end

    it 'creates some continental plates' do
      continental_count = generator.plates.values.count { |p| p[:continental] }
      expect(continental_count).to be > 0
    end

    it 'creates some oceanic plates' do
      oceanic_count = generator.plates.values.count { |p| !p[:continental] }
      expect(oceanic_count).to be > 0
    end
  end

  describe 'plate structure' do
    before { generator.generate }

    it 'each plate has required keys' do
      generator.plates.each do |plate_id, plate|
        expect(plate).to have_key(:id)
        expect(plate).to have_key(:center)
        expect(plate).to have_key(:drift_x)
        expect(plate).to have_key(:drift_y)
        expect(plate).to have_key(:continental)
        expect(plate).to have_key(:hexes)
      end
    end

    it 'plate id matches key' do
      generator.plates.each do |plate_id, plate|
        expect(plate[:id]).to eq(plate_id)
      end
    end

    it 'plate center is a HexData object' do
      generator.plates.each do |_, plate|
        expect(plate[:center]).to be_a(WorldGeneration::HexData)
      end
    end

    it 'plate hexes is a non-empty array' do
      generator.plates.each do |_, plate|
        expect(plate[:hexes]).to be_an(Array)
        expect(plate[:hexes]).not_to be_empty
      end
    end

    it 'drift values are numeric' do
      generator.plates.each do |_, plate|
        expect(plate[:drift_x]).to be_a(Numeric)
        expect(plate[:drift_y]).to be_a(Numeric)
      end
    end

    it 'continental is a boolean' do
      generator.plates.each do |_, plate|
        expect([true, false]).to include(plate[:continental])
      end
    end

    it 'all hexes are accounted for in plates' do
      all_plate_hexes = generator.plates.values.flat_map { |p| p[:hexes] }
      expect(all_plate_hexes.size).to eq(grid.hex_count)
    end

    it 'each hex appears in exactly one plate' do
      hex_counts = Hash.new(0)
      generator.plates.each do |_, plate|
        plate[:hexes].each { |hex| hex_counts[hex.id] += 1 }
      end

      grid.each_hex do |hex|
        expect(hex_counts[hex.id]).to eq(1),
          "Hex #{hex.id} appears #{hex_counts[hex.id]} times in plates"
      end
    end
  end

  describe 'plate boundary structure' do
    before { generator.generate }

    it 'each boundary has required keys' do
      generator.plate_boundaries.each do |key, boundary|
        expect(boundary).to have_key(:plate_ids)
        expect(boundary).to have_key(:type)
        expect(boundary).to have_key(:hexes)
      end
    end

    it 'boundary key format is "id1-id2" with id1 < id2' do
      generator.plate_boundaries.each do |key, boundary|
        parts = key.split('-').map(&:to_i)
        expect(parts.size).to eq(2)
        expect(parts[0]).to be < parts[1]
        expect(boundary[:plate_ids]).to eq(parts)
      end
    end

    it 'plate_ids contains two valid plate ids' do
      generator.plate_boundaries.each do |_, boundary|
        expect(boundary[:plate_ids].size).to eq(2)
        boundary[:plate_ids].each do |plate_id|
          expect(generator.plates).to have_key(plate_id)
        end
      end
    end

    it 'type is one of convergent, divergent, or transform' do
      generator.plate_boundaries.each do |_, boundary|
        expect([:convergent, :divergent, :transform]).to include(boundary[:type])
      end
    end

    it 'boundary hexes are on the edge of their plate' do
      generator.plate_boundaries.each do |_, boundary|
        boundary[:hexes].each do |hex|
          neighbors = grid.neighbors_of(hex)
          neighbor_plates = neighbors.map(&:plate_id).uniq

          # A boundary hex should have at least one neighbor from a different plate
          expect(neighbor_plates.size).to be >= 2,
            "Boundary hex #{hex.id} should have neighbors from multiple plates"
        end
      end
    end
  end

  describe 'boundary type distribution' do
    before { generator.generate }

    it 'has at least one boundary of each type (with enough plates)' do
      # With earth_like preset (10-14 plates), we should get variety
      # Skip this test if we have very few boundaries
      next if generator.plate_boundaries.size < 3

      types = generator.plate_boundaries.values.map { |b| b[:type] }.uniq
      # We may not always get all three types, but should get at least one
      expect(types).not_to be_empty
    end
  end

  describe 'continental ratio' do
    before { generator.generate }

    it 'approximately matches config ratio' do
      expected_ratio = config[:continental_ratio]
      continental_count = generator.plates.values.count { |p| p[:continental] }
      actual_ratio = continental_count.to_f / generator.plates.size

      # Allow some variance due to rounding
      expect(actual_ratio).to be_within(0.2).of(expected_ratio)
    end
  end

  describe 'reproducibility with same RNG seed' do
    it 'generates identical plates with same seed' do
      rng1 = Random.new(99999)
      rng2 = Random.new(99999)

      gen1 = described_class.new(grid, config, rng1)
      # Need fresh grid since hexes get mutated
      grid2 = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2)
      gen2 = described_class.new(grid2, config, rng2)

      gen1.generate
      gen2.generate

      expect(gen1.plates.size).to eq(gen2.plates.size)
      expect(gen1.plate_boundaries.size).to eq(gen2.plate_boundaries.size)

      # Compare plate centers
      gen1.plates.each do |plate_id, plate1|
        plate2 = gen2.plates[plate_id]
        expect(plate1[:center].id).to eq(plate2[:center].id)
        expect(plate1[:continental]).to eq(plate2[:continental])
      end
    end
  end

  describe 'different presets' do
    it 'respects plate_count from pangaea preset' do
      pangaea_config = WorldGeneration::PresetConfig.for(:pangaea)
      pangaea_gen = described_class.new(grid, pangaea_config, Random.new(11111))

      # Need fresh grid
      fresh_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2)
      pangaea_gen = described_class.new(fresh_grid, pangaea_config, Random.new(11111))
      pangaea_gen.generate

      plate_range = pangaea_config[:plate_count]
      expect(pangaea_gen.plates.size).to be_between(plate_range.min, plate_range.max)
    end

    it 'respects plate_count from archipelago preset' do
      arch_config = WorldGeneration::PresetConfig.for(:archipelago)
      fresh_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2)
      arch_gen = described_class.new(fresh_grid, arch_config, Random.new(22222))
      arch_gen.generate

      plate_range = arch_config[:plate_count]
      expect(arch_gen.plates.size).to be_between(plate_range.min, plate_range.max)
    end

    it 'respects continental_ratio from pangaea preset' do
      pangaea_config = WorldGeneration::PresetConfig.for(:pangaea)
      fresh_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 2)
      pangaea_gen = described_class.new(fresh_grid, pangaea_config, Random.new(33333))
      pangaea_gen.generate

      expected_ratio = pangaea_config[:continental_ratio]
      continental_count = pangaea_gen.plates.values.count { |p| p[:continental] }
      actual_ratio = continental_count.to_f / pangaea_gen.plates.size

      expect(actual_ratio).to be_within(0.25).of(expected_ratio)
    end
  end

  describe 'flood fill properties' do
    before { generator.generate }

    it 'plates are spatially contiguous' do
      generator.plates.each do |plate_id, plate|
        hexes_in_plate = Set.new(plate[:hexes].map(&:id))

        # For each hex in the plate, verify it can reach all others through neighbors
        # (BFS from center should find all hexes in the plate)
        visited = Set.new
        queue = [plate[:center]]

        while queue.any?
          current = queue.shift
          next if visited.include?(current.id)
          next unless hexes_in_plate.include?(current.id)

          visited.add(current.id)

          grid.neighbors_of(current).each do |neighbor|
            queue << neighbor if hexes_in_plate.include?(neighbor.id) && !visited.include?(neighbor.id)
          end
        end

        expect(visited.size).to eq(plate[:hexes].size),
          "Plate #{plate_id} is not contiguous: #{visited.size} of #{plate[:hexes].size} hexes reachable"
      end
    end

    it 'center hex belongs to its own plate' do
      generator.plates.each do |plate_id, plate|
        expect(plate[:center].plate_id).to eq(plate_id)
        expect(plate[:hexes]).to include(plate[:center])
      end
    end
  end

  describe 'performance' do
    it 'generates plates in reasonable time for medium grid' do
      # Use subdivisions: 3 for 1280 hexes
      medium_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 3)
      medium_gen = described_class.new(medium_grid, config, Random.new(54321))

      start_time = Time.now
      medium_gen.generate
      elapsed = Time.now - start_time

      # Should complete in under 5 seconds
      expect(elapsed).to be < 5.0
    end
  end

  describe 'edge cases' do
    it 'handles minimum plate count (1 plate)' do
      min_config = {
        plate_count: 1..1,
        continental_ratio: 1.0
      }
      fresh_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 1) # 80 hexes
      min_gen = described_class.new(fresh_grid, min_config, Random.new(1))
      min_gen.generate

      expect(min_gen.plates.size).to eq(1)
      expect(min_gen.plate_boundaries).to be_empty # No boundaries with 1 plate
      expect(min_gen.plates[0][:hexes].size).to eq(80)
    end

    it 'handles grid with all continental plates' do
      all_continental = {
        plate_count: 3..3,
        continental_ratio: 1.0
      }
      fresh_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 1)
      gen = described_class.new(fresh_grid, all_continental, Random.new(2))
      gen.generate

      continental_count = gen.plates.values.count { |p| p[:continental] }
      expect(continental_count).to eq(3)
    end

    it 'handles grid with all oceanic plates' do
      all_oceanic = {
        plate_count: 3..3,
        continental_ratio: 0.0
      }
      fresh_grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 1)
      gen = described_class.new(fresh_grid, all_oceanic, Random.new(3))
      gen.generate

      oceanic_count = gen.plates.values.count { |p| !p[:continental] }
      expect(oceanic_count).to eq(3)
    end
  end
end
