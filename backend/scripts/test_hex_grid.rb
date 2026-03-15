# frozen_string_literal: true

#!/usr/bin/env ruby

require_relative '../app/lib/hex_grid'

puts "🔬 Testing Hex Grid Functions..."
puts "=" * 50

# Test valid_hex_coords?
puts "\n📋 Testing valid_hex_coords?:"
test_cases = [
  [0, 0, true],   # y=0 (0/2=0, even), x=0 (even) -> valid
  [2, 0, true],   # y=0 (0/2=0, even), x=2 (even) -> valid
  [1, 0, false],  # y=0 (0/2=0, even), x=1 (odd) -> invalid
  [1, 2, true],   # y=2 (2/2=1, odd), x=1 (odd) -> valid
  [2, 2, false],  # y=2 (2/2=1, odd), x=2 (even) -> invalid
  [0, 4, true],   # y=4 (4/2=2, even), x=0 (even) -> valid
  [1, 4, false],  # y=4 (4/2=2, even), x=1 (odd) -> invalid
  [3, 6, true],   # y=6 (6/2=3, odd), x=3 (odd) -> valid
  [4, 6, false],  # y=6 (6/2=3, odd), x=4 (even) -> invalid
  [0, 1, false],  # y=1 (odd) -> invalid
  [0, 3, false],  # y=3 (odd) -> invalid
]

test_cases.each do |x, y, expected|
  result = HexGrid.valid_hex_coords?(x, y)
  status = result == expected ? "✅" : "❌"
  puts "  #{status} (#{x}, #{y}) -> #{result} (expected #{expected})"
end

# Test to_hex_coords
puts "\n📋 Testing to_hex_coords (conversion):"
conversion_tests = [
  [0.5, 0.3, [0, 0]],     # Should round to (0, 0)
  [1.7, 0.8, [2, 0]],     # y=0 (even row), x should be even -> (2, 0)
  [1.2, 1.9, [1, 2]],     # y≈2 (odd row), x should be odd -> (1, 2)
  [2.8, 2.1, [3, 2]],     # y≈2 (odd row), x should be odd -> (3, 2)
  [3.1, 3.9, [4, 4]],     # y≈4 (even row), x should be even -> (4, 4)
  [4.7, 5.6, [5, 6]],     # y≈6 (odd row), x should be odd -> (5, 6)
  [-1.2, -0.8, [-2, 0]], # Negative values
  [0, -1.1, [1, -2]],     # Negative y should go to even, y=-2 is odd row
]

conversion_tests.each do |x, y, expected|
  result = HexGrid.to_hex_coords(x, y)
  status = result == expected ? "✅" : "❌"
  puts "  #{status} (#{x}, #{y}) -> #{result} (expected #{expected})"
end

# Test hex_coords_in_bounds
puts "\n📋 Testing hex_coords_in_bounds:"
bounds_result = HexGrid.hex_coords_in_bounds(-2, -2, 4, 4)
puts "  Coords in bounds (-2, -2, 4, 4):"
bounds_result.each do |coord|
  puts "    #{coord}"
end

valid_count = bounds_result.count { |x, y| HexGrid.valid_hex_coords?(x, y) }
puts "  ✅ All #{bounds_result.length} coordinates are valid hex coordinates" if valid_count == bounds_result.length

# Test hex_distance
puts "\n📋 Testing hex_distance:"
distance_tests = [
  [[0, 0], [0, 0], 0],    # Same point
  [[0, 0], [2, 0], 1],    # Adjacent horizontally
  [[0, 0], [0, 2], 1],    # Adjacent vertically  
  [[0, 0], [4, 0], 2],    # 2 steps away
  [[0, 0], [1, 2], 1],    # Diagonal adjacent
]

distance_tests.each do |coord1, coord2, expected|
  result = HexGrid.hex_distance(coord1[0], coord1[1], coord2[0], coord2[1])
  status = result == expected ? "✅" : "❌"
  puts "  #{status} #{coord1} to #{coord2} = #{result} (expected #{expected})"
end

# Test hex_neighbors
puts "\n📋 Testing hex_neighbors (should return NE, E, SE, SW, W, NW):"
neighbor_tests = [
  [0, 0],   # Even row
  [1, 2],   # Odd row
  [4, 4],   # Even row
]

neighbor_tests.each do |x, y|
  neighbors = HexGrid.hex_neighbors(x, y)
  puts "  Neighbors of (#{x}, #{y}) [NE, E, SE, SW, W, NW]: #{neighbors}"
  
  # Verify we have exactly 6 neighbors (or fewer if at edge)
  expected_count = 6
  actual_count = neighbors.length
  status = actual_count <= expected_count ? "✅" : "❌"
  puts "    #{status} Found #{actual_count} neighbors (max expected: #{expected_count})"
  
  # Verify all neighbors are valid hex coordinates
  all_valid = neighbors.all? { |nx, ny| HexGrid.valid_hex_coords?(nx, ny) }
  status = all_valid ? "✅" : "❌"
  puts "    #{status} All neighbors are valid hex coordinates"
  
  # Verify distance to each neighbor is 1
  distances = neighbors.map { |nx, ny| HexGrid.hex_distance(x, y, nx, ny) }
  all_distance_1 = distances.all? { |d| d == 1 }
  status = all_distance_1 ? "✅" : "❌"
  puts "    #{status} All neighbors are distance 1 away (distances: #{distances})"
  
  # Verify directions for known coordinates
  if x == 0 && y == 0
    expected_neighbors = [
      [1, 2],   # NE
      [2, 0],   # E
      [1, -2],  # SE
      [-1, -2], # SW
      [-2, 0],  # W
      [-1, 2]   # NW
    ].select { |nx, ny| HexGrid.valid_hex_coords?(nx, ny) }
    
    matches_expected = neighbors.all? { |neighbor| expected_neighbors.include?(neighbor) } &&
                      expected_neighbors.all? { |expected| neighbors.include?(expected) }
    status = matches_expected ? "✅" : "❌"
    puts "    #{status} Directions match expected pattern for (0,0)"
  end
end

# Test directional helper functions
puts "\n📋 Testing directional helper functions:"
test_coord = [0, 0]
directions = ['NE', 'E', 'SE', 'SW', 'W', 'NW']

puts "  Testing hex_neighbor_by_direction for (#{test_coord[0]}, #{test_coord[1]}):"
directions.each do |direction|
  neighbor = HexGrid.hex_neighbor_by_direction(test_coord[0], test_coord[1], direction)
  if neighbor
    distance = HexGrid.hex_distance(test_coord[0], test_coord[1], neighbor[0], neighbor[1])
    status = distance == 1 ? "✅" : "❌"
    puts "    #{status} #{direction}: #{neighbor} (distance: #{distance})"
  else
    puts "    ❌ #{direction}: no valid neighbor"
  end
end

puts "  Available directions from (#{test_coord[0]}, #{test_coord[1]}): #{HexGrid.available_directions(test_coord[0], test_coord[1])}"

# Test edge case - coordinate with fewer neighbors
puts "  Testing available directions for edge coordinates..."
edge_coords = [[-1, -2], [1, -2], [3, -2]]  # Bottom edge coordinates
edge_coords.each do |x, y|
  if HexGrid.valid_hex_coords?(x, y)
    available = HexGrid.available_directions(x, y)
    neighbor_count = HexGrid.hex_neighbors(x, y).length
    puts "    (#{x}, #{y}): #{neighbor_count} neighbors, directions: #{available}"
  end
end

puts "\n🎉 Hex Grid Testing Complete!"