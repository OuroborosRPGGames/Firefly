# frozen_string_literal: true

# BlockLotService subdivides city blocks into lots separated by alleys.
#
# A city block is 150x150 feet of buildable area. This service calculates
# how to divide blocks into lots based on building demand, inserting 10-foot
# alleys between lots.
#
# Block types:
#   :full        - 1 lot  150x150 (no alleys)
#   :half_ns     - 2 lots 150x70  (E-W alley splits north/south)
#   :half_ew     - 2 lots 70x150  (N-S alley splits east/west)
#   :quarters    - 4 lots 70x70   (cross alleys)
#   :tee_north   - 1 lot 150x70 (north) + 2 lots 70x70 (sw, se)
#   :tee_south   - 2 lots 70x70 (nw, ne) + 1 lot 150x70 (south)
#   :tee_east    - 2 lots 70x70 (nw, sw) + 1 lot 70x150 (east)
#   :tee_west    - 1 lot 70x150 (west) + 2 lots 70x70 (ne, se)
#
# @example Calculate lot positions
#   bounds = { min_x: 25, max_x: 175, min_y: 25, max_y: 175, width: 150, height: 150 }
#   lots = BlockLotService.lot_bounds(block_bounds: bounds, block_type: :quarters)
#   # => { nw: { min_x: 25, max_x: 95, min_y: 105, max_y: 175, ... }, ... }
#
# @example Plan block allocation for buildings
#   plan = BlockLotService.plan_blocks(
#     buildings: [:shop, :shop, :warehouse, :park],
#     available_blocks: 10,
#     city_size: :town
#   )
#
class BlockLotService
  ALLEY_WIDTH = 10

  BLOCK_TYPES = %i[full half_ns half_ew quarters tee_north tee_south tee_east tee_west].freeze

  # Building size classifications
  SMALL_BUILDINGS = %i[
    shop house brownstone apartment_tower cafe bar restaurant church temple
    clinic cottage townhouse fire_station police_station library gym cinema
    gas_station subway_entrance terrace condo_tower
  ].freeze

  LARGE_BUILDINGS = %i[
    warehouse parking_garage school hospital mall hotel office_tower park
    playground garden
  ].freeze

  FULL_BLOCK_BUILDINGS = %i[
    palace castle cathedral sports_field plaza courtyard government large_park
  ].freeze

  # Green space ratio by city size
  GREEN_SPACE_RATIOS = {
    village: 0.7,
    town: 0.6,
    small_city: 0.5,
    medium: 0.4,
    large_city: 0.3,
    metropolis: 0.5
  }.freeze

  # Green space types by city size
  GREEN_SPACE_TYPES = {
    village: %i[garden park playground],
    town: %i[garden park plaza playground],
    small_city: %i[park plaza playground],
    medium: %i[park plaza playground],
    large_city: %i[park plaza],
    metropolis: %i[park plaza]
  }.freeze

  class << self
    # Calculate lot bounds for each lot within a block.
    #
    # @param block_bounds [Hash] { min_x:, max_x:, min_y:, max_y:, width:, height: }
    # @param block_type [Symbol] one of BLOCK_TYPES
    # @param max_height [Integer] maximum building height in feet (default: 200)
    # @return [Hash<Symbol, Hash>] lot_name => { min_x:, max_x:, min_y:, max_y:, min_z:, max_z:, width:, height: }
    def lot_bounds(block_bounds:, block_type:, max_height: 200)
      min_x = block_bounds[:min_x]
      max_x = block_bounds[:max_x]
      min_y = block_bounds[:min_y]
      max_y = block_bounds[:max_y]

      mid_x = min_x + ((max_x - min_x - ALLEY_WIDTH) / 2)
      mid_y = min_y + ((max_y - min_y - ALLEY_WIDTH) / 2)

      case block_type
      when :full
        {
          full: make_lot(min_x, max_x, min_y, max_y, max_height)
        }

      when :half_ns
        # E-W alley at mid_y, splitting into north and south lots
        {
          north: make_lot(min_x, max_x, mid_y + ALLEY_WIDTH, max_y, max_height),
          south: make_lot(min_x, max_x, min_y, mid_y, max_height)
        }

      when :half_ew
        # N-S alley at mid_x, splitting into east and west lots
        {
          east: make_lot(mid_x + ALLEY_WIDTH, max_x, min_y, max_y, max_height),
          west: make_lot(min_x, mid_x, min_y, max_y, max_height)
        }

      when :quarters
        # Cross alleys, 4 quadrant lots
        {
          nw: make_lot(min_x, mid_x, mid_y + ALLEY_WIDTH, max_y, max_height),
          ne: make_lot(mid_x + ALLEY_WIDTH, max_x, mid_y + ALLEY_WIDTH, max_y, max_height),
          sw: make_lot(min_x, mid_x, min_y, mid_y, max_height),
          se: make_lot(mid_x + ALLEY_WIDTH, max_x, min_y, mid_y, max_height)
        }

      when :tee_north
        # E-W alley + partial N-S alley on south half
        # North: full-width lot, South: two quarter lots
        {
          north: make_lot(min_x, max_x, mid_y + ALLEY_WIDTH, max_y, max_height),
          sw: make_lot(min_x, mid_x, min_y, mid_y, max_height),
          se: make_lot(mid_x + ALLEY_WIDTH, max_x, min_y, mid_y, max_height)
        }

      when :tee_south
        # E-W alley + partial N-S alley on north half
        # North: two quarter lots, South: full-width lot
        {
          nw: make_lot(min_x, mid_x, mid_y + ALLEY_WIDTH, max_y, max_height),
          ne: make_lot(mid_x + ALLEY_WIDTH, max_x, mid_y + ALLEY_WIDTH, max_y, max_height),
          south: make_lot(min_x, max_x, min_y, mid_y, max_height)
        }

      when :tee_east
        # N-S alley + partial E-W alley on west half
        # West: two quarter lots, East: full-height lot
        {
          nw: make_lot(min_x, mid_x, mid_y + ALLEY_WIDTH, max_y, max_height),
          sw: make_lot(min_x, mid_x, min_y, mid_y, max_height),
          east: make_lot(mid_x + ALLEY_WIDTH, max_x, min_y, max_y, max_height)
        }

      when :tee_west
        # N-S alley + partial E-W alley on east half
        # West: full-height lot, East: two quarter lots
        {
          west: make_lot(min_x, mid_x, min_y, max_y, max_height),
          ne: make_lot(mid_x + ALLEY_WIDTH, max_x, mid_y + ALLEY_WIDTH, max_y, max_height),
          se: make_lot(mid_x + ALLEY_WIDTH, max_x, min_y, mid_y, max_height)
        }

      else
        warn "[BlockLotService] Unknown block type: #{block_type}, falling back to :full"
        { full: make_lot(min_x, max_x, min_y, max_y, max_height) }
      end
    end

    # Calculate alley bounds for a block type.
    #
    # @param block_bounds [Hash] { min_x:, max_x:, min_y:, max_y:, width:, height: }
    # @param block_type [Symbol] one of BLOCK_TYPES
    # @return [Array<Hash>] list of alley bounds { min_x:, max_x:, min_y:, max_y:, orientation: }
    def alley_bounds(block_bounds:, block_type:)
      min_x = block_bounds[:min_x]
      max_x = block_bounds[:max_x]
      min_y = block_bounds[:min_y]
      max_y = block_bounds[:max_y]

      mid_x = min_x + ((max_x - min_x - ALLEY_WIDTH) / 2)
      mid_y = min_y + ((max_y - min_y - ALLEY_WIDTH) / 2)

      case block_type
      when :full
        [] # No alleys

      when :half_ns
        # One E-W alley spanning full width
        [{ min_x: min_x, max_x: max_x, min_y: mid_y, max_y: mid_y + ALLEY_WIDTH, orientation: :ew }]

      when :half_ew
        # One N-S alley spanning full height
        [{ min_x: mid_x, max_x: mid_x + ALLEY_WIDTH, min_y: min_y, max_y: max_y, orientation: :ns }]

      when :quarters
        # Cross: one E-W + one N-S
        [
          { min_x: min_x, max_x: max_x, min_y: mid_y, max_y: mid_y + ALLEY_WIDTH, orientation: :ew },
          { min_x: mid_x, max_x: mid_x + ALLEY_WIDTH, min_y: min_y, max_y: max_y, orientation: :ns }
        ]

      when :tee_north
        # E-W alley full width + partial N-S on south half only
        [
          { min_x: min_x, max_x: max_x, min_y: mid_y, max_y: mid_y + ALLEY_WIDTH, orientation: :ew },
          { min_x: mid_x, max_x: mid_x + ALLEY_WIDTH, min_y: min_y, max_y: mid_y, orientation: :ns }
        ]

      when :tee_south
        # E-W alley full width + partial N-S on north half only
        [
          { min_x: min_x, max_x: max_x, min_y: mid_y, max_y: mid_y + ALLEY_WIDTH, orientation: :ew },
          { min_x: mid_x, max_x: mid_x + ALLEY_WIDTH, min_y: mid_y + ALLEY_WIDTH, max_y: max_y, orientation: :ns }
        ]

      when :tee_east
        # N-S alley full height + partial E-W on west half only
        [
          { min_x: mid_x, max_x: mid_x + ALLEY_WIDTH, min_y: min_y, max_y: max_y, orientation: :ns },
          { min_x: min_x, max_x: mid_x, min_y: mid_y, max_y: mid_y + ALLEY_WIDTH, orientation: :ew }
        ]

      when :tee_west
        # N-S alley full height + partial E-W on east half only
        [
          { min_x: mid_x, max_x: mid_x + ALLEY_WIDTH, min_y: min_y, max_y: max_y, orientation: :ns },
          { min_x: mid_x + ALLEY_WIDTH, max_x: max_x, min_y: mid_y, max_y: mid_y + ALLEY_WIDTH, orientation: :ew }
        ]

      else
        []
      end
    end

    # Classify a building type by its lot size requirement.
    #
    # @param building_type [Symbol, String] the building type
    # @return [Symbol] :small, :large, or :full_block
    def lot_size_for_building(building_type)
      bt = building_type.to_sym

      return :full_block if FULL_BLOCK_BUILDINGS.include?(bt)
      return :large if LARGE_BUILDINGS.include?(bt)
      return :small if SMALL_BUILDINGS.include?(bt)

      # Default: unknown types treated as small
      warn "[BlockLotService] Unknown building type '#{building_type}', defaulting to :small"
      :small
    end

    # Plan block allocations for a set of buildings using demand-driven logic.
    #
    # @param buildings [Array<Symbol, String>] list of building types to place
    # @param available_blocks [Integer] total number of blocks available
    # @param city_size [Symbol] :village, :town, :small_city, :medium, :large_city, :metropolis
    # @return [Array<Hash>] block assignments [{ block_type:, buildings: [...] }, ...]
    def plan_blocks(buildings:, available_blocks:, city_size:, green_space_ratio: nil, rng: Random)
      buildings = buildings.map(&:to_sym)
      assignments = []
      remaining_blocks = available_blocks

      # Classify buildings by size (single pass)
      grouped = buildings.group_by { |b| lot_size_for_building(b) }
      full_block = grouped[:full_block] || []
      large = grouped[:large] || []
      small = grouped[:small] || []

      # Step 1: Full-block buildings each get one :full block
      full_block.each do |building|
        break if remaining_blocks <= 0

        assignments << { block_type: :full, buildings: [building] }
        remaining_blocks -= 1
      end

      # Step 2: Pair large buildings into :half_ns or :half_ew blocks
      large_pairs = large.each_slice(2).to_a
      large_pairs.each do |pair|
        break if remaining_blocks <= 0

        if pair.size == 2
          # Two large buildings share a halved block
          orientation = [:half_ns, :half_ew].sample(random: rng)
          assignments << { block_type: orientation, buildings: pair }
          remaining_blocks -= 1
        else
          # Step 3: Odd large building + up to 2 smalls → tee block
          tee_buildings = [pair.first]
          2.times { tee_buildings << small.shift if !small.empty? }
          tee_type = [:tee_north, :tee_south, :tee_east, :tee_west].sample(random: rng)
          assignments << { block_type: tee_type, buildings: tee_buildings }
          remaining_blocks -= 1
        end
      end

      # Step 4: Remaining smalls → :quarters blocks (4 per block)
      small.each_slice(4) do |group|
        break if remaining_blocks <= 0

        assignments << { block_type: :quarters, buildings: group }
        remaining_blocks -= 1
      end

      # Step 5: Empty blocks → green space or vacant based on city_size ratio
      if remaining_blocks > 0
        green_ratio = green_space_ratio || GREEN_SPACE_RATIOS[city_size] || 0.5
        green_types = GREEN_SPACE_TYPES[city_size] || %i[park plaza playground]

        remaining_blocks.times do
          if rng.rand < green_ratio
            green_type = green_types.sample(random: rng)
            assignments << { block_type: :full, buildings: [green_type] }
          else
            assignments << { block_type: :full, buildings: [:vacant] }
          end
        end
      end

      assignments
    end

    # Create Room records for alleys within a block.
    #
    # @param location [Location] the city location
    # @param block_bounds [Hash] { min_x:, max_x:, min_y:, max_y:, width:, height: }
    # @param block_type [Symbol] one of BLOCK_TYPES
    # @param grid_x [Integer] block grid X position
    # @param grid_y [Integer] block grid Y position
    # @return [Array<Room>] created alley rooms
    def create_alleys(location:, block_bounds:, block_type:, grid_x:, grid_y:)
      alleys_data = alley_bounds(block_bounds: block_bounds, block_type: block_type)
      rooms = []

      alleys_data.each_with_index do |alley, index|
        orientation_label = alley[:orientation] == :ns ? 'north-south' : 'east-west'
        name = "Alley #{grid_x},#{grid_y}"
        name += " ##{index + 1}" if alleys_data.size > 1

        room = Room.create(
          location_id: location.id,
          name: name,
          room_type: 'alley',
          short_description: "A narrow #{orientation_label} alley.",
          long_description: "A narrow #{orientation_label} alley running between buildings.",
          min_x: alley[:min_x],
          max_x: alley[:max_x],
          min_y: alley[:min_y],
          max_y: alley[:max_y],
          min_z: 0,
          max_z: 10,
          grid_x: grid_x,
          grid_y: grid_y,
          city_role: 'alley'
        )
        rooms << room
      rescue StandardError => e
        warn "[BlockLotService] Failed to create alley at #{grid_x},#{grid_y}: #{e.message}"
      end

      rooms
    end

    private

    # Build a lot bounds hash from coordinates.
    #
    # @param min_x [Numeric]
    # @param max_x [Numeric]
    # @param min_y [Numeric]
    # @param max_y [Numeric]
    # @param max_height [Integer]
    # @return [Hash]
    def make_lot(min_x, max_x, min_y, max_y, max_height)
      {
        min_x: min_x,
        max_x: max_x,
        min_y: min_y,
        max_y: max_y,
        min_z: 0,
        max_z: max_height,
        width: max_x - min_x,
        height: max_y - min_y
      }
    end
  end
end
