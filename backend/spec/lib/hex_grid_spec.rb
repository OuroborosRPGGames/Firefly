# frozen_string_literal: true

require 'spec_helper'

RSpec.describe HexGrid do
  describe 'HEX_SIZE_FEET' do
    it 'is set to 2 feet per hex' do
      expect(HexGrid::HEX_SIZE_FEET).to eq(2)
    end
  end

  describe '.feet_to_hex' do
    it 'converts (0, 0) feet to (0, 0) hex' do
      expect(described_class.feet_to_hex(0, 0)).to eq([0, 0])
    end

    it 'converts (4, 4) feet to valid hex coordinates' do
      result = described_class.feet_to_hex(4, 4)
      expect(described_class.valid_hex_coords?(*result)).to be true
    end

    it 'converts (8, 8) feet to valid hex (4,4)' do
      result = described_class.feet_to_hex(8, 8)
      # Raw (4, 4): y=4, (4/2)=2 is even, so x should be even → 4 is valid
      expect(described_class.valid_hex_coords?(*result)).to be true
      expect(result).to eq([4, 4])
    end

    it 'accounts for room offset' do
      result = described_class.feet_to_hex(10, 10, 2, 2)
      expect(described_class.valid_hex_coords?(*result)).to be true
    end

    it 'rounds to nearest hex' do
      result = described_class.feet_to_hex(5, 5)
      expect(described_class.valid_hex_coords?(*result)).to be true
    end

    context 'with negative coordinates' do
      it 'handles negative feet values' do
        result = described_class.feet_to_hex(-8, -8)
        expect(described_class.valid_hex_coords?(*result)).to be true
      end
    end
  end

  describe '.hex_to_feet' do
    it 'converts (0, 0) hex to (0.0, 0.0) feet' do
      expect(described_class.hex_to_feet(0, 0)).to eq([0.0, 0.0])
    end

    it 'converts (2, 0) hex to (4.0, 0.0) feet' do
      expect(described_class.hex_to_feet(2, 0)).to eq([4.0, 0.0])
    end

    it 'converts (1, 2) hex to (2.0, 4.0) feet' do
      expect(described_class.hex_to_feet(1, 2)).to eq([2.0, 4.0])
    end

    it 'accounts for room offset' do
      expect(described_class.hex_to_feet(2, 0, 5, 10)).to eq([9.0, 10.0])
    end

    it 'returns floats' do
      result = described_class.hex_to_feet(1, 2)
      expect(result).to all(be_a(Float))
    end
  end

  describe '.arena_dimensions_from_feet' do
    it 'converts room dimensions to arena hexes' do
      width, height = described_class.arena_dimensions_from_feet(20, 16)
      expect(width).to eq(10)
      expect(height).to eq(8)
    end

    it 'returns minimum of 1 for each dimension' do
      width, height = described_class.arena_dimensions_from_feet(1, 1)
      expect(width).to be >= 1
      expect(height).to be >= 1
    end

    it 'rounds up partial hexes' do
      width, height = described_class.arena_dimensions_from_feet(5, 5)
      expect(width).to eq(3)
      expect(height).to eq(3)
    end

    it 'handles zero dimensions' do
      width, height = described_class.arena_dimensions_from_feet(0, 0)
      expect(width).to eq(1)
      expect(height).to eq(1)
    end

    context 'large room compression' do
      it 'does not compress dimensions at or below threshold' do
        # 60ft → 30 hexes (at threshold), no compression
        width, height = described_class.arena_dimensions_from_feet(60, 60)
        expect(width).to eq(30)
        expect(height).to eq(30)
      end

      it 'compresses dimensions above threshold halfway toward 30' do
        # 180ft → 90 natural hexes → (90 + 30) / 2 = 60
        width, height = described_class.arena_dimensions_from_feet(180, 180)
        expect(width).to eq(60)
        expect(height).to eq(60)
      end

      it 'compresses moderately sized rooms proportionally' do
        # 120ft → 60 natural hexes → (60 + 30) / 2 = 45
        width, height = described_class.arena_dimensions_from_feet(120, 120)
        expect(width).to eq(45)
        expect(height).to eq(45)
      end
    end

    context 'aspect ratio capping' do
      it 'caps wide rooms to 3:1 ratio after compression' do
        # 20ft × 100ft = 10×50 hexes → 50 compresses to (50+30)/2=40 → 10×40 → capped to 10×30
        width, height = described_class.arena_dimensions_from_feet(20, 100)
        expect(width).to eq(10)
        expect(height).to eq(30) # 10 * 3 = 30
      end

      it 'caps tall rooms to 3:1 ratio after compression' do
        # 100ft × 20ft = 50×10 hexes → 50 compresses to 40 → 40×10 → capped to 30×10
        width, height = described_class.arena_dimensions_from_feet(100, 20)
        expect(width).to eq(30)
        expect(height).to eq(10)
      end

      it 'does not cap rooms within 3:1 ratio' do
        # 20ft × 60ft = 10×30 hexes → both within threshold, no compression or aspect cap
        width, height = described_class.arena_dimensions_from_feet(20, 60)
        expect(width).to eq(10)
        expect(height).to eq(30)
      end

      it 'does not cap square rooms' do
        width, height = described_class.arena_dimensions_from_feet(40, 40)
        expect(width).to eq(20)
        expect(height).to eq(20)
      end
    end
  end

  describe '.valid_hex_coords?' do
    context 'with y = 0 (row 0)' do
      it 'returns true for even x' do
        expect(described_class.valid_hex_coords?(0, 0)).to be true
        expect(described_class.valid_hex_coords?(2, 0)).to be true
        expect(described_class.valid_hex_coords?(4, 0)).to be true
        expect(described_class.valid_hex_coords?(-2, 0)).to be true
      end

      it 'returns false for odd x' do
        expect(described_class.valid_hex_coords?(1, 0)).to be false
        expect(described_class.valid_hex_coords?(3, 0)).to be false
        expect(described_class.valid_hex_coords?(-1, 0)).to be false
      end
    end

    context 'with y = 2 (row 1)' do
      it 'returns true for odd x' do
        expect(described_class.valid_hex_coords?(1, 2)).to be true
        expect(described_class.valid_hex_coords?(3, 2)).to be true
        expect(described_class.valid_hex_coords?(-1, 2)).to be true
      end

      it 'returns false for even x' do
        expect(described_class.valid_hex_coords?(0, 2)).to be false
        expect(described_class.valid_hex_coords?(2, 2)).to be false
      end
    end

    context 'with y = 4 (row 2)' do
      it 'returns true for even x (same pattern as y = 0)' do
        expect(described_class.valid_hex_coords?(0, 4)).to be true
        expect(described_class.valid_hex_coords?(2, 4)).to be true
      end

      it 'returns false for odd x' do
        expect(described_class.valid_hex_coords?(1, 4)).to be false
        expect(described_class.valid_hex_coords?(3, 4)).to be false
      end
    end

    context 'with y = 6 (row 3)' do
      it 'returns true for odd x (same pattern as y = 2)' do
        expect(described_class.valid_hex_coords?(1, 6)).to be true
        expect(described_class.valid_hex_coords?(3, 6)).to be true
      end
    end

    context 'with odd y values' do
      it 'returns false for any x' do
        expect(described_class.valid_hex_coords?(0, 1)).to be false
        expect(described_class.valid_hex_coords?(1, 1)).to be false
        expect(described_class.valid_hex_coords?(0, 3)).to be false
        expect(described_class.valid_hex_coords?(1, 3)).to be false
      end
    end

    context 'with negative coordinates' do
      it 'follows the same pattern' do
        expect(described_class.valid_hex_coords?(-2, 0)).to be true
        expect(described_class.valid_hex_coords?(-1, 2)).to be true
        expect(described_class.valid_hex_coords?(-2, -4)).to be true
        expect(described_class.valid_hex_coords?(-1, -2)).to be true
      end
    end
  end

  describe '.to_hex_coords' do
    it 'returns the same coords if already valid' do
      expect(described_class.to_hex_coords(0, 0)).to eq([0, 0])
      expect(described_class.to_hex_coords(2, 0)).to eq([2, 0])
      expect(described_class.to_hex_coords(1, 2)).to eq([1, 2])
    end

    it 'snaps odd y to nearest even y' do
      result = described_class.to_hex_coords(0, 1)
      expect(result[1]).to be_even
    end

    it 'adjusts x based on the snapped y' do
      result = described_class.to_hex_coords(2, 2)
      # y = 2 requires odd x, so 2 should snap to 1 or 3
      expect(result[0]).to be_odd
    end

    it 'returns valid hex coordinates for any input' do
      [-5, -1, 0, 1, 3, 5, 10].each do |x|
        [-5, -1, 0, 1, 3, 5, 10].each do |y|
          result = described_class.to_hex_coords(x, y)
          rx, ry = result
          is_valid = described_class.valid_hex_coords?(rx, ry)
          expect(is_valid).to be(true), "Expected to_hex_coords(#{x}, #{y}) = #{result.inspect} to be valid"
        end
      end
    end
  end

  describe '.hex_coords_in_bounds' do
    it 'returns all valid hex coordinates in bounds' do
      coords = described_class.hex_coords_in_bounds(0, 0, 4, 4)

      coords.each do |coord|
        cx, cy = coord
        is_valid = described_class.valid_hex_coords?(cx, cy)
        expect(is_valid).to be(true), "Expected (#{cx}, #{cy}) to be valid hex coords"
      end
    end

    it 'includes origin when bounds include it' do
      coords = described_class.hex_coords_in_bounds(0, 0, 4, 4)
      expect(coords).to include([0, 0])
    end

    it 'returns correct hexes for a small area' do
      coords = described_class.hex_coords_in_bounds(0, 0, 4, 4)
      # y=0: even x -> [0, 2, 4]
      # y=2: odd x -> [1, 3]
      # y=4: even x -> [0, 2, 4]
      expected = [
        [0, 0], [2, 0], [4, 0],
        [1, 2], [3, 2],
        [0, 4], [2, 4], [4, 4]
      ]
      expect(coords).to match_array(expected)
    end

    it 'returns empty array for invalid bounds' do
      coords = described_class.hex_coords_in_bounds(5, 5, 0, 0)
      expect(coords).to eq([])
    end
  end

  describe '.hex_distance' do
    it 'returns 0 for same hex' do
      expect(described_class.hex_distance(0, 0, 0, 0)).to eq(0)
    end

    it 'calculates distance for horizontal movement (no direct E/W neighbors)' do
      # (0,0) to (2,0) requires zigzag: NE(1,2) then SE(2,0) = 2 steps
      expect(described_class.hex_distance(0, 0, 2, 0)).to eq(2)
      # (0,0) to (4,0) = 4 steps via zigzag
      expect(described_class.hex_distance(0, 0, 4, 0)).to eq(4)
    end

    it 'calculates distance for vertical movement' do
      # (0,0) to (0,4) is one N step
      expect(described_class.hex_distance(0, 0, 0, 4)).to eq(1)
      # (0,0) to (0,8) is two N steps
      expect(described_class.hex_distance(0, 0, 0, 8)).to eq(2)
    end

    it 'calculates distance for diagonal movement' do
      # From (0,0) to (1,2) is one step (NE)
      expect(described_class.hex_distance(0, 0, 1, 2)).to eq(1)
      # From (0,0) to (2,4) is two steps (NE, NE)
      expect(described_class.hex_distance(0, 0, 2, 4)).to eq(2)
    end

    it 'calculates distance for mixed diagonal and vertical' do
      # (0,0) to (1,6): NE(1,2) then N(1,6) = 2 steps
      expect(described_class.hex_distance(0, 0, 1, 6)).to eq(2)
    end

    it 'is symmetric' do
      expect(described_class.hex_distance(0, 0, 3, 2)).to eq(described_class.hex_distance(3, 2, 0, 0))
    end

    it 'works with negative coordinates' do
      # From (-2,0) to (2,0) = 4 steps via zigzag
      expect(described_class.hex_distance(-2, 0, 2, 0)).to eq(4)
    end
  end

  describe '.hex_neighbors' do
    it 'returns empty array for invalid coords' do
      expect(described_class.hex_neighbors(1, 0)).to eq([])
    end

    it 'returns 6 neighbors for valid coords in center' do
      neighbors = described_class.hex_neighbors(0, 0)
      expect(neighbors.length).to eq(6)
      # All returned neighbors should be valid
      neighbors.each do |nx, ny|
        expect(described_class.valid_hex_coords?(nx, ny)).to be true
      end
    end

    it 'returns neighbors in N, NE, SE, S, SW, NW order' do
      neighbors = described_class.hex_neighbors(0, 0)
      # Same offsets for all rows: (0,+4), (+1,+2), (+1,-2), (0,-4), (-1,-2), (-1,+2)
      expect(neighbors[0]).to eq([0, 4])   # N
      expect(neighbors[1]).to eq([1, 2])   # NE
      expect(neighbors[2]).to eq([1, -2])  # SE
      expect(neighbors[3]).to eq([0, -4])  # S
      expect(neighbors[4]).to eq([-1, -2]) # SW
      expect(neighbors[5]).to eq([-1, 2])  # NW
    end

    it 'returns correct neighbors for odd row' do
      neighbors = described_class.hex_neighbors(1, 2)
      expect(neighbors.length).to eq(6)
      # Same offsets: N(1,6), NE(2,4), SE(2,0), S(1,-2), SW(0,0), NW(0,4)
      expect(neighbors[0]).to eq([1, 6])   # N
      expect(neighbors[1]).to eq([2, 4])   # NE
      expect(neighbors[2]).to eq([2, 0])   # SE
      expect(neighbors[3]).to eq([1, -2])  # S
      expect(neighbors[4]).to eq([0, 0])   # SW
      expect(neighbors[5]).to eq([0, 4])   # NW
      neighbors.each do |nx, ny|
        expect(described_class.valid_hex_coords?(nx, ny)).to be true
      end
    end
  end

  describe '.hex_neighbor_by_direction' do
    it 'returns nil for invalid coords' do
      expect(described_class.hex_neighbor_by_direction(1, 0, 'NE')).to be_nil
    end

    it 'returns nil for invalid direction' do
      expect(described_class.hex_neighbor_by_direction(0, 0, 'INVALID')).to be_nil
    end

    it 'returns correct neighbor for N' do
      expect(described_class.hex_neighbor_by_direction(0, 0, 'N')).to eq([0, 4])
    end

    it 'returns correct neighbor for NE' do
      expect(described_class.hex_neighbor_by_direction(0, 0, 'NE')).to eq([1, 2])
    end

    it 'returns correct neighbor for SE' do
      expect(described_class.hex_neighbor_by_direction(0, 0, 'SE')).to eq([1, -2])
    end

    it 'returns correct neighbor for S' do
      expect(described_class.hex_neighbor_by_direction(0, 0, 'S')).to eq([0, -4])
    end

    it 'returns correct neighbor for SW' do
      expect(described_class.hex_neighbor_by_direction(0, 0, 'SW')).to eq([-1, -2])
    end

    it 'returns correct neighbor for NW' do
      expect(described_class.hex_neighbor_by_direction(0, 0, 'NW')).to eq([-1, 2])
    end

    it 'returns nil for E/W (not valid hex directions)' do
      expect(described_class.hex_neighbor_by_direction(0, 0, 'E')).to be_nil
      expect(described_class.hex_neighbor_by_direction(0, 0, 'W')).to be_nil
    end

    it 'accepts lowercase direction' do
      expect(described_class.hex_neighbor_by_direction(0, 0, 'ne')).to eq([1, 2])
    end

    it 'accepts symbol direction' do
      expect(described_class.hex_neighbor_by_direction(0, 0, :ne)).to eq([1, 2])
    end
  end

  describe '.available_directions' do
    it 'returns empty array for invalid coords' do
      expect(described_class.available_directions(1, 0)).to eq([])
    end

    it 'returns all 6 directions for valid coords' do
      directions = described_class.available_directions(0, 0)
      expect(directions).to eq(%w[N NE SE S SW NW])
    end
  end

  describe 'coordinate system consistency' do
    it 'feet_to_hex and hex_to_feet are inverse operations' do
      # Start with a valid hex coordinate
      original_hex = [2, 4]
      feet = described_class.hex_to_feet(*original_hex)
      recovered_hex = described_class.feet_to_hex(*feet)

      expect(recovered_hex).to eq(original_hex)
    end

    it 'neighbors are at distance 1' do
      neighbors = described_class.hex_neighbors(0, 0)
      neighbors.each do |nx, ny|
        distance = described_class.hex_distance(0, 0, nx, ny)
        expect(distance).to eq(1), "Expected neighbor (#{nx}, #{ny}) to be at distance 1, got #{distance}"
      end
    end
  end
end
