# frozen_string_literal: true

# CityBuilderViewService aggregates city data for the admin city builder interface.
#
# Provides API methods for:
# - Fetching complete city data (grid, streets, blocks, buildings)
# - Creating buildings at specific grid positions
# - Deleting buildings and their interior rooms
#
# @example Get city data for rendering
#   CityBuilderViewService.city_data(location)
#
# @example Create a building
#   CityBuilderViewService.create_building(location, { grid_x: 1, grid_y: 2, building_type: 'house' })
#
class CityBuilderViewService
  class << self
    # Get complete city data for rendering in the editor
    # @param location [Location] the city location
    # @return [Hash] city data including grid info, streets, buildings, blocks
    def city_data(location)
      h_streets = location.horizontal_streets || 10
      v_streets = location.vertical_streets || 10

      {
        location_id: location.id,
        city_name: location.city_name || location.name,
        world_id: location.world_id,
        grid: grid_info(location, h_streets, v_streets),
        street_names: location.street_names_json || [],
        avenue_names: location.avenue_names_json || [],
        streets: streets_data(location),
        avenues: avenues_data(location),
        intersections: intersections_data(location),
        buildings: buildings_data(location),
        blocks: blocks_data(location, h_streets, v_streets)
      }
    end

    # Create a building at a specific grid position
    # @param location [Location] the city location
    # @param data [Hash] building data { grid_x:, grid_y:, building_type:, options: }
    # @return [Hash] result with success status and building data or error
    def create_building(location, data)
      grid_x = data['grid_x'].to_i
      grid_y = data['grid_y'].to_i

      # Find the intersection at this position
      intersection = Room.where(
        location_id: location.id,
        city_role: 'intersection',
        grid_x: grid_x,
        grid_y: grid_y
      ).first

      return { success: false, error: 'Invalid block position - no intersection found' } unless intersection

      # Check if building already exists at this position
      existing = Room.where(
        location_id: location.id,
        city_role: 'building',
        grid_x: grid_x,
        grid_y: grid_y
      ).first

      return { success: false, error: 'A building already exists at this position' } if existing

      # Build the block
      building_type = (data['building_type'] || 'house').to_sym
      options = data['options'] || {}

      rooms = BlockBuilderService.build_block(
        location: location,
        intersection_room: intersection,
        building_type: building_type,
        options: options
      )

      building = rooms.first
      return { success: false, error: 'Failed to create building' } unless building

      {
        success: true,
        building: building_to_api(building),
        total_rooms: rooms.count
      }
    rescue StandardError => e
      warn "[CityBuilderViewService] Error creating building: #{e.message}"
      { success: false, error: e.message }
    end

    # Delete a building and all its interior rooms
    # @param building_id [Integer] the building room ID
    # @return [Hash] result with success status
    def delete_building(building_id, location: nil)
      building = Room[building_id]
      return { success: false, error: 'Building not found' } unless building
      if location && building.location_id != location.id
        return { success: false, error: 'Building not found in this city' }
      end
      return { success: false, error: 'Not a building' } unless building.city_role == 'building'

      # Count interior rooms
      interior_count = Room.where(inside_room_id: building.id).count

      # Delete interior rooms first
      Room.where(inside_room_id: building.id).delete

      # Delete the building
      building.delete

      {
        success: true,
        deleted_rooms: interior_count + 1
      }
    rescue StandardError => e
      warn "[CityBuilderViewService] Error deleting building: #{e.message}"
      { success: false, error: e.message }
    end

    # Get building types grouped by category
    # @return [Hash<Symbol, Array<Hash>>] building types by category
    def building_types_by_category
      GridCalculationService.all_building_types.group_by { |_, config| config[:category] }.transform_values do |types|
        types.map do |name, config|
          {
            name: name,
            display_name: name.to_s.split('_').map(&:capitalize).join(' '),
            floors: config[:floors],
            height: config[:height],
            per_block: config[:per_block]
          }
        end
      end
    end

    private

    # Grid metadata
    def grid_info(location, h_streets, v_streets)
      dimensions = GridCalculationService.city_dimensions(
        horizontal_streets: h_streets,
        vertical_streets: v_streets
      )

      {
        horizontal_streets: h_streets,
        vertical_streets: v_streets,
        cell_size: GridCalculationService::GRID_CELL_SIZE,
        street_width: GridCalculationService::STREET_WIDTH,
        width: dimensions[:width],
        height: dimensions[:height],
        max_building_height: location.max_building_height || 200
      }
    end

    # Fetch rooms by city role and convert to API format
    # @param location [Location] the city location
    # @param role [String] the city role ('street', 'avenue', 'intersection', 'building')
    # @return [Array<Hash>] array of room data
    def rooms_by_role(location, role)
      location.rooms_dataset.where(city_role: role).map { |r| room_to_api(r) }
    end

    # Alias methods for clarity in city_data hash
    def streets_data(location) = rooms_by_role(location, 'street')
    def avenues_data(location) = rooms_by_role(location, 'avenue')
    def intersections_data(location) = rooms_by_role(location, 'intersection')

    # Fetch and format buildings with preloaded room counts (avoids N+1)
    # @param location [Location] the city location
    # @return [Array<Hash>] array of building data with room counts
    def buildings_data(location)
      # Only include top-level building shells (room_type 'building'),
      # not interior rooms (bedrooms, kitchens, etc.) which also have city_role 'building'
      buildings = location.rooms_dataset
                          .where(room_type: 'building')
                          .exclude(grid_x: nil)
                          .exclude(grid_y: nil)
                          .all

      # Preload room counts for all buildings in a single query
      building_ids = buildings.map(&:id)
      room_counts = Room.where(inside_room_id: building_ids)
                        .group_and_count(:inside_room_id)
                        .to_hash(:inside_room_id, :count)

      buildings.map { |b| building_to_api(b, room_counts[b.id] || 0) }
    end

    # Calculate block data for empty/filled display
    def blocks_data(location, h_streets, v_streets)
      # Get positions of all buildings
      building_positions = location.rooms_dataset
        .where(city_role: 'building')
        .select(:grid_x, :grid_y)
        .map { |r| [r.grid_x, r.grid_y] }

      blocks = []

      # Blocks are the areas between intersections (n-1 blocks for n intersections)
      (0...v_streets - 1).each do |x|
        (0...h_streets - 1).each do |y|
          bounds = GridCalculationService.block_bounds(
            intersection_x: x,
            intersection_y: y
          )

          blocks << {
            grid_x: x,
            grid_y: y,
            bounds: {
              min_x: bounds[:min_x],
              max_x: bounds[:max_x],
              min_y: bounds[:min_y],
              max_y: bounds[:max_y]
            },
            has_building: building_positions.include?([x, y])
          }
        end
      end

      blocks
    end

    # Convert a room to API format
    def room_to_api(room)
      {
        id: room.id,
        name: room.name,
        type: room.room_type,
        city_role: room.city_role,
        grid_x: room.grid_x,
        grid_y: room.grid_y,
        street_name: room.street_name,
        bounds: {
          min_x: room.min_x,
          max_x: room.max_x,
          min_y: room.min_y,
          max_y: room.max_y
        }
      }
    end

    # Convert a building to API format with additional details
    # @param building [Room] the building room
    # @param interior_count [Integer, nil] preloaded room count, or nil to query
    # @return [Hash] building data for API response
    def building_to_api(building, interior_count = nil)
      # Use preloaded count or query if not provided
      interior_count ||= Room.where(inside_room_id: building.id).count

      {
        id: building.id,
        name: building.name,
        type: building.room_type,
        building_type: building.building_type,
        city_role: building.city_role,
        grid_x: building.grid_x,
        grid_y: building.grid_y,
        street_name: building.street_name,
        bounds: {
          min_x: building.min_x,
          max_x: building.max_x,
          min_y: building.min_y,
          max_y: building.max_y,
          min_z: building.min_z || 0,
          max_z: building.max_z || 10
        },
        floors: calculate_floors(building),
        room_count: interior_count
      }
    end

    # Calculate floor count from building height
    def calculate_floors(building)
      max_z = building.max_z || 10
      min_z = building.min_z || 0
      height = max_z - min_z
      (height / 10.0).ceil.clamp(1, 50)
    end
  end
end
