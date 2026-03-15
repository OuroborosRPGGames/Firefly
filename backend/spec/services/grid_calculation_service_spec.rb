# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/services/grid_calculation_service'

RSpec.describe GridCalculationService do
  describe '.city_dimensions' do
    it 'calculates correct dimensions for a 10x10 grid' do
      result = described_class.city_dimensions(horizontal_streets: 10, vertical_streets: 10)

      expect(result[:width]).to eq(1750)   # 10 * 175
      expect(result[:height]).to eq(1750)  # 10 * 175
    end

    it 'handles asymmetric grids' do
      result = described_class.city_dimensions(horizontal_streets: 5, vertical_streets: 8)

      expect(result[:width]).to eq(1400)  # 8 * 175
      expect(result[:height]).to eq(875)  # 5 * 175
    end
  end

  describe '.street_bounds' do
    it 'calculates correct bounds for first street (index 0)' do
      result = described_class.street_bounds(grid_index: 0, city_size: 10)

      expect(result[:min_x]).to eq(0)
      expect(result[:max_x]).to eq(1750)  # 10 * 175
      expect(result[:min_y]).to eq(0)
      expect(result[:max_y]).to eq(25)    # Street width
      expect(result[:min_z]).to eq(0)
      expect(result[:max_z]).to eq(10)
    end

    it 'calculates correct bounds for second street (index 1)' do
      result = described_class.street_bounds(grid_index: 1, city_size: 10)

      expect(result[:min_y]).to eq(175)   # 1 * 175
      expect(result[:max_y]).to eq(200)   # 175 + 25
    end

    it 'calculates correct bounds for third street (index 2)' do
      result = described_class.street_bounds(grid_index: 2, city_size: 10)

      expect(result[:min_y]).to eq(350)   # 2 * 175
      expect(result[:max_y]).to eq(375)   # 350 + 25
    end
  end

  describe '.avenue_bounds' do
    it 'calculates correct bounds for first avenue (index 0)' do
      result = described_class.avenue_bounds(grid_index: 0, city_size: 10)

      expect(result[:min_x]).to eq(0)
      expect(result[:max_x]).to eq(25)    # Street width
      expect(result[:min_y]).to eq(0)
      expect(result[:max_y]).to eq(1750)  # 10 * 175
    end

    it 'calculates correct bounds for fifth avenue (index 4)' do
      result = described_class.avenue_bounds(grid_index: 4, city_size: 10)

      expect(result[:min_x]).to eq(700)   # 4 * 175
      expect(result[:max_x]).to eq(725)   # 700 + 25
    end
  end

  describe '.intersection_bounds' do
    it 'calculates correct bounds for origin intersection (0,0)' do
      result = described_class.intersection_bounds(grid_x: 0, grid_y: 0)

      expect(result[:min_x]).to eq(0)
      expect(result[:max_x]).to eq(25)
      expect(result[:min_y]).to eq(0)
      expect(result[:max_y]).to eq(25)
    end

    it 'calculates correct bounds for intersection at (2, 3)' do
      result = described_class.intersection_bounds(grid_x: 2, grid_y: 3)

      expect(result[:min_x]).to eq(350)   # 2 * 175
      expect(result[:max_x]).to eq(375)   # 350 + 25
      expect(result[:min_y]).to eq(525)   # 3 * 175
      expect(result[:max_y]).to eq(550)   # 525 + 25
    end

    it 'creates 25x25 intersection' do
      result = described_class.intersection_bounds(grid_x: 5, grid_y: 5)

      width = result[:max_x] - result[:min_x]
      height = result[:max_y] - result[:min_y]

      expect(width).to eq(25)
      expect(height).to eq(25)
    end
  end

  describe '.block_bounds' do
    it 'calculates buildable area after street offset' do
      result = described_class.block_bounds(intersection_x: 0, intersection_y: 0)

      # Block starts after the 25ft street
      expect(result[:min_x]).to eq(25)
      expect(result[:max_x]).to eq(175)
      expect(result[:min_y]).to eq(25)
      expect(result[:max_y]).to eq(175)
    end

    it 'calculates correct width and height' do
      result = described_class.block_bounds(intersection_x: 2, intersection_y: 3)

      # Block is 150x150 (175 - 25 = 150)
      expect(result[:width]).to eq(150)
      expect(result[:height]).to eq(150)
    end

    it 'positions block correctly at arbitrary position' do
      result = described_class.block_bounds(intersection_x: 5, intersection_y: 7)

      expect(result[:min_x]).to eq(5 * 175 + 25)   # 900
      expect(result[:max_x]).to eq(6 * 175)        # 1050
      expect(result[:min_y]).to eq(7 * 175 + 25)   # 1250
      expect(result[:max_y]).to eq(8 * 175)        # 1400
    end
  end

  describe '.building_footprint' do
    let(:block) { described_class.block_bounds(intersection_x: 0, intersection_y: 0) }

    context 'with position :full' do
      it 'uses the entire block' do
        result = described_class.building_footprint(
          block_bounds: block,
          building_type: :apartment_tower,
          position: :full
        )

        expect(result[:min_x]).to eq(block[:min_x])
        expect(result[:max_x]).to eq(block[:max_x])
        expect(result[:min_y]).to eq(block[:min_y])
        expect(result[:max_y]).to eq(block[:max_y])
      end

      it 'respects max_height' do
        result = described_class.building_footprint(
          block_bounds: block,
          building_type: :apartment_tower,
          position: :full,
          max_height: 100
        )

        expect(result[:max_z]).to eq(100)
      end
    end

    context 'with position :north' do
      it 'uses the northern half of the block' do
        result = described_class.building_footprint(
          block_bounds: block,
          building_type: :house,
          position: :north
        )

        mid_y = (block[:min_y] + block[:max_y]) / 2

        expect(result[:min_y]).to eq(mid_y)
        expect(result[:max_y]).to eq(block[:max_y])
      end
    end

    context 'with position :south' do
      it 'uses the southern half of the block' do
        result = described_class.building_footprint(
          block_bounds: block,
          building_type: :house,
          position: :south
        )

        mid_y = (block[:min_y] + block[:max_y]) / 2

        expect(result[:min_y]).to eq(block[:min_y])
        expect(result[:max_y]).to eq(mid_y)
      end
    end
  end

  describe '.floor_bounds' do
    let(:building) do
      {
        min_x: 100, max_x: 200,
        min_y: 100, max_y: 200,
        min_z: 0, max_z: 100
      }
    end

    it 'calculates ground floor (floor 0) bounds' do
      result = described_class.floor_bounds(building_bounds: building, floor_number: 0)

      expect(result[:min_z]).to eq(0)
      expect(result[:max_z]).to eq(10)
      expect(result[:min_x]).to eq(building[:min_x])
      expect(result[:max_x]).to eq(building[:max_x])
    end

    it 'calculates upper floor bounds' do
      result = described_class.floor_bounds(building_bounds: building, floor_number: 5)

      expect(result[:min_z]).to eq(50)
      expect(result[:max_z]).to eq(60)
    end

    it 'respects custom floor height' do
      result = described_class.floor_bounds(
        building_bounds: building,
        floor_number: 2,
        floor_height: 15
      )

      expect(result[:min_z]).to eq(30)
      expect(result[:max_z]).to eq(45)
    end
  end

  describe '.unit_bounds' do
    let(:floor) do
      {
        min_x: 0, max_x: 100,
        min_y: 0, max_y: 100,
        min_z: 0, max_z: 10
      }
    end

    it 'calculates first unit (index 0) in 2x2 grid' do
      result = described_class.unit_bounds(
        floor_bounds: floor,
        units_x: 2,
        units_y: 2,
        unit_index: 0
      )

      expect(result[:min_x]).to eq(0)
      expect(result[:max_x]).to eq(50)
      expect(result[:min_y]).to eq(0)
      expect(result[:max_y]).to eq(50)
    end

    it 'calculates fourth unit (index 3) in 2x2 grid' do
      result = described_class.unit_bounds(
        floor_bounds: floor,
        units_x: 2,
        units_y: 2,
        unit_index: 3
      )

      expect(result[:min_x]).to eq(50)
      expect(result[:max_x]).to eq(100)
      expect(result[:min_y]).to eq(50)
      expect(result[:max_y]).to eq(100)
    end
  end

  describe '.format_address' do
    it 'formats address without unit number' do
      result = described_class.format_address(
        street_name: 'Oak Street',
        grid_x: 2,
        grid_y: 3
      )

      expect(result).to eq('321 Oak Street')
    end

    it 'formats address with unit number' do
      result = described_class.format_address(
        street_name: 'Main Avenue',
        grid_x: 1,
        grid_y: 5,
        unit_number: 4
      )

      expect(result).to eq('511 Main Avenue, #4')
    end
  end

  describe '.point_to_grid' do
    it 'identifies point in block area' do
      result = described_class.point_to_grid(x: 100, y: 100)

      expect(result[:grid_x]).to eq(0)
      expect(result[:grid_y]).to eq(0)
      expect(result[:on_street]).to be false
      expect(result[:on_avenue]).to be false
      expect(result[:at_intersection]).to be false
    end

    it 'identifies point on a street' do
      result = described_class.point_to_grid(x: 100, y: 10)

      expect(result[:on_street]).to be true
      expect(result[:on_avenue]).to be false
    end

    it 'identifies point on an avenue' do
      result = described_class.point_to_grid(x: 10, y: 100)

      expect(result[:on_avenue]).to be true
      expect(result[:on_street]).to be false
    end

    it 'identifies point at intersection' do
      result = described_class.point_to_grid(x: 10, y: 10)

      expect(result[:at_intersection]).to be true
    end
  end

  describe '.building_config' do
    it 'returns configuration for brownstone' do
      result = described_class.building_config(:brownstone)

      expect(result[:width]).to eq(30)
      expect(result[:height]).to eq(30)
      expect(result[:floors]).to eq(3)
    end

    it 'returns configuration for apartment_tower' do
      result = described_class.building_config(:apartment_tower)

      expect(result[:height]).to eq(200)
      expect(result[:floors]).to eq(20)
      expect(result[:units_per_floor]).to eq(4)
    end

    it 'defaults to house for unknown type' do
      result = described_class.building_config(:unknown_type)

      expect(result).to eq(described_class.building_config(:house))
    end
  end
end
