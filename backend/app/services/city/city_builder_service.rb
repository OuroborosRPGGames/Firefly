# frozen_string_literal: true

# CityBuilderService is the main orchestrator for city/town building.
#
# Coordinates street name generation, grid creation, and building placement
# to create a complete urban grid from parameters.
#
# @example Build a city programmatically
#   result = CityBuilderService.build_city(
#     location: location,
#     params: {
#       city_name: 'New York City',
#       horizontal_streets: 10,
#       vertical_streets: 10,
#       max_building_height: 200,
#       longitude: -74.0060,
#       latitude: 40.7128
#     },
#     character: builder_character
#   )
#
# @example Find and assign an apartment
#   apartment = CityBuilderService.find_or_create_building(
#     location: city_location,
#     building_type: :apartment,
#     preferences: { size: :medium }
#   )
#   CityBuilderService.assign_building(building: apartment, character: character)
#
class CityBuilderService
  class << self
    # Build a complete city grid with streets, intersections, and optional buildings
    # @param location [Location] the location to build the city in
    # @param params [Hash] city parameters
    # @option params [String] :city_name name of the city
    # @option params [Integer] :horizontal_streets number of E-W streets (default: 10)
    # @option params [Integer] :vertical_streets number of N-S avenues (default: 10)
    # @option params [Integer] :max_building_height max height in feet (default: 200)
    # @option params [Float] :longitude optional longitude for LLM context
    # @option params [Float] :latitude optional latitude for LLM context
    # @option params [Boolean] :use_llm_names force LLM usage for street names
    # @param character [Character, nil] the character building the city (for permissions)
    # @return [Hash] { success:, streets:, avenues:, intersections:, sky_room:, error: }
    def build_city(location:, params:, character: nil)
      DB.transaction do
        # Update location with city parameters
        update_location_params(location, params)
        clear_existing_city_grid!(location)

        # Generate street and avenue names (or use provided overrides)
        street_count = params[:horizontal_streets] || 10
        avenue_count = params[:vertical_streets] || 10

        provided_street_names = params[:street_names]
        provided_avenue_names = params[:avenue_names]

        street_names = if provided_street_names.is_a?(Array) && provided_street_names.length >= street_count
                         provided_street_names.first(street_count)
                       else
                         generate_street_names(location, street_count, params[:use_llm_names])
                       end

        street_bases = street_names.map { |n| StreetNameService.extract_base_name(n) }
        avenue_names = if provided_avenue_names.is_a?(Array) && provided_avenue_names.length >= avenue_count
                         provided_avenue_names.first(avenue_count)
                       else
                         generate_avenue_names(location, avenue_count, params[:use_llm_names], exclude_bases: street_bases)
                       end

        # Cache the names on the location
        save_street_names(location, street_names, avenue_names)

        # Create the grid
        streets = build_streets(location, street_names, avenue_count)
        avenues = build_avenues(location, avenue_names, street_count)
        intersections = build_intersections(location, streets, avenues, street_names, avenue_names)

        # Create sky room above the city
        sky_room = build_sky_room(location, street_count, avenue_count)

        # Mark city as built
        location.city_built_at = Time.now
        location.save

        # Mark rooms outside zone polygon as inaccessible
        polygon_result = mark_rooms_outside_polygon(location)

        {
          success: true,
          streets: streets,
          avenues: avenues,
          intersections: intersections,
          sky_room: sky_room,
          street_names: street_names,
          avenue_names: avenue_names,
          polygon_status: polygon_result
        }
      end
    rescue StandardError => e
      warn "[CityBuilderService] build_city failed: #{e.message}"
      {
        success: false,
        error: e.message
      }
    end

    # Generate street names (E-W running)
    # @param location [Location] the city location
    # @param count [Integer] number of streets
    # @param use_llm [Boolean, nil] force LLM usage
    # @return [Array<String>] street names
    def generate_street_names(location, count, use_llm = nil)
      StreetNameService.generate(
        location: location,
        count: count,
        direction: :street,
        use_llm: use_llm
      )
    end

    # Generate avenue names (N-S running)
    # @param location [Location] the city location
    # @param count [Integer] number of avenues
    # @param use_llm [Boolean, nil] force LLM usage
    # @return [Array<String>] avenue names
    def generate_avenue_names(location, count, use_llm = nil, exclude_bases: [])
      StreetNameService.generate(
        location: location,
        count: count,
        direction: :avenue,
        use_llm: use_llm,
        exclude_bases: exclude_bases
      )
    end

    # Build street rooms (E-W running, spanning the full city width)
    # Each street is a single long room. Intersections overlay on top.
    # @param location [Location] the city location
    # @param street_names [Array<String>] names for streets
    # @param avenue_count [Integer] number of avenues (determines city width)
    # @return [Array<Room>] street rooms (excludes rooms wholly outside polygon)
    def build_streets(location, street_names, avenue_count)
      rooms = []

      street_names.each_with_index do |name, street_index|
        bounds = GridCalculationService.street_bounds(
          grid_index: street_index,
          city_size: avenue_count
        )

        next unless room_bounds_have_usable_area?(location, bounds)

        room = Room.create(
          location_id: location.id,
          name: name,
          room_type: 'street',
          short_description: "A city street running east to west.",
          long_description: "#{name} runs east to west through the city.",
          min_x: bounds[:min_x],
          max_x: bounds[:max_x],
          min_y: bounds[:min_y],
          max_y: bounds[:max_y],
          min_z: bounds[:min_z],
          max_z: bounds[:max_z],
          grid_x: nil,
          grid_y: street_index,
          city_role: 'street',
          street_name: name
        )
        rooms << room
      end

      rooms
    end

    # Build avenue rooms (N-S running, spanning the full city height)
    # Each avenue is a single long room. Intersections overlay on top.
    # @param location [Location] the city location
    # @param avenue_names [Array<String>] names for avenues
    # @param street_count [Integer] number of streets (determines city height)
    # @return [Array<Room>] avenue rooms (excludes rooms wholly outside polygon)
    def build_avenues(location, avenue_names, street_count)
      rooms = []

      avenue_names.each_with_index do |name, avenue_index|
        bounds = GridCalculationService.avenue_bounds(
          grid_index: avenue_index,
          city_size: street_count
        )

        next unless room_bounds_have_usable_area?(location, bounds)

        room = Room.create(
          location_id: location.id,
          name: name,
          room_type: 'avenue',
          short_description: "A city avenue running north to south.",
          long_description: "#{name} runs north to south through the city.",
          min_x: bounds[:min_x],
          max_x: bounds[:max_x],
          min_y: bounds[:min_y],
          max_y: bounds[:max_y],
          min_z: bounds[:min_z],
          max_z: bounds[:max_z],
          grid_x: avenue_index,
          grid_y: nil,
          city_role: 'avenue',
          street_name: name
        )
        rooms << room
      end

      rooms
    end

    # Build intersection rooms at grid crossings
    # @param location [Location] the city location
    # @param streets [Array<Room>] street rooms
    # @param avenues [Array<Room>] avenue rooms
    # @param street_names [Array<String>] street names
    # @param avenue_names [Array<String>] avenue names
    # @return [Array<Room>] intersection rooms (excludes rooms wholly outside polygon)
    def build_intersections(location, streets, avenues, street_names, avenue_names)
      intersections = []

      street_names.each_with_index do |street_name, y_index|
        avenue_names.each_with_index do |avenue_name, x_index|
          bounds = GridCalculationService.intersection_bounds(
            grid_x: x_index,
            grid_y: y_index
          )

          # Skip room creation if wholly outside zone polygon
          next unless room_bounds_have_usable_area?(location, bounds)

          intersection_name = "#{street_name} & #{avenue_name}"

          intersection = Room.create(
            location_id: location.id,
            name: intersection_name,
            room_type: 'intersection',
            short_description: "A busy city intersection.",
            long_description: "The intersection of #{street_name} and #{avenue_name}.",
            min_x: bounds[:min_x],
            max_x: bounds[:max_x],
            min_y: bounds[:min_y],
            max_y: bounds[:max_y],
            min_z: bounds[:min_z],
            max_z: bounds[:max_z],
            grid_x: x_index,
            grid_y: y_index,
            city_role: 'intersection',
            street_name: intersection_name
          )

          intersections << intersection
        end
      end

      intersections
    end

    # Build the sky room above the city
    # @param location [Location] the city location
    # @param street_count [Integer] number of streets
    # @param avenue_count [Integer] number of avenues
    # @return [Room] the sky room
    def build_sky_room(location, street_count, avenue_count)
      dimensions = GridCalculationService.city_dimensions(
        horizontal_streets: street_count,
        vertical_streets: avenue_count
      )

      max_height = location.max_building_height || GameConfig::DEFAULT_BUILDING_HEIGHT
      sky_clearance = GameConfig::SKY_CLEARANCE_FEET
      sky_height = max_height + sky_clearance

      Room.create(
        location_id: location.id,
        name: "Sky Above #{location.city_name || location.name}",
        room_type: 'sky',
        short_description: "High above the city.",
        long_description: "High above the city, the sky stretches out in all directions. Below, the urban grid spreads like a vast checkerboard.",
        min_x: 0,
        max_x: dimensions[:width],
        min_y: 0,
        max_y: dimensions[:height],
        min_z: sky_height,
        max_z: sky_height + GameConfig::SKY_HEIGHT_FEET,
        city_role: 'sky',
        grid_x: nil,
        grid_y: nil
      )
    end

    # Find or create a building of a specific type
    # @param location [Location] the city location
    # @param building_type [Symbol] :apartment, :brownstone, :house, :shop
    # @param preferences [Hash] optional preferences (size, floor, etc.)
    # @return [Room] the building room
    def find_or_create_building(location:, building_type:, preferences: {})
      # First try to find an existing available building
      existing = find_available_building(location, building_type, preferences)
      return existing if existing

      # Need to create a new building - find a suitable intersection
      intersection = find_available_intersection(location)
      return nil unless intersection

      # Build at this intersection
      rooms = BlockBuilderService.build_block(
        location: location,
        intersection_room: intersection,
        building_type: building_type,
        options: preferences
      )

      # Return the appropriate room based on building type
      case building_type
      when :apartment, :apartment_tower
        rooms.find { |r| r.room_type == 'apartment' }
      when :office, :office_tower
        rooms.find { |r| r.room_type == 'office' }
      else
        rooms.first
      end
    end

    # Assign a building/unit to a character
    # @param building [Room] the room to assign
    # @param character [Character] the character to assign to
    # @return [Boolean] success status
    def assign_building(building:, character:)
      BlockBuilderService.assign_to_character(room: building, character: character)
    end

    # Check if a character has permission to build
    # @param character [Character] the character
    # @param operation [Symbol] :build_city, :build_block, :build_apartment, :assign
    # @return [Boolean] whether character has permission
    def can_build?(character, operation)
      return true if character_is_admin?(character)

      case operation
      when :build_city, :build_block, :delete_city
        character_has_building_permission?(character)
      when :build_apartment, :build_shop
        character_in_creator_mode?(character) || character_has_building_permission?(character)
      when :assign
        character_has_building_permission?(character)
      else
        false
      end
    end

    private

    # Remove previously generated city grid rooms before rebuilding.
    # Keeps building/vacant/interior rooms intact to avoid data loss.
    def clear_existing_city_grid!(location)
      Room.where(location_id: location.id, city_role: %w[street avenue intersection sky]).delete
      RoomExitCacheService.invalidate_location!(location.id) if defined?(RoomExitCacheService)
    rescue StandardError => e
      warn "[CityBuilderService] Failed to clear existing grid for location #{location.id}: #{e.message}"
      raise
    end

    # Mark rooms outside zone polygon as inaccessible
    # With new clipping system, this also:
    # - Deletes rooms wholly outside polygon
    # - Calculates effective polygons for rooms straddling boundary
    # @param location [Location] the city location
    # @return [Hash, nil] { kept:, deleted:, inside:, outside: } or nil if no polygon
    def mark_rooms_outside_polygon(location)
      return nil unless location.zone&.has_polygon?

      RoomPolygonService.recalculate_location(location)
    end

    # Check if a room with given bounds would have any usable area
    # Call this before creating rooms to avoid creating then deleting
    # @param location [Location] the city location
    # @param bounds [Hash] { min_x:, max_x:, min_y:, max_y: }
    # @return [Boolean] true if room would have usable area
    def room_bounds_have_usable_area?(location, bounds)
      return true unless location.zone&.has_polygon?

      RoomPolygonService.can_create_room?(
        location,
        min_x: bounds[:min_x],
        max_x: bounds[:max_x],
        min_y: bounds[:min_y],
        max_y: bounds[:max_y]
      )
    end

    # Update location with city parameters
    def update_location_params(location, params)
      location.city_name = params[:city_name] if params[:city_name]
      location.horizontal_streets = params[:horizontal_streets] if params[:horizontal_streets]
      location.vertical_streets = params[:vertical_streets] if params[:vertical_streets]
      location.max_building_height = params[:max_building_height] if params[:max_building_height]
      location.longitude = params[:longitude] if params[:longitude]
      location.latitude = params[:latitude] if params[:latitude]
      location.save

      # Clear zone's polygon when building a city - the globe-scale polygon (lat/lng)
      # is incompatible with the city-scale grid (feet). Cities fill their entire grid.
      if location.zone&.has_polygon?
        location.zone.update(polygon_points: nil)
      end
    end

    # Save generated street names to location
    def save_street_names(location, street_names, avenue_names)
      if location.respond_to?(:street_names_json=)
        location.street_names_json = Sequel.pg_json_wrap(street_names)
        location.avenue_names_json = Sequel.pg_json_wrap(avenue_names)
        location.save
      end
    rescue StandardError => e
      warn "[CityBuilderService] Failed to save street names: #{e.message}"
    end

    # Find an available building of a given type.
    # Delegates apartment search to BlockBuilderService to avoid duplication.
    def find_available_building(location, building_type, preferences)
      case building_type
      when :apartment, :apartment_tower
        BlockBuilderService.find_available_apartment(
          location: location,
          apartment_size: preferences[:size] || :medium
        )
      when :office, :office_tower
        Room.where(
          location_id: location.id,
          building_type: building_type.to_s,
          room_type: 'office',
          owner_id: nil
        ).first
      else
        Room.where(
          location_id: location.id,
          building_type: building_type.to_s
        ).first
      end
    end

    # Find an intersection that doesn't have a building yet using a single SQL query.
    def find_available_intersection(location)
      buildings_ds = Room.where(
        location_id: location.id,
        city_role: 'building'
      ).select(:grid_x, :grid_y)

      Room.where(
        location_id: location.id,
        city_role: 'intersection'
      ).exclude(
        [:grid_x, :grid_y] => buildings_ds
      ).first
    end

    # Check if character is an admin
    def character_is_admin?(character)
      return false unless character

      user = character.user
      return false unless user

      # Try admin? method first, then fall back to is_admin attribute
      if user.respond_to?(:admin?)
        user.admin?
      elsif user.respond_to?(:is_admin)
        user.is_admin
      else
        false
      end
    end

    # Check if character has building permission
    def character_has_building_permission?(character)
      return false unless character

      # Check for can_build flag on character or user
      return true if character.respond_to?(:can_build?) && character.can_build?

      user = character.user
      return true if user&.respond_to?(:can_build?) && user.can_build?

      false
    end

    # Check if character is in creator mode
    def character_in_creator_mode?(character)
      return false unless character

      # Try to get the instance from character's associations
      instance = if character.respond_to?(:current_instance)
                   character.current_instance
                 elsif character.respond_to?(:character_instances)
                   character.character_instances.find { |i| i.online }
                 end
      return false unless instance

      instance.respond_to?(:creator_mode?) && instance.creator_mode?
    end
  end
end
