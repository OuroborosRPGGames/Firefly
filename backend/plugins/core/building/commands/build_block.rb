# frozen_string_literal: true

module Commands
  module Building
    class BuildBlock < Commands::Base::Command
      command_name 'build block'
      aliases 'buildblock', 'create block', 'build building'
      category :building
      help_text 'Build a building at the current intersection'
      usage 'build block <type> [layout]'
      examples 'build block apartment', 'buildblock brownstone', 'build block terrace', 'build block shop quadrants'

      # All supported building types mapped to their internal symbols
      BUILDING_TYPES = {
        # Residential
        'apartment' => :apartment_tower,
        'apartment_tower' => :apartment_tower,
        'condo' => :condo_tower,
        'condo_tower' => :condo_tower,
        'brownstone' => :brownstone,
        'house' => :house,
        'terrace' => :terrace,
        'townhouse' => :townhouse,
        'cottage' => :cottage,
        # Commercial
        'office' => :office_tower,
        'office_tower' => :office_tower,
        'hotel' => :hotel,
        'mall' => :mall,
        'shop' => :shop,
        'restaurant' => :restaurant,
        'bar' => :bar,
        'cafe' => :cafe,
        'gym' => :gym,
        'cinema' => :cinema,
        'warehouse' => :warehouse,
        # Civic
        'church' => :church,
        'temple' => :temple,
        'school' => :school,
        'hospital' => :hospital,
        'clinic' => :clinic,
        'library' => :library,
        'police' => :police_station,
        'police_station' => :police_station,
        'fire' => :fire_station,
        'fire_station' => :fire_station,
        'government' => :government,
        # Recreation
        'park' => :park,
        'playground' => :playground,
        'garden' => :garden,
        'plaza' => :plaza,
        'courtyard' => :courtyard,
        'sports' => :sports_field,
        'sports_field' => :sports_field,
        # Infrastructure
        'parking' => :parking_garage,
        'parking_garage' => :parking_garage,
        'gas' => :gas_station,
        'gas_station' => :gas_station,
        'subway' => :subway_entrance,
        'subway_entrance' => :subway_entrance
      }.freeze

      # Layout types that can be used
      LAYOUT_TYPES = {
        'full' => :full,
        'single' => :full,
        'split' => :split_ns,
        'split_ns' => :split_ns,
        'split_ew' => :split_ew,
        'quadrants' => :quadrants,
        'four' => :quadrants,
        'terrace_north' => :terrace_north,
        'terrace_south' => :terrace_south,
        'terrace_east' => :terrace_east,
        'terrace_west' => :terrace_west,
        'row_north' => :terrace_north,
        'row_south' => :terrace_south,
        'row_east' => :terrace_east,
        'row_west' => :terrace_west,
        'perimeter' => :perimeter,
        'mixed' => :mixed_tower_shops,
        'mixed_tower' => :mixed_tower_shops
      }.freeze

      protected

      def perform_command(parsed_input)
        # Check permissions
        unless CityBuilderService.can_build?(character, :build_block)
          return error_result(
            'You must be staff with building permission to build blocks.'
          )
        end

        # Must be at an intersection
        current_room = location
        unless current_room.city_role == 'intersection'
          return error_result(
            'You must be at an intersection to build a block. ' \
            "Current location type: #{current_room.city_role || 'unknown'}"
          )
        end

        # Check if there's already a building here
        existing = Room.where(
          location_id: current_room.location_id,
          grid_x: current_room.grid_x,
          grid_y: current_room.grid_y,
          city_role: 'building'
        ).first

        if existing
          return error_result(
            "There's already a building at this intersection: #{existing.name}. " \
            "Use a different intersection."
          )
        end

        # Parse building type and optional layout
        input_text = (parsed_input[:text] || '').sub(/^(block|building)\s*/i, '').strip.downcase
        parts = input_text.split(/\s+/)

        building_type = nil
        layout = nil

        # Try to parse parts as building type and/or layout
        parts.each do |part|
          if building_type.nil? && BUILDING_TYPES[part]
            building_type = BUILDING_TYPES[part]
          elsif layout.nil? && LAYOUT_TYPES[part]
            layout = LAYOUT_TYPES[part]
          end
        end

        if building_type.nil?
          return show_building_menu
        end

        build_at_intersection(current_room, building_type, layout || :full)
      end

      # Handle quickmenu response
      def handle_quickmenu_response(selected_key, context)
        current_room = Room[context['room_id']]
        unless current_room
          return error_result('Room no longer exists.')
        end

        menu_type = context['menu_type'] || 'building'

        case menu_type
        when 'building'
          building_type = selected_key.to_sym
          unless BUILDING_TYPES.values.include?(building_type)
            return error_result("Invalid building type: #{selected_key}")
          end
          # Show layout menu after building type selection
          show_layout_menu(current_room, building_type)
        when 'layout'
          building_type = context['building_type']&.to_sym
          layout = selected_key.to_sym
          build_at_intersection(current_room, building_type, layout)
        else
          error_result('Unknown menu type')
        end
      end

      private

      def show_building_menu
        options = [
          # Residential
          { key: 'apartment_tower', label: 'Apartment Tower', description: 'Multi-floor residential building with apartments' },
          { key: 'condo_tower', label: 'Condo Tower', description: 'Multi-floor residential building with condos' },
          { key: 'brownstone', label: 'Brownstone', description: 'Classic 3-floor urban townhouse' },
          { key: 'house', label: 'House', description: 'Single-family home with 2 floors' },
          { key: 'terrace', label: 'Terrace House', description: 'Narrow 2-floor row house' },
          { key: 'townhouse', label: 'Townhouse', description: '3-floor attached home' },
          # Commercial
          { key: 'office_tower', label: 'Office Tower', description: 'Commercial office building' },
          { key: 'hotel', label: 'Hotel', description: 'Multi-floor accommodation' },
          { key: 'mall', label: 'Mall', description: 'Multi-level shopping center' },
          { key: 'shop', label: 'Shop', description: 'Small retail store' },
          { key: 'restaurant', label: 'Restaurant', description: 'Dining establishment' },
          { key: 'bar', label: 'Bar', description: 'Drinking establishment' },
          { key: 'cafe', label: 'Café', description: 'Coffee shop' },
          { key: 'gym', label: 'Gym', description: 'Fitness center' },
          { key: 'cinema', label: 'Cinema', description: 'Movie theater' },
          # Civic
          { key: 'church', label: 'Church', description: 'Place of worship' },
          { key: 'school', label: 'School', description: 'Educational building' },
          { key: 'hospital', label: 'Hospital', description: 'Medical center' },
          { key: 'library', label: 'Library', description: 'Public library' },
          { key: 'police_station', label: 'Police Station', description: 'Law enforcement' },
          { key: 'fire_station', label: 'Fire Station', description: 'Fire department' },
          # Recreation
          { key: 'park', label: 'Park', description: 'Green urban park space' },
          { key: 'plaza', label: 'Plaza', description: 'Open public square' },
          { key: 'garden', label: 'Garden', description: 'Landscaped garden' },
          # Infrastructure
          { key: 'parking_garage', label: 'Parking Garage', description: 'Multi-level parking' }
        ]

        create_quickmenu(
          character_instance,
          'What type of building do you want to create?',
          options,
          context: {
            command: 'build_block',
            room_id: location.id,
            menu_type: 'building'
          }
        )
      end

      def show_layout_menu(current_room, building_type)
        options = [
          { key: 'full', label: 'Full Block', description: 'Single building fills entire block' },
          { key: 'split_ns', label: 'Split N/S', description: 'Two buildings, north and south halves' },
          { key: 'split_ew', label: 'Split E/W', description: 'Two buildings, east and west halves' },
          { key: 'quadrants', label: 'Quadrants', description: 'Four buildings in corners' },
          { key: 'terrace_north', label: 'Row North', description: 'Row of terraces along north edge' },
          { key: 'terrace_south', label: 'Row South', description: 'Row of terraces along south edge' },
          { key: 'perimeter', label: 'Perimeter', description: 'Buildings around edges with courtyard' },
          { key: 'mixed_tower_shops', label: 'Mixed Use', description: 'Tower with corner shops' }
        ]

        create_quickmenu(
          character_instance,
          "Select a layout for the #{building_type.to_s.tr('_', ' ')}:",
          options,
          context: {
            command: 'build_block',
            room_id: current_room.id,
            menu_type: 'layout',
            building_type: building_type.to_s
          }
        )
      end

      def build_at_intersection(intersection_room, building_type, layout = :full)
        city_location = Location[intersection_room.location_id]
        unless city_location
          return error_result('Cannot find city location.')
        end

        # Build the block using the appropriate method based on layout
        begin
          if layout == :full
            # Simple single building
            rooms = BlockBuilderService.build_block(
              location: city_location,
              intersection_room: intersection_room,
              building_type: building_type
            )
          else
            # Use layout-based building
            rooms = BlockBuilderService.build_block_layout(
              location: city_location,
              intersection_room: intersection_room,
              layout: layout,
              building_assignments: generate_building_assignments(building_type, layout)
            )
          end
        rescue StandardError => e
          return error_result("Failed to build: #{e.message}")
        end

        if rooms.empty?
          return error_result('No buildings were created.')
        end

        building = rooms.first
        interior_count = rooms.length - 1
        building_count = rooms.count { |r| r.city_role == 'building' && r.building_type && !r.building_type.empty? }

        # Move to the first building entrance
        character_instance.update(current_room_id: building.id, x: 0.0, y: 0.0, z: 0.0)

        type_name = building_type.to_s.tr('_', ' ').capitalize
        layout_name = layout.to_s.tr('_', ' ')

        message = if layout == :full
                    "You have built a #{type_name} at #{intersection_room.name}!\n\n" \
                    "Created:\n" \
                    "  - #{building.name}\n" \
                    "  - #{interior_count} interior rooms\n\n" \
                    "You are now at the building entrance."
                  else
                    "You have built a #{layout_name} development at #{intersection_room.name}!\n\n" \
                    "Created:\n" \
                    "  - #{building_count} buildings\n" \
                    "  - #{rooms.length} total rooms\n\n" \
                    "You are now at #{building.name}."
                  end

        success_result(
          message,
          type: :action,
          data: {
            action: 'build_block',
            building_type: building_type.to_s,
            layout: layout.to_s,
            building_id: building.id,
            building_name: building.name,
            total_rooms: rooms.length,
            building_count: building_count,
            intersection_name: intersection_room.name
          }
        )
      end

      # Generate building assignments for each section of a layout
      def generate_building_assignments(building_type, layout)
        layout_config = GridCalculationService.block_layout(layout)
        assignments = {}

        layout_config[:sections].each_with_index do |section, idx|
          # For most layouts, use the specified building type
          # For special layouts like mixed_tower_shops, vary the types
          position = section[:position]

          case layout
          when :mixed_tower_shops
            # Central tower is the main type, corners are shops
            if position == :center_large
              assignments[position] = building_type
            else
              assignments[position] = :shop
            end
          when :perimeter
            # Perimeter gets shops, center gets courtyard or park
            if position == :center
              assignments[position] = :courtyard
            else
              assignments[position] = building_type
            end
          else
            # Default: all sections get the same building type
            assignments[position] = building_type
            assignments[idx] = building_type
          end
        end

        assignments
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Building::BuildBlock)
