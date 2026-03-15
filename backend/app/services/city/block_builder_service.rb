# frozen_string_literal: true

require_relative '../../../lib/core_extensions'
require_relative 'block_lot_service'

# BlockBuilderService handles the creation of buildings within city blocks.
#
# Creates buildings of various types (apartments, brownstones, houses, shops, etc.)
# at specific city grid positions, with proper room hierarchy and coordinates.
#
# @example Build an apartment tower at an intersection
#   BlockBuilderService.build_block(
#     location: city_location,
#     intersection_room: intersection,
#     building_type: :apartment_tower
#   )
#
# @example Create a shop within a building
#   BlockBuilderService.create_building(
#     location: city_location,
#     parent_room: street_room,
#     building_type: :shop,
#     bounds: GridCalculationService.building_footprint(...),
#     address: '123 Main Street'
#   )
#
class BlockBuilderService
  class << self
    # Build structures at a city block (the area between four intersections)
    # @param location [Location] the city location
    # @param intersection_room [Room] the intersection room marking the block's corner
    # @param building_type [Symbol] type of building to create
    # @param options [Hash] additional options (position, name, etc.)
    # @return [Array<Room>] created building rooms
    def build_block(location:, intersection_room:, building_type:, options: {})
      DB.transaction do
        grid_x = intersection_room.grid_x
        grid_y = intersection_room.grid_y

        # Calculate block bounds
        block_bounds = GridCalculationService.block_bounds(
          intersection_x: grid_x,
          intersection_y: grid_y
        )

        # Handle vacant lots - just an empty outdoor space
        if %i[vacant_lot vacant].include?(building_type.to_sym)
          room = Room.create(
            location_id: location.id,
            name: 'Vacant Lot',
            room_type: 'outdoor',
            city_role: 'vacant_lot',
            long_description: 'An empty lot overgrown with weeds. Scattered debris and a few wooden stakes mark where a building might one day stand.',
            min_x: block_bounds[:min_x],
            max_x: block_bounds[:max_x],
            min_y: block_bounds[:min_y],
            max_y: block_bounds[:max_y],
            min_z: 0,
            max_z: 10,
            grid_x: grid_x,
            grid_y: grid_y
          )
          return [room]
        end

        # Determine street name from adjacent street
        street_name = find_adjacent_street_name(location, grid_x, grid_y)

        # Generate address
        address = GridCalculationService.format_address(
          street_name: street_name,
          grid_x: grid_x,
          grid_y: grid_y
        )

        # Get building configuration
        config = GridCalculationService.building_config(building_type)
        max_height = options[:max_height] || location.max_building_height || 200

        # Determine building bounds using lot-aware placement
        building_bounds = resolve_building_bounds(
          location: location,
          block_bounds: block_bounds,
          building_type: building_type,
          grid_x: grid_x,
          grid_y: grid_y,
          max_height: max_height,
          lot_bounds: options[:lot_bounds],
          position: options[:position] || :full
        )

        # Create the main building room
        building = create_building(
          location: location,
          parent_room: intersection_room,
          building_type: building_type,
          bounds: building_bounds,
          address: address,
          name: options[:name],
          grid_x: grid_x,
          grid_y: grid_y
        )

        # Add a street-facing door to the building
        create_building_door(building)

        # Populate building with interior rooms if applicable
        interior_rooms = populate_building(
          building: building,
          building_type: building_type,
          config: config,
          bounds: building_bounds,
          location: location
        )

        [building] + interior_rooms
      end
    end


    # Create a single building room
    # @param location [Location] the city location
    # @param parent_room [Room] the parent room (street or intersection)
    # @param building_type [Symbol] type of building
    # @param bounds [Hash] coordinate bounds { min_x:, max_x:, min_y:, max_y:, min_z:, max_z: }
    # @param address [String] the building address
    # @param name [String, nil] optional custom name
    # @param grid_x [Integer] grid X position
    # @param grid_y [Integer] grid Y position
    # @return [Room] the created building room
    def create_building(location:, parent_room:, building_type:, bounds:, address:, name: nil, grid_x: nil, grid_y: nil)
      building_name = name || generate_building_name(building_type, address)

      Room.create(
        location_id: location.id,
        name: building_name,
        room_type: 'building',
        long_description: generate_building_description(building_type, address),
        min_x: bounds[:min_x],
        max_x: bounds[:max_x],
        min_y: bounds[:min_y],
        max_y: bounds[:max_y],
        min_z: bounds[:min_z],
        max_z: bounds[:max_z],
        grid_x: grid_x || parent_room&.grid_x,
        grid_y: grid_y || parent_room&.grid_y,
        city_role: 'building',
        building_type: building_type.to_s,
        street_name: address
      )
    end

    # Populate a building with interior rooms
    # @param building [Room] the building room
    # @param building_type [Symbol] type of building
    # @param config [Hash] building configuration
    # @param bounds [Hash] building coordinate bounds
    # @param location [Location] the city location
    # @return [Array<Room>] interior rooms created
    def populate_building(building:, building_type:, config:, bounds:, location:)
      bt = building_type.to_sym

      # Parks and open areas - no interior needed
      return [] if %i[park garden playground plaza courtyard sports_field vacant_lot vacant].include?(bt)

      # Simple single-room buildings with no interior
      return [] if %i[warehouse gas_station subway_entrance government].include?(bt)

      # Determine floor count
      floor_count = config[:floors] || determine_floor_count(building_type, bounds)

      interior_rooms = []

      floor_count.times do |floor_num|
        # Generate the floor plan
        plan = FloorPlanService.generate(
          building_bounds: bounds,
          floor_number: floor_num,
          building_type: bt
        )

        # Create Room records from the plan
        plan.each do |room_def|
          room = Room.create(
            location_id: location.id,
            name: "#{building.name} - #{room_def[:name]}",
            room_type: room_def[:room_type],
            long_description: generate_room_description(building_type, room_def[:name], floor_num),
            min_x: room_def[:bounds][:min_x],
            max_x: room_def[:bounds][:max_x],
            min_y: room_def[:bounds][:min_y],
            max_y: room_def[:bounds][:max_y],
            min_z: room_def[:bounds][:min_z],
            max_z: room_def[:bounds][:max_z],
            grid_x: building.grid_x,
            grid_y: building.grid_y,
            city_role: 'building',
            building_type: building.building_type,
            floor_number: floor_num
          )
          interior_rooms << room

          # Create interior door between room and hallway
          create_interior_door(room, building) unless room_def[:is_hallway]
        end
      end

      # Link all interior rooms to their parent building shell as subrooms
      if interior_rooms.any?
        Room.where(id: interior_rooms.map(&:id)).update(inside_room_id: building.id)
        interior_rooms.each { |r| r.values[:inside_room_id] = building.id }
      end

      # Auto-connect floors with stairs
      connect_floors(interior_rooms, floor_count) if floor_count > 1

      interior_rooms
    end

    # Build a block using a specific layout configuration
    # Creates multiple buildings/structures within a block based on the layout
    # @param location [Location] the city location
    # @param intersection_room [Room] the intersection room marking the block's corner
    # @param layout [Symbol] layout name (:full, :split_ns, :quadrants, :terrace_north, etc.)
    # @param building_assignments [Hash] mapping of section position to building type
    # @param options [Hash] additional options
    # @return [Array<Room>] all created rooms
    def build_block_layout(location:, intersection_room:, layout:, building_assignments: {}, options: {})
      grid_x = intersection_room.grid_x
      grid_y = intersection_room.grid_y

      # Get block bounds
      block_bounds = GridCalculationService.block_bounds(
        intersection_x: grid_x,
        intersection_y: grid_y
      )

      # Get layout configuration
      layout_config = GridCalculationService.block_layout(layout)
      max_height = options[:max_height] || location.max_building_height || 200

      # Get street name for addresses
      street_name = find_adjacent_street_name(location, grid_x, grid_y)

      all_rooms = []

      # Build each section according to the layout
      layout_config[:sections].each_with_index do |section, section_idx|
        position = section[:position]
        index = section[:index] || 0

        # Get building type for this section (from assignments or default)
        building_type = building_assignments[position] ||
                        building_assignments[section_idx] ||
                        default_building_for_position(position, layout)

        next unless building_type
        next if building_type == :open || building_type == :courtyard_open

        # Calculate section bounds
        section_bounds = GridCalculationService.section_bounds(
          block_bounds: block_bounds,
          position: position,
          index: index,
          max_height: max_height
        )

        next unless section_bounds

        # Generate address
        address = GridCalculationService.format_address(
          street_name: street_name,
          grid_x: grid_x,
          grid_y: grid_y,
          unit_number: section_idx > 0 ? section_idx + 1 : nil
        )

        # Create building based on type
        rooms = create_section_building(
          location: location,
          building_type: building_type,
          bounds: section_bounds,
          address: address,
          grid_x: grid_x,
          grid_y: grid_y,
          section_position: position,
          section_index: index
        )

        all_rooms.concat(rooms)
      end

      all_rooms
    end

    # Create a building for a section within a block
    # @param location [Location] the city location
    # @param building_type [Symbol] type of building
    # @param bounds [Hash] section bounds
    # @param address [String] building address
    # @param grid_x [Integer] grid X position
    # @param grid_y [Integer] grid Y position
    # @param section_position [Symbol] position within block
    # @param section_index [Integer] index for row positions
    # @return [Array<Room>] created rooms
    def create_section_building(location:, building_type:, bounds:, address:, grid_x:, grid_y:, section_position:, section_index: 0)
      config = GridCalculationService.building_config(building_type)

      # Adjust height based on config
      adjusted_bounds = bounds.merge(
        max_z: [config[:height], bounds[:max_z]].min
      )

      # Create the main building room
      building = create_building(
        location: location,
        parent_room: nil,
        building_type: building_type,
        bounds: adjusted_bounds,
        address: address,
        name: generate_section_building_name(building_type, address, section_position, section_index),
        grid_x: grid_x,
        grid_y: grid_y
      )

      # Populate with interior rooms
      interior_rooms = populate_building(
        building: building,
        building_type: building_type,
        config: config,
        bounds: adjusted_bounds,
        location: location
      )

      [building] + interior_rooms
    end

    # Create a row of terrace houses
    # @param location [Location] the city location
    # @param intersection_room [Room] the intersection room
    # @param edge [Symbol] :north, :south, :east, :west
    # @param count [Integer] number of terraces (default 6)
    # @param options [Hash] additional options
    # @return [Array<Room>] all created rooms
    def build_terrace_row(location:, intersection_room:, edge:, count: 6, options: {})
      layout = :"terrace_#{edge}"
      building_assignments = {}

      count.times do |i|
        position = :"terrace_#{edge[0]}"  # :terrace_n, :terrace_s, :terrace_e, :terrace_w
        building_assignments[i] = :terrace
      end

      build_block_layout(
        location: location,
        intersection_room: intersection_room,
        layout: layout,
        building_assignments: building_assignments,
        options: options
      )
    end

    # Find the nearest available apartment in the city
    # @param location [Location] the city location
    # @param apartment_size [Symbol] :small, :medium, :large, or :penthouse
    # @return [Room, nil] an available apartment room, or nil if none available
    def find_available_apartment(location:, apartment_size: :medium)
      # Find apartment rooms that aren't assigned to anyone
      apartments = Room.where(
        location_id: location.id,
        building_type: 'apartment_tower',
        room_type: 'apartment'
      ).exclude(floor_number: 0) # Exclude lobby
       .where(owner_id: nil)

      # Filter by size if specified
      apartments = case apartment_size
                   when :small
                     apartments.where { floor_number < 5 }
                   when :large
                     apartments.where { floor_number >= 10 }
                   when :penthouse
                     apartments.order(Sequel.desc(:floor_number)).limit(4)
                   else
                     apartments
                   end

      # Return first unassigned apartment
      # (In a real system, you'd track assignment status)
      apartments.first
    end

    # Assign a building/unit to a character
    # @param room [Room] the room to assign
    # @param character [Character] the character to assign to
    # @return [Boolean] success status
    def assign_to_character(room:, character:)
      # This would integrate with the ownership/rental system
      # For now, just update the room's owner field if it exists
      if room.respond_to?(:owner_id) && room.owner_id && room.owner_id != character.id
        false
      elsif room.respond_to?(:owner_id=)
        room.owner_id = character.id
        room.save
        true
      else
        # If Room doesn't have owner tracking yet, just return success
        true
      end
    end

    # Add street-facing doors to all buildings in a location that don't have one.
    # @param location [Location] the city location
    # @return [Integer] number of doors created
    def backfill_doors(location:)
      buildings = Room.where(
        location_id: location.id,
        city_role: 'building'
      ).exclude(room_type: %w[street avenue intersection safe]).all

      existing_door_room_ids = RoomFeature.where(
        room_id: buildings.map(&:id),
        feature_type: 'door'
      ).select_map(:room_id).to_set

      count = 0
      buildings.each do |building|
        next if existing_door_room_ids.include?(building.id)

        create_building_door(building)
        count += 1
      end

      count
    end

    private

    # Resolve building bounds using lot-aware placement.
    # When lot_bounds is provided (from city generation), use those bounds directly.
    # Otherwise, auto-subdivide the block based on building type.
    #
    # @param location [Location] the city location
    # @param block_bounds [Hash] { min_x:, max_x:, min_y:, max_y:, width:, height: }
    # @param building_type [Symbol] type of building
    # @param grid_x [Integer] block grid X position
    # @param grid_y [Integer] block grid Y position
    # @param max_height [Integer] maximum building height in feet
    # @param lot_bounds [Hash, nil] pre-calculated lot bounds from city generation
    # @param position [Symbol] building position within block (for legacy fallback)
    # @return [Hash] { min_x:, max_x:, min_y:, max_y:, min_z:, max_z: }
    def resolve_building_bounds(location:, block_bounds:, building_type:, grid_x:, grid_y:, max_height:, lot_bounds: nil, position: :full)
      config = GridCalculationService.building_config(building_type)
      effective_height = [config[:height], max_height].min

      # Option 1: Explicit lot_bounds provided (from city generation pipeline)
      if lot_bounds
        return lot_bounds.merge(
          min_z: lot_bounds[:min_z] || 0,
          max_z: [lot_bounds[:max_z] || max_height, effective_height].min
        )
      end

      # Option 2: Auto-subdivide based on building type
      lot_size = BlockLotService.lot_size_for_building(building_type)

      if lot_size == :full_block
        # Full-block buildings use the entire block, no alleys
        return {
          min_x: block_bounds[:min_x],
          max_x: block_bounds[:max_x],
          min_y: block_bounds[:min_y],
          max_y: block_bounds[:max_y],
          min_z: 0,
          max_z: effective_height
        }
      end

      # For :large or :small buildings, determine block subdivision type
      block_type = lot_size == :large ? :half_ns : :quarters

      # Check if alleys already exist at this grid position
      existing_alleys = Room.where(
        location_id: location.id,
        grid_x: grid_x,
        grid_y: grid_y,
        room_type: 'alley'
      ).count

      # Create alleys if none exist yet
      if existing_alleys == 0
        BlockLotService.create_alleys(
          location: location,
          block_bounds: block_bounds,
          block_type: block_type,
          grid_x: grid_x,
          grid_y: grid_y
        )
      end

      # Get lot subdivisions
      lots = BlockLotService.lot_bounds(
        block_bounds: block_bounds,
        block_type: block_type,
        max_height: max_height
      )

      # Find the first available lot (no existing building at the same min_x/min_y)
      available_lot = find_available_lot(location, grid_x, grid_y, lots)

      if available_lot
        available_lot.merge(
          min_z: 0,
          max_z: [available_lot[:max_z] || max_height, effective_height].min
        )
      else
        # Fallback: use full block bounds if all lots are taken
        GridCalculationService.building_footprint(
          block_bounds: block_bounds,
          building_type: building_type,
          position: position,
          max_height: max_height
        )
      end
    end

    # Find the first lot that doesn't already have a building placed at its position.
    #
    # @param location [Location] the city location
    # @param grid_x [Integer] block grid X position
    # @param grid_y [Integer] block grid Y position
    # @param lots [Hash<Symbol, Hash>] lot_name => lot bounds
    # @return [Hash, nil] the first available lot bounds, or nil if all taken
    def find_available_lot(location, grid_x, grid_y, lots)
      # Get all existing building min_x/min_y pairs at this grid position
      existing_buildings = Room.where(
        location_id: location.id,
        grid_x: grid_x,
        grid_y: grid_y,
        city_role: 'building'
      ).select_map([:min_x, :min_y])

      occupied_positions = existing_buildings.to_set

      lots.each_value do |lot|
        unless occupied_positions.include?([lot[:min_x], lot[:min_y]])
          return lot
        end
      end

      nil
    end


    # Create a street-facing door on a building.
    # Detects which edge faces a street/avenue and places the door there.
    # @param building [Room] the building room
    # @return [RoomFeature, nil] the created door, or nil for parks/open spaces
    def create_building_door(building)
      # Parks and open spaces don't need doors
      bt = building.building_type.to_s
      return nil if %w[park garden playground plaza courtyard sports_field vacant_lot vacant].include?(bt)
      return nil unless building.min_x && building.max_x && building.min_y && building.max_y

      # Determine which edge faces a street
      door_info = detect_street_facing_edge(building)
      direction = door_info[:direction]
      x = door_info[:x]
      y = door_info[:y]

      RoomFeature.create(
        room_id: building.id,
        feature_type: 'door',
        name: 'Front Door',
        description: "The main entrance to #{building.name}.",
        x: x,
        y: y,
        z: 0.0,
        direction: direction,
        open_state: 'open',
        allows_sight: true,
        allows_movement: true
      )
    rescue StandardError => e
      warn "[BlockBuilderService] Failed to create door for building #{building.id}: #{e.message}"
      nil
    end

    # Find the street name from an adjacent street room
    def find_adjacent_street_name(location, grid_x, grid_y)
      # Look for a street at this grid position
      street = Room.where(
        location_id: location.id,
        grid_y: grid_y,
        city_role: 'street'
      ).first

      street&.street_name || "#{CoreExtensions.ordinalize(grid_y + 1)} Street"
    end

    public

    # Generate a building name based on type and address.
    # Public because it is called from BuilderApi.
    def generate_building_name(building_type, address)
      case building_type
      when :apartment_tower
        "#{address} Apartments"
      when :office_tower
        "#{address} Tower"
      when :brownstone
        "#{address} Brownstone"
      when :house
        address
      when :mall
        "#{address} Mall"
      when :shop
        "Shop at #{address}"
      when :park
        "#{address} Park"
      else
        address
      end
    end

    private

    # Generate a building description
    def generate_building_description(building_type, address)
      case building_type
      when :apartment_tower
        "A modern apartment tower located at #{address}. Multiple floors of residential units rise above a ground-floor lobby."
      when :office_tower
        "A sleek office tower at #{address}. Professional spaces occupy multiple floors of this commercial building."
      when :brownstone
        "A classic brownstone building at #{address}. Three floors of urban living in a traditional style."
      when :house
        "A residential house at #{address}. A cozy home with multiple rooms."
      when :mall
        "A shopping mall at #{address}. Multiple levels of retail stores and restaurants."
      when :shop
        "A small shop at #{address}."
      when :park
        "A green urban park at #{address}. Trees and benches offer a peaceful respite from the city."
      else
        "A building at #{address}."
      end
    end

    # Determine floor count from building height when config doesn't specify
    def determine_floor_count(building_type, bounds)
      max_z = bounds[:max_z] || 10
      min_z = bounds[:min_z] || 0
      height = max_z - min_z
      (height / FloorPlanService::FLOOR_HEIGHT.to_f).ceil.clamp(1, 50)
    end

    # Create stair features connecting adjacent floors within a building.
    # Groups rooms by floor_number and links hallways (or first rooms) with hatch features.
    def connect_floors(interior_rooms, floor_count)
      return if interior_rooms.empty? || floor_count <= 1

      # Group by floor_number
      by_floor = interior_rooms.group_by(&:floor_number)

      (floor_count - 1).times do |floor_num|
        lower_rooms = by_floor[floor_num] || []
        upper_rooms = by_floor[floor_num + 1] || []
        next if lower_rooms.empty? || upper_rooms.empty?

        # Find hallway or first room on each floor
        lower_room = lower_rooms.find { |r| r.room_type == 'hallway' } || lower_rooms.first
        upper_room = upper_rooms.find { |r| r.room_type == 'hallway' } || upper_rooms.first

        # Place stairs near the center of each room
        lower_cx = ((lower_room.min_x || 0) + (lower_room.max_x || 10)) / 2.0
        lower_cy = ((lower_room.min_y || 0) + (lower_room.max_y || 10)) / 2.0
        upper_cx = ((upper_room.min_x || 0) + (upper_room.max_x || 10)) / 2.0
        upper_cy = ((upper_room.min_y || 0) + (upper_room.max_y || 10)) / 2.0

        # Create "Stairs Up" on the lower floor
        RoomFeature.create(
          room_id: lower_room.id,
          feature_type: 'staircase',
          name: 'Stairway Up',
          description: 'A stairway leading to the floor above.',
          x: lower_cx,
          y: lower_cy,
          z: 0.0,
          direction: 'up',
          open_state: 'open',
          allows_sight: true,
          allows_movement: true,
          connected_room_id: upper_room.id
        )

        # Create "Stairs Down" on the upper floor
        RoomFeature.create(
          room_id: upper_room.id,
          feature_type: 'staircase',
          name: 'Stairway Down',
          description: 'A stairway leading to the floor below.',
          x: upper_cx,
          y: upper_cy,
          z: 0.0,
          direction: 'down',
          open_state: 'open',
          allows_sight: true,
          allows_movement: true,
          connected_room_id: lower_room.id
        )
      rescue StandardError => e
        warn "[BlockBuilder] Failed to connect floors #{floor_num} and #{floor_num + 1}: #{e.message}"
      end
    end

    # Generate a contextual room description based on building type and room name
    def generate_room_description(building_type, room_name, floor_num)
      bt = building_type.to_s.tr('_', ' ')
      if floor_num == 0
        "The #{room_name.downcase} on the ground floor of a #{bt}."
      else
        "The #{room_name.downcase} on floor #{floor_num + 1} of a #{bt}."
      end
    end

    # Create an interior door feature on a room, positioned on the edge
    # closest to the building center (where the hallway typically is).
    def create_interior_door(room, building)
      return unless room.min_x && room.min_y && room.max_x && room.max_y
      return unless building.min_x && building.min_y && building.max_x && building.max_y

      # Calculate building center (where hallway typically is)
      bldg_cx = (building.min_x + building.max_x) / 2.0
      bldg_cy = (building.min_y + building.max_y) / 2.0

      # Calculate room center
      room_cx = (room.min_x + room.max_x) / 2.0
      room_cy = (room.min_y + room.max_y) / 2.0

      # Determine which edge of the room faces the building center
      dx = bldg_cx - room_cx
      dy = bldg_cy - room_cy

      if dx.abs > dy.abs
        if dx > 0
          direction = 'east'
          x = room.max_x.to_f
          y = room_cy
        else
          direction = 'west'
          x = room.min_x.to_f
          y = room_cy
        end
      else
        if dy > 0
          direction = 'north'
          x = room_cx
          y = room.max_y.to_f
        else
          direction = 'south'
          x = room_cx
          y = room.min_y.to_f
        end
      end

      RoomFeature.create(
        room_id: room.id,
        feature_type: 'door',
        name: 'Door',
        description: "A door connecting to the hallway.",
        x: x,
        y: y,
        z: 0.0,
        direction: direction,
        open_state: 'open',
        allows_sight: true,
        allows_movement: true
      )
    rescue StandardError => e
      warn "[BlockBuilderService] Failed to create interior door: #{e.message}"
    end

    # Detect which edge of a building faces a street/avenue.
    # Checks each edge for nearby street/avenue/intersection rooms.
    # @param building [Room] the building room
    # @return [Hash] { direction:, x:, y: } for door placement
    def detect_street_facing_edge(building)
      mid_x = (building.min_x + building.max_x) / 2.0
      mid_y = (building.min_y + building.max_y) / 2.0
      b_min_x = building.min_x
      b_max_x = building.max_x
      b_min_y = building.min_y
      b_max_y = building.max_y
      tolerance = 5

      streets = Room.where(location_id: building.location_id, city_role: %w[street avenue intersection])

      # South: street whose max_y is near building's min_y
      if streets.where(Sequel.lit('max_y >= ? AND max_y <= ?', b_min_y - tolerance, b_min_y + tolerance)).any?
        return { direction: 'south', x: mid_x, y: b_min_y.to_f }
      end

      # North: street whose min_y is near building's max_y
      if streets.where(Sequel.lit('min_y >= ? AND min_y <= ?', b_max_y - tolerance, b_max_y + tolerance)).any?
        return { direction: 'north', x: mid_x, y: b_max_y.to_f }
      end

      # West: street/avenue whose max_x is near building's min_x
      if streets.where(Sequel.lit('max_x >= ? AND max_x <= ?', b_min_x - tolerance, b_min_x + tolerance)).any?
        return { direction: 'west', x: b_min_x.to_f, y: mid_y }
      end

      # East: street/avenue whose min_x is near building's max_x
      if streets.where(Sequel.lit('min_x >= ? AND min_x <= ?', b_max_x - tolerance, b_max_x + tolerance)).any?
        return { direction: 'east', x: b_max_x.to_f, y: mid_y }
      end

      # Default: south
      { direction: 'south', x: mid_x, y: b_min_y.to_f }
    end

    # Determine default building type for a section position
    def default_building_for_position(position, layout)
      case position
      when :full
        :house
      when :north, :south, :east, :west
        :brownstone
      when :ne, :nw, :se, :sw
        :house
      when :terrace_n, :terrace_s, :terrace_e, :terrace_w
        :terrace
      when :center
        layout == :perimeter ? :courtyard : :park
      when :perimeter_n, :perimeter_s, :perimeter_e, :perimeter_w
        :shop
      when :center_large
        :apartment_tower
      when :corner_ne, :corner_nw, :corner_se, :corner_sw
        :shop
      when :open_sw, :open_se
        nil  # Open area, no building
      else
        :house
      end
    end

    # Generate building name for a section within a block
    def generate_section_building_name(building_type, address, section_position, section_index)
      type_names = {
        apartment_tower: 'Apartments',
        condo_tower: 'Condos',
        office_tower: 'Tower',
        brownstone: 'Brownstone',
        house: '',
        terrace: 'Terrace',
        townhouse: 'Townhouse',
        cottage: 'Cottage',
        hotel: 'Hotel',
        mall: 'Mall',
        shop: 'Shop',
        restaurant: 'Restaurant',
        bar: 'Bar',
        cafe: 'Café',
        gym: 'Fitness',
        cinema: 'Cinema',
        warehouse: 'Warehouse',
        church: 'Church',
        temple: 'Temple',
        school: 'School',
        hospital: 'Hospital',
        clinic: 'Medical Clinic',
        library: 'Library',
        police_station: 'Police Station',
        fire_station: 'Fire Station',
        government: 'Government Building',
        park: 'Park',
        playground: 'Playground',
        garden: 'Garden',
        plaza: 'Plaza',
        courtyard: 'Courtyard',
        sports_field: 'Sports Field',
        parking_garage: 'Parking',
        gas_station: 'Gas Station',
        subway_entrance: 'Subway Entrance'
      }

      type_name = type_names[building_type.to_sym] || building_type.to_s.gsub('_', ' ').split.map(&:capitalize).join(' ')

      # For terrace rows, add a number
      if section_position.to_s.start_with?('terrace_')
        "#{address} #{type_name} ##{section_index + 1}"
      elsif type_name.empty?
        address
      else
        "#{address} #{type_name}"
      end
    end

  end
end
