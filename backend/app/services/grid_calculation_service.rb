# frozen_string_literal: true

# GridCalculationService handles all coordinate calculations for city grids.
#
# Based on Ravencroft's grid system:
# - Cell size: 175x175 feet
# - Street width: 25 feet
# - Intersections: 25x25 feet at grid crossings
#
# Coordinate system:
# - X axis: East-West (avenues run N-S, so positioned on X)
# - Y axis: North-South (streets run E-W, so positioned on Y)
# - Z axis: Elevation (ground = 0, buildings go up)
#
# Grid layout:
#   Each cell is 175x175 feet
#   Streets are 25 feet wide at the edge of cells
#   Total width for N streets = N * 175 + 25 (final street)
#
class GridCalculationService
  GRID_CELL_SIZE = 175  # feet
  STREET_WIDTH = 25     # feet

  class << self
    # Calculate the total dimensions of a city grid
    # @param horizontal_streets [Integer] number of E-W running streets
    # @param vertical_streets [Integer] number of N-S running avenues
    # @return [Hash] { width:, height: } in feet
    def city_dimensions(horizontal_streets:, vertical_streets:)
      # Each avenue/street creates a line, with cells between them
      # Total width = (number of avenues) * cell_size
      # We include the street width at the edge
      width = vertical_streets * GRID_CELL_SIZE
      height = horizontal_streets * GRID_CELL_SIZE

      { width: width, height: height }
    end

    # Calculate room bounds for a street segment (E-W running, between two avenues)
    # Street segments connect intersections and don't overlap with them.
    # @param street_index [Integer] the Y grid position (0-based)
    # @param segment_index [Integer] which segment between avenues (0 = between avenue 0-1)
    # @param avenue_count [Integer] number of avenues (determines how many segments)
    # @return [Hash, nil] { min_x:, max_x:, min_y:, max_y:, min_z:, max_z: } or nil if invalid
    def street_segment_bounds(street_index:, segment_index:, avenue_count:)
      # Street segments run between intersections
      # Segment 0 is between avenue 0 and avenue 1 (x = 25 to 175)
      # Segment 1 is between avenue 1 and avenue 2 (x = 200 to 350)
      return nil if segment_index >= avenue_count - 1

      min_x = (segment_index * GRID_CELL_SIZE) + STREET_WIDTH  # Start after intersection
      max_x = ((segment_index + 1) * GRID_CELL_SIZE)           # End before next intersection
      min_y = street_index * GRID_CELL_SIZE
      max_y = min_y + STREET_WIDTH

      {
        min_x: min_x,
        max_x: max_x,
        min_y: min_y,
        max_y: max_y,
        min_z: 0,
        max_z: 10
      }
    end

    # Calculate room bounds for an avenue segment (N-S running, between two streets)
    # Avenue segments connect intersections and don't overlap with them.
    # @param avenue_index [Integer] the X grid position (0-based)
    # @param segment_index [Integer] which segment between streets (0 = between street 0-1)
    # @param street_count [Integer] number of streets (determines how many segments)
    # @return [Hash, nil] { min_x:, max_x:, min_y:, max_y:, min_z:, max_z: } or nil if invalid
    def avenue_segment_bounds(avenue_index:, segment_index:, street_count:)
      # Avenue segments run between intersections
      # Segment 0 is between street 0 and street 1 (y = 25 to 175)
      return nil if segment_index >= street_count - 1

      min_x = avenue_index * GRID_CELL_SIZE
      max_x = min_x + STREET_WIDTH
      min_y = (segment_index * GRID_CELL_SIZE) + STREET_WIDTH  # Start after intersection
      max_y = ((segment_index + 1) * GRID_CELL_SIZE)           # End before next intersection

      {
        min_x: min_x,
        max_x: max_x,
        min_y: min_y,
        max_y: max_y,
        min_z: 0,
        max_z: 10
      }
    end

    # Calculate room bounds for a street (E-W running)
    # Streets span the full width of the city at a specific Y position
    # @param grid_index [Integer] the grid position (0-based)
    # @param city_size [Integer] number of avenues (determines width)
    # @return [Hash] { min_x:, max_x:, min_y:, max_y:, min_z:, max_z: }
    def street_bounds(grid_index:, city_size:)
      min_x = 0
      max_x = city_size * GRID_CELL_SIZE
      min_y = grid_index * GRID_CELL_SIZE
      max_y = min_y + STREET_WIDTH

      {
        min_x: min_x,
        max_x: max_x,
        min_y: min_y,
        max_y: max_y,
        min_z: 0,
        max_z: 10  # Street level height
      }
    end

    # Calculate room bounds for an avenue (N-S running)
    # Avenues span the full height of the city at a specific X position
    # @param grid_index [Integer] the grid position (0-based)
    # @param city_size [Integer] number of streets (determines height)
    # @return [Hash] { min_x:, max_x:, min_y:, max_y:, min_z:, max_z: }
    def avenue_bounds(grid_index:, city_size:)
      min_x = grid_index * GRID_CELL_SIZE
      max_x = min_x + STREET_WIDTH
      min_y = 0
      max_y = city_size * GRID_CELL_SIZE

      {
        min_x: min_x,
        max_x: max_x,
        min_y: min_y,
        max_y: max_y,
        min_z: 0,
        max_z: 10  # Street level height
      }
    end

    # Calculate room bounds for an intersection
    # Intersections are 25x25 squares at grid crossing points
    # @param grid_x [Integer] the X grid position (avenue index)
    # @param grid_y [Integer] the Y grid position (street index)
    # @return [Hash] { min_x:, max_x:, min_y:, max_y:, min_z:, max_z: }
    def intersection_bounds(grid_x:, grid_y:)
      min_x = grid_x * GRID_CELL_SIZE
      max_x = min_x + STREET_WIDTH
      min_y = grid_y * GRID_CELL_SIZE
      max_y = min_y + STREET_WIDTH

      {
        min_x: min_x,
        max_x: max_x,
        min_y: min_y,
        max_y: max_y,
        min_z: 0,
        max_z: 10
      }
    end

    # Calculate the available building space at a block
    # A block is the space between four intersections
    # @param intersection_x [Integer] the base intersection X (lower-left corner)
    # @param intersection_y [Integer] the base intersection Y (lower-left corner)
    # @return [Hash] { min_x:, max_x:, min_y:, max_y: } of buildable area
    def block_bounds(intersection_x:, intersection_y:)
      # Block starts after the intersection (street width offset)
      # and extends to the next intersection
      min_x = (intersection_x * GRID_CELL_SIZE) + STREET_WIDTH
      max_x = ((intersection_x + 1) * GRID_CELL_SIZE)
      min_y = (intersection_y * GRID_CELL_SIZE) + STREET_WIDTH
      max_y = ((intersection_y + 1) * GRID_CELL_SIZE)

      {
        min_x: min_x,
        max_x: max_x,
        min_y: min_y,
        max_y: max_y,
        width: max_x - min_x,
        height: max_y - min_y
      }
    end

    # Calculate building footprint within a block
    # @param block_bounds [Hash] from block_bounds
    # @param building_type [Symbol] :brownstone, :house, :apartment_tower, :mall, :park
    # @param position [Symbol] :north, :south, :east, :west, :full, :corner_ne, etc.
    # @param max_height [Integer] maximum building height in feet
    # @return [Hash] { min_x:, max_x:, min_y:, max_y:, min_z:, max_z: }
    def building_footprint(block_bounds:, building_type:, position: :full, max_height: 200)
      config = building_config(building_type)

      case position
      when :full
        # Building takes the whole block
        {
          min_x: block_bounds[:min_x],
          max_x: block_bounds[:max_x],
          min_y: block_bounds[:min_y],
          max_y: block_bounds[:max_y],
          min_z: 0,
          max_z: [config[:height], max_height].min
        }
      when :north
        mid_y = (block_bounds[:min_y] + block_bounds[:max_y]) / 2
        {
          min_x: block_bounds[:min_x],
          max_x: block_bounds[:max_x],
          min_y: mid_y,
          max_y: block_bounds[:max_y],
          min_z: 0,
          max_z: [config[:height], max_height].min
        }
      when :south
        mid_y = (block_bounds[:min_y] + block_bounds[:max_y]) / 2
        {
          min_x: block_bounds[:min_x],
          max_x: block_bounds[:max_x],
          min_y: block_bounds[:min_y],
          max_y: mid_y,
          min_z: 0,
          max_z: [config[:height], max_height].min
        }
      when :east
        mid_x = (block_bounds[:min_x] + block_bounds[:max_x]) / 2
        {
          min_x: mid_x,
          max_x: block_bounds[:max_x],
          min_y: block_bounds[:min_y],
          max_y: block_bounds[:max_y],
          min_z: 0,
          max_z: [config[:height], max_height].min
        }
      when :west
        mid_x = (block_bounds[:min_x] + block_bounds[:max_x]) / 2
        {
          min_x: block_bounds[:min_x],
          max_x: mid_x,
          min_y: block_bounds[:min_y],
          max_y: block_bounds[:max_y],
          min_z: 0,
          max_z: [config[:height], max_height].min
        }
      else
        # Default to full block
        building_footprint(block_bounds: block_bounds, building_type: building_type, position: :full, max_height: max_height)
      end
    end

    # Calculate floor bounds within a building
    # @param building_bounds [Hash] building footprint
    # @param floor_number [Integer] 0-based floor number (0 = ground)
    # @param floor_height [Integer] height of each floor in feet (default: 10)
    # @return [Hash] { min_x:, max_x:, min_y:, max_y:, min_z:, max_z: }
    def floor_bounds(building_bounds:, floor_number:, floor_height: 10)
      {
        min_x: building_bounds[:min_x],
        max_x: building_bounds[:max_x],
        min_y: building_bounds[:min_y],
        max_y: building_bounds[:max_y],
        min_z: floor_number * floor_height,
        max_z: (floor_number + 1) * floor_height
      }
    end

    # Calculate unit bounds within a floor (for apartments, offices)
    # Divides a floor into a grid of units
    # @param floor_bounds [Hash] the floor bounds
    # @param units_x [Integer] number of units along X axis
    # @param units_y [Integer] number of units along Y axis
    # @param unit_index [Integer] which unit (0-based, row-major order)
    # @return [Hash] { min_x:, max_x:, min_y:, max_y:, min_z:, max_z: }
    def unit_bounds(floor_bounds:, units_x:, units_y:, unit_index:)
      unit_width = (floor_bounds[:max_x] - floor_bounds[:min_x]) / units_x
      unit_height = (floor_bounds[:max_y] - floor_bounds[:min_y]) / units_y

      unit_x = unit_index % units_x
      unit_y = unit_index / units_x

      {
        min_x: floor_bounds[:min_x] + (unit_x * unit_width),
        max_x: floor_bounds[:min_x] + ((unit_x + 1) * unit_width),
        min_y: floor_bounds[:min_y] + (unit_y * unit_height),
        max_y: floor_bounds[:min_y] + ((unit_y + 1) * unit_height),
        min_z: floor_bounds[:min_z],
        max_z: floor_bounds[:max_z]
      }
    end

    # Get the address for a building based on its position
    # @param street_name [String] the street the building faces
    # @param grid_x [Integer] X position in grid
    # @param grid_y [Integer] Y position in grid
    # @param unit_number [Integer, nil] optional unit/apartment number
    # @return [String] formatted address
    def format_address(street_name:, grid_x:, grid_y:, unit_number: nil)
      # Generate a building number based on position
      # Convention: street number = grid_y * 100 + grid_x * 10 + offset
      building_number = (grid_y * 100) + (grid_x * 10) + 1

      if unit_number
        "#{building_number} #{street_name}, ##{unit_number}"
      else
        "#{building_number} #{street_name}"
      end
    end

    # Calculate which grid cell contains a point
    # @param x [Float] X coordinate
    # @param y [Float] Y coordinate
    # @return [Hash] { grid_x:, grid_y:, on_street:, on_avenue:, at_intersection: }
    def point_to_grid(x:, y:)
      grid_x = (x / GRID_CELL_SIZE).floor
      grid_y = (y / GRID_CELL_SIZE).floor

      # Check if on a street/avenue (within street width of grid line)
      x_offset = x % GRID_CELL_SIZE
      y_offset = y % GRID_CELL_SIZE

      on_avenue = x_offset < STREET_WIDTH
      on_street = y_offset < STREET_WIDTH
      at_intersection = on_avenue && on_street

      {
        grid_x: grid_x,
        grid_y: grid_y,
        on_street: on_street,
        on_avenue: on_avenue,
        at_intersection: at_intersection
      }
    end

    # Get building configuration for a type
    # @param building_type [Symbol]
    # @return [Hash] { width:, depth:, height:, per_block:, floors: }
    def building_config(building_type)
      BUILDING_TYPES[building_type.to_sym] || BUILDING_TYPES[:house]
    end

    # Building type configurations
    BUILDING_TYPES = {
      # Residential - Towers
      apartment_tower: { width: 70, depth: 70, height: 200, per_block: 4, floors: 20, units_per_floor: 4, category: :residential },
      condo_tower: { width: 70, depth: 70, height: 180, per_block: 4, floors: 18, units_per_floor: 2, category: :residential },

      # Residential - Low-rise
      brownstone: { width: 30, depth: 30, height: 30, per_block: 16, floors: 3, category: :residential },
      house: { width: 50, depth: 50, height: 30, per_block: 8, floors: 2, category: :residential },
      terrace: { width: 25, depth: 40, height: 25, per_block: 24, floors: 2, category: :residential },
      townhouse: { width: 30, depth: 50, height: 35, per_block: 12, floors: 3, category: :residential },
      cottage: { width: 40, depth: 40, height: 20, per_block: 8, floors: 1, category: :residential },

      # Commercial - Towers
      office_tower: { width: 70, depth: 70, height: 150, per_block: 4, floors: 15, units_per_floor: 6, category: :commercial },
      hotel: { width: 60, depth: 60, height: 120, per_block: 4, floors: 12, units_per_floor: 10, category: :commercial },

      # Commercial - Low-rise
      mall: { width: 70, depth: 150, height: 50, per_block: 2, floors: 3, category: :commercial },
      shop: { width: 30, depth: 30, height: 20, per_block: 0, floors: 2, category: :commercial },
      restaurant: { width: 40, depth: 40, height: 20, per_block: 8, floors: 2, category: :commercial },
      bar: { width: 35, depth: 35, height: 20, per_block: 10, floors: 2, category: :commercial },
      cafe: { width: 30, depth: 30, height: 10, per_block: 12, floors: 1, category: :commercial },
      gym: { width: 60, depth: 60, height: 30, per_block: 4, floors: 2, category: :commercial },
      cinema: { width: 80, depth: 100, height: 40, per_block: 2, floors: 2, category: :commercial },
      warehouse: { width: 100, depth: 100, height: 40, per_block: 2, floors: 1, category: :commercial },

      # Civic/Public
      church: { width: 60, depth: 80, height: 50, per_block: 2, floors: 1, category: :civic },
      temple: { width: 60, depth: 80, height: 45, per_block: 2, floors: 1, category: :civic },
      school: { width: 100, depth: 80, height: 35, per_block: 2, floors: 3, category: :civic },
      hospital: { width: 120, depth: 100, height: 60, per_block: 1, floors: 6, category: :civic },
      clinic: { width: 50, depth: 50, height: 25, per_block: 4, floors: 2, category: :civic },
      library: { width: 60, depth: 60, height: 35, per_block: 3, floors: 3, category: :civic },
      police_station: { width: 50, depth: 60, height: 30, per_block: 3, floors: 2, category: :civic },
      fire_station: { width: 60, depth: 60, height: 35, per_block: 3, floors: 2, category: :civic },
      government: { width: 80, depth: 80, height: 50, per_block: 2, floors: 4, category: :civic },

      # Recreation/Open
      park: { width: 150, depth: 150, height: 10, per_block: 1, floors: 1, category: :recreation },
      playground: { width: 60, depth: 60, height: 10, per_block: 4, floors: 1, category: :recreation },
      garden: { width: 80, depth: 80, height: 10, per_block: 2, floors: 1, category: :recreation },
      plaza: { width: 100, depth: 100, height: 5, per_block: 2, floors: 1, category: :recreation },
      courtyard: { width: 50, depth: 50, height: 5, per_block: 4, floors: 1, category: :recreation },
      sports_field: { width: 150, depth: 100, height: 10, per_block: 1, floors: 1, category: :recreation },

      # Infrastructure
      parking_garage: { width: 80, depth: 80, height: 60, per_block: 2, floors: 6, category: :infrastructure },
      gas_station: { width: 60, depth: 50, height: 15, per_block: 4, floors: 1, category: :infrastructure },
      subway_entrance: { width: 20, depth: 20, height: 10, per_block: 12, floors: 1, category: :infrastructure }
    }.freeze

    # Block layout configurations - how to divide a block
    BLOCK_LAYOUTS = {
      # Single structure layouts
      full: {
        description: 'Single structure fills entire block',
        sections: [{ position: :full, ratio: 1.0 }]
      },

      # Split in two layouts
      split_ns: {
        description: 'Block split north/south into two halves',
        sections: [
          { position: :north, ratio: 0.5 },
          { position: :south, ratio: 0.5 }
        ]
      },
      split_ew: {
        description: 'Block split east/west into two halves',
        sections: [
          { position: :east, ratio: 0.5 },
          { position: :west, ratio: 0.5 }
        ]
      },

      # Quadrant layouts
      quadrants: {
        description: 'Block split into four quadrants',
        sections: [
          { position: :ne, ratio: 0.25 },
          { position: :nw, ratio: 0.25 },
          { position: :se, ratio: 0.25 },
          { position: :sw, ratio: 0.25 }
        ]
      },

      # Terrace/row house layouts
      terrace_north: {
        description: 'Row of terraces along north edge',
        sections: (0..5).map { |i| { position: :terrace_n, index: i, ratio: 1.0 / 6 } }
      },
      terrace_south: {
        description: 'Row of terraces along south edge',
        sections: (0..5).map { |i| { position: :terrace_s, index: i, ratio: 1.0 / 6 } }
      },
      terrace_east: {
        description: 'Row of terraces along east edge',
        sections: (0..5).map { |i| { position: :terrace_e, index: i, ratio: 1.0 / 6 } }
      },
      terrace_west: {
        description: 'Row of terraces along west edge',
        sections: (0..5).map { |i| { position: :terrace_w, index: i, ratio: 1.0 / 6 } }
      },

      # Perimeter layout (buildings around edges, open center)
      perimeter: {
        description: 'Buildings around perimeter with central courtyard',
        sections: [
          { position: :perimeter_n, ratio: 0.2 },
          { position: :perimeter_s, ratio: 0.2 },
          { position: :perimeter_e, ratio: 0.2 },
          { position: :perimeter_w, ratio: 0.2 },
          { position: :center, ratio: 0.2 }
        ]
      },

      # L-shaped layouts
      l_shaped_ne: {
        description: 'L-shaped building in NE corner',
        sections: [
          { position: :l_ne, ratio: 0.5 },
          { position: :open_sw, ratio: 0.5 }
        ]
      },
      l_shaped_nw: {
        description: 'L-shaped building in NW corner',
        sections: [
          { position: :l_nw, ratio: 0.5 },
          { position: :open_se, ratio: 0.5 }
        ]
      },

      # Mixed use - large building with small shops
      mixed_tower_shops: {
        description: 'Tower with surrounding small shops',
        sections: [
          { position: :center_large, ratio: 0.6 },
          { position: :corner_ne, ratio: 0.1 },
          { position: :corner_nw, ratio: 0.1 },
          { position: :corner_se, ratio: 0.1 },
          { position: :corner_sw, ratio: 0.1 }
        ]
      }
    }.freeze

    # Get a block layout configuration
    # @param layout_name [Symbol] name of the layout
    # @return [Hash] layout configuration
    def block_layout(layout_name)
      BLOCK_LAYOUTS[layout_name.to_sym] || BLOCK_LAYOUTS[:full]
    end

    # Calculate section bounds within a block based on position
    # @param block_bounds [Hash] the block bounds
    # @param position [Symbol] position within block
    # @param index [Integer] for row positions, which slot (0-based)
    # @param max_height [Integer] maximum height
    # @return [Hash] bounds for the section
    def section_bounds(block_bounds:, position:, index: 0, max_height: 200)
      width = block_bounds[:width]
      height = block_bounds[:height]
      min_x = block_bounds[:min_x]
      min_y = block_bounds[:min_y]
      max_x = block_bounds[:max_x]
      max_y = block_bounds[:max_y]
      mid_x = (min_x + max_x) / 2
      mid_y = (min_y + max_y) / 2

      bounds = case position
               # Full block
               when :full
                 { min_x: min_x, max_x: max_x, min_y: min_y, max_y: max_y }

               # Half blocks
               when :north
                 { min_x: min_x, max_x: max_x, min_y: mid_y, max_y: max_y }
               when :south
                 { min_x: min_x, max_x: max_x, min_y: min_y, max_y: mid_y }
               when :east
                 { min_x: mid_x, max_x: max_x, min_y: min_y, max_y: max_y }
               when :west
                 { min_x: min_x, max_x: mid_x, min_y: min_y, max_y: max_y }

               # Quadrants
               when :ne
                 { min_x: mid_x, max_x: max_x, min_y: mid_y, max_y: max_y }
               when :nw
                 { min_x: min_x, max_x: mid_x, min_y: mid_y, max_y: max_y }
               when :se
                 { min_x: mid_x, max_x: max_x, min_y: min_y, max_y: mid_y }
               when :sw
                 { min_x: min_x, max_x: mid_x, min_y: min_y, max_y: mid_y }

               # Terrace rows (6 units per side)
               when :terrace_n
                 unit_width = width / 6
                 { min_x: min_x + (index * unit_width), max_x: min_x + ((index + 1) * unit_width),
                   min_y: max_y - 40, max_y: max_y }
               when :terrace_s
                 unit_width = width / 6
                 { min_x: min_x + (index * unit_width), max_x: min_x + ((index + 1) * unit_width),
                   min_y: min_y, max_y: min_y + 40 }
               when :terrace_e
                 unit_height = height / 6
                 { min_x: max_x - 40, max_x: max_x,
                   min_y: min_y + (index * unit_height), max_y: min_y + ((index + 1) * unit_height) }
               when :terrace_w
                 unit_height = height / 6
                 { min_x: min_x, max_x: min_x + 40,
                   min_y: min_y + (index * unit_height), max_y: min_y + ((index + 1) * unit_height) }

               # Perimeter sections
               when :perimeter_n
                 { min_x: min_x, max_x: max_x, min_y: max_y - 30, max_y: max_y }
               when :perimeter_s
                 { min_x: min_x, max_x: max_x, min_y: min_y, max_y: min_y + 30 }
               when :perimeter_e
                 { min_x: max_x - 30, max_x: max_x, min_y: min_y + 30, max_y: max_y - 30 }
               when :perimeter_w
                 { min_x: min_x, max_x: min_x + 30, min_y: min_y + 30, max_y: max_y - 30 }
               when :center
                 { min_x: min_x + 30, max_x: max_x - 30, min_y: min_y + 30, max_y: max_y - 30 }

               # Corner positions (for mixed use)
               when :center_large
                 margin = width * 0.15
                 { min_x: min_x + margin, max_x: max_x - margin, min_y: min_y + margin, max_y: max_y - margin }
               when :corner_ne
                 size = width * 0.15
                 { min_x: max_x - size, max_x: max_x, min_y: max_y - size, max_y: max_y }
               when :corner_nw
                 size = width * 0.15
                 { min_x: min_x, max_x: min_x + size, min_y: max_y - size, max_y: max_y }
               when :corner_se
                 size = width * 0.15
                 { min_x: max_x - size, max_x: max_x, min_y: min_y, max_y: min_y + size }
               when :corner_sw
                 size = width * 0.15
                 { min_x: min_x, max_x: min_x + size, min_y: min_y, max_y: min_y + size }

               # L-shaped and open sections
               when :l_ne
                 # L covering north and east edges
                 nil # Handled specially
               when :open_sw
                 # Open area in SW for L-shaped
                 { min_x: min_x, max_x: mid_x, min_y: min_y, max_y: mid_y }

               else
                 { min_x: min_x, max_x: max_x, min_y: min_y, max_y: max_y }
               end

      return nil unless bounds

      bounds.merge(min_z: 0, max_z: max_height)
    end

    # Get all available block layouts
    # @return [Array<Hash>] layout info
    def available_layouts
      BLOCK_LAYOUTS.map do |name, config|
        { name: name, description: config[:description], sections: config[:sections].length }
      end
    end

    # Get building types by category
    # @param category [Symbol] :residential, :commercial, :civic, :recreation, :infrastructure
    # @return [Array<Symbol>] building type names
    def building_types_by_category(category)
      BUILDING_TYPES.select { |_, config| config[:category] == category }.keys
    end

    # Get all building types configuration
    # @return [Hash] building type configurations
    def all_building_types
      BUILDING_TYPES
    end
  end
end
