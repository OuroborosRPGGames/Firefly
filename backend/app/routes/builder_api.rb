# frozen_string_literal: true

# Builder API endpoints for MCP building tools integration.
# All endpoints require admin authentication via Bearer token.
#
# Used by Claude Code for conversational world-building:
# - Map visualization (SVG rendering)
# - World/city/room CRUD operations
# - LLM-enhanced content generation
#
class BuilderApi < Roda
  include RouteHelpers

  plugin :json
  plugin :json_parser
  plugin :all_verbs

  route do |r|
    parse_boolean_param = lambda do |value, default:|
      case value
      when nil
        default
      when true, false
        value
      when String
        stripped = value.strip.downcase
        return true if %w[true 1 yes on].include?(stripped)
        return false if %w[false 0 no off].include?(stripped)
        default
      else
        default
      end
    end

    cleanup_generated_location = lambda do |location|
      next unless location

      Room.where(location_id: location.id).delete
      location.destroy
      RoomExitCacheService.invalidate_location!(location.id) if defined?(RoomExitCacheService)
    rescue StandardError => e
      warn "[BuilderApi] cleanup generated location #{location&.id} failed: #{e.message}"
    end

    response['Content-Type'] = 'application/json'

    # Authenticate via Bearer token and require admin
    char_instance = character_instance_from_token
    unless char_instance
      response.status = 401
      next { success: false, error: 'Unauthorized - valid Bearer token required' }.to_json
    end

    user = char_instance.character&.user
    unless user&.admin?
      response.status = 403
      next { success: false, error: 'Admin access required' }.to_json
    end

    # === WORLDS ===

    r.on 'worlds' do
      r.is do
        r.get do
          worlds = World.all.map do |w|
            {
              id: w.id,
              name: w.name,
              description: w.description,
              hex_count: WorldHex.where(world_id: w.id).count
            }
          end
          { success: true, worlds: worlds }.to_json
        end
      end

      r.on Integer do |world_id|
        world = World[world_id]
        unless world
          response.status = 404
          next { success: false, error: 'World not found' }.to_json
        end

        r.is do
          r.get do
            {
              success: true,
              world: {
                id: world.id,
                name: world.name,
                description: world.description,
                hex_count: WorldHex.where(world_id: world.id).count,
                terrain_stats: WorldHex.where(world_id: world.id)
                                       .group_and_count(:terrain_type)
                                       .map { |r| { terrain: r[:terrain_type], count: r[:count] } }
              }
            }.to_json
          end
        end

        r.on 'hexes' do
          r.get do
            # Get hex data for a region using lat/lon bounding box
            min_lat = r.params['min_lat']&.to_f || -90.0
            max_lat = r.params['max_lat']&.to_f || 90.0
            min_lon = r.params['min_lon']&.to_f || -180.0
            max_lon = r.params['max_lon']&.to_f || 180.0

            hexes = WorldHex.where(world_id: world.id)
                            .where { latitude >= min_lat }
                            .where { latitude <= max_lat }
                            .where { longitude >= min_lon }
                            .where { longitude <= max_lon }
                            .all.map do |h|
              {
                globe_hex_id: h.globe_hex_id,
                latitude: h.latitude,
                longitude: h.longitude,
                terrain: h.terrain_type,
                features: h.directional_features.merge(h.linear_features),
                elevation: h.elevation
              }
            end

            { success: true, hexes: hexes, bounds: { min_lat: min_lat, max_lat: max_lat, min_lon: min_lon, max_lon: max_lon } }.to_json
          end
        end

        r.on 'terrain' do
          r.post do
            # Set terrain for hex(es)
            hexes_data = r.params['hexes'] || []

            results = hexes_data.map do |hex_data|
              globe_hex_id = hex_data['globe_hex_id']&.to_i
              # Find or create the hex by globe_hex_id
              hex = WorldHex.find_or_create(
                world_id: world.id,
                globe_hex_id: globe_hex_id
              ) { |h| h.terrain_type = hex_data['terrain'] || 'grassy_plains' }

              # Update with any provided values
              updates = {}
              updates[:terrain_type] = hex_data['terrain'] if hex_data['terrain']
              updates[:elevation] = hex_data['elevation'] if hex_data['elevation']
              updates[:latitude] = hex_data['latitude'].to_f if hex_data['latitude']
              updates[:longitude] = hex_data['longitude'].to_f if hex_data['longitude']
              hex.update(updates) unless updates.empty?

              { globe_hex_id: globe_hex_id, updated: true }
            rescue StandardError => e
              { globe_hex_id: hex_data['globe_hex_id'], error: e.message }
            end

            { success: true, results: results }.to_json
          end
        end
      end
    end

    # === CITIES (Locations with city_built_at) ===

    r.on 'cities' do
      r.is do
        r.get do
          cities = Location.exclude(city_built_at: nil).all.map do |loc|
            {
              id: loc.id,
              name: loc.city_name || loc.name,
              world_id: loc.world_id,
              horizontal_streets: loc.horizontal_streets,
              vertical_streets: loc.vertical_streets,
              building_count: Room.where(location_id: loc.id, city_role: 'building').count
            }
          end
          { success: true, cities: cities }.to_json
        end
      end

      r.on Integer do |city_id|
        location = Location[city_id]
        unless location
          response.status = 404
          next { success: false, error: 'City not found' }.to_json
        end

        r.is do
          r.get do
            # Get city layout using the view service
            layout = CityBuilderViewService.build_city_view(location)
            { success: true, city: layout }.to_json
          end
        end

        r.on 'building' do
          r.post do
            # Create building at grid position
            grid_x = r.params['grid_x']&.to_i
            grid_y = r.params['grid_y']&.to_i
            building_type = r.params['building_type']&.to_sym || :shop
            name = r.params['name']

            # Find intersection at that grid position
            intersection = Room.where(location_id: location.id)
                               .where(room_type: 'intersection')
                               .where(grid_x: grid_x, grid_y: grid_y)
                               .first

            unless intersection
              response.status = 400
              next { success: false, error: "No intersection found at grid (#{grid_x}, #{grid_y})" }.to_json
            end

            # Build the building
            rooms = BlockBuilderService.build_block(
              location: location,
              intersection_room: intersection,
              building_type: building_type,
              options: { name: name }
            )

            {
              success: true,
              building: {
                id: rooms.first.id,
                name: rooms.first.name,
                room_type: rooms.first.room_type,
                interior_rooms: rooms[1..].map { |rm| { id: rm.id, name: rm.name } }
              }
            }.to_json
          rescue StandardError => e
            warn "[BuilderAPI] route error: #{e.message}"
            response.status = 500
            { success: false, error: e.message }.to_json
          end

          r.on Integer do |building_id|
            building = Room[building_id]
            unless building && building.location_id == location.id
              response.status = 404
              next { success: false, error: 'Building not found' }.to_json
            end

            r.delete do
              # Delete building and interior rooms, cleaning up associated records first
              location_id = building.location_id
              interior_rooms = building.contained_rooms
              interior_rooms.each do |rm|
                rm.cleanup_contents!
                rm.destroy
              end
              building.cleanup_contents!
              building.destroy
              RoomExitCacheService.invalidate_location!(location_id)

              { success: true, deleted: building_id, interior_count: interior_rooms.count }.to_json
            rescue StandardError => e
              warn "[BuilderAPI] route error: #{e.message}"
              response.status = 500
              { success: false, error: e.message }.to_json
            end
          end
        end
      end

      # Simple grid-only creation (no places/NPCs)
      r.on 'create' do
        r.post do
          location_id = r.params['location_id']&.to_i
          location = location_id ? Location[location_id] : nil
          location_created_here = false

          unless location
            world_id = r.params['world_id']&.to_i
            city_name = r.params['city_name']
            unless city_name && !city_name.strip.empty?
              response.status = 400
              next { success: false, error: 'city_name required when not using existing location' }.to_json
            end

            requested_zone_id = r.params['zone_id']&.to_i
            zone = requested_zone_id ? Zone[requested_zone_id] : nil
            if requested_zone_id && !zone
              response.status = 400
              next { success: false, error: "Zone #{requested_zone_id} not found" }.to_json
            end
            if zone && world_id && zone.world_id != world_id
              response.status = 400
              next { success: false, error: "Zone #{requested_zone_id} does not belong to world #{world_id}" }.to_json
            end

            zone ||= world_id ? Zone.where(world_id: world_id).first : Zone.first
            unless zone
              response.status = 400
              next { success: false, error: (world_id ? "No zones exist for world #{world_id} - create a zone first" : 'No zones exist - create a zone first') }.to_json
            end

            location = Location.create(
              name: city_name.strip,
              zone_id: zone.id,
              location_type: 'outdoor',
              world_id: world_id || zone.world_id
            )
            location_created_here = true
          end

          result = CityBuilderService.build_city(
            location: location,
            params: {
              city_name: r.params['city_name'] || location.name,
              horizontal_streets: r.params['horizontal_streets']&.to_i || 10,
              vertical_streets: r.params['vertical_streets']&.to_i || 10,
              max_building_height: r.params['max_building_height']&.to_i || 200
            }
          )

          if result[:success]
            {
              success: true,
              city_id: location.id,
              city_name: location.reload.city_name,
              horizontal_streets: location.horizontal_streets,
              vertical_streets: location.vertical_streets,
              streets: result[:street_names],
              avenues: result[:avenue_names],
              intersection_count: result[:intersections]&.count || 0
            }.to_json
          else
            cleanup_generated_location.call(location) if location_created_here
            response.status = 500
            { success: false, error: result[:error] }.to_json
          end
        end
      end

      # Full LLM-powered generation with places, buildings, and NPCs
      r.on 'generate' do
        r.post do
          # Parse options
          size = (r.params['size'] || 'village').to_sym
          setting = (r.params['setting'] || 'fantasy').to_sym
          generate_places = parse_boolean_param.call(r.params['generate_places'], default: true)
          create_buildings = parse_boolean_param.call(r.params['create_buildings'], default: false)
          generate_npcs = parse_boolean_param.call(r.params['generate_npcs'], default: false)

          # Seed terms for city character (from description)
          seed_terms = if r.params['description']
                         r.params['description'].split(/[\s,]+/).first(5)
                       else
                         []
                       end

          # Get or create location
          location = nil
          location_created_here = false
          if r.params['location_id']
            location = Location[r.params['location_id'].to_i]
            unless location
              response.status = 404
              next { success: false, errors: ['Location not found'] }.to_json
            end
          else
            # Create a temporary location - the generator will set the name
            world_id = r.params['world_id']&.to_i
            requested_zone_id = r.params['zone_id']&.to_i
            zone = requested_zone_id ? Zone[requested_zone_id] : nil
            if requested_zone_id && !zone
              response.status = 400
              next { success: false, errors: ["Zone #{requested_zone_id} not found"] }.to_json
            end
            if zone && world_id && zone.world_id != world_id
              response.status = 400
              next { success: false, errors: ["Zone #{requested_zone_id} does not belong to world #{world_id}"] }.to_json
            end
            zone ||= world_id ? Zone.where(world_id: world_id).first : Zone.first
            unless zone
              response.status = 400
              next { success: false, errors: [world_id ? "No zones exist for world #{world_id} - create a zone first" : 'No zones exist - create a zone first'] }.to_json
            end

            location = Location.create(
              name: 'Generated City',  # Will be updated by generator
              zone_id: zone.id,
              location_type: 'outdoor',
              world_id: world_id || zone.world_id
            )
            location_created_here = true
          end

          result = Generators::CityGeneratorService.generate(
            location: location,
            setting: setting,
            size: size,
            generate_places: generate_places,
            generate_place_rooms: true,
            create_buildings: create_buildings,
            generate_npcs: generate_npcs,
            options: { seed_terms: seed_terms }
          )

          if result[:success]
            # Reload location to get updated city_name
            location.reload if location

            {
              success: true,
              city_id: location&.id,
              city_name: result[:city_name] || location&.city_name,
              seed_terms: result[:seed_terms],
              streets: result[:streets],
              street_names: result[:street_names],
              avenue_names: result[:avenue_names],
              intersections: result[:intersections],
              places: result[:places],
              places_plan: result[:places_plan]&.map { |p| { type: p[:place_type], tier: p[:tier] } },
              errors: result[:errors]
            }.to_json
          else
            cleanup_generated_location.call(location) if location_created_here
            response.status = 500
            { success: false, errors: result[:errors] }.to_json
          end
        end
      end
    end

    # === ROOMS ===

    r.on 'rooms' do
      r.is do
        r.get do
          # List rooms with optional filters
          query = Room.dataset

          query = query.where(location_id: r.params['location_id'].to_i) if r.params['location_id']
          query = query.where(room_type: r.params['room_type']) if r.params['room_type']
          query = query.where(inside_room_id: r.params['inside_room_id'].to_i) if r.params['inside_room_id']

          requested_limit = r.params['limit']&.to_i
          limit = if requested_limit && requested_limit.positive?
                    [requested_limit, 200].min
                  else
                    50
                  end

          rooms = query.limit(limit).all.map do |rm|
            {
              id: rm.id,
              name: rm.name,
              room_type: rm.room_type,
              location_id: rm.location_id,
              location_name: rm.location&.name,
              inside_room_id: rm.inside_room_id
            }
          end

          { success: true, rooms: rooms, count: rooms.count }.to_json
        end
      end

      r.on Integer do |room_id|
        room = Room[room_id]
        unless room
          response.status = 404
          next { success: false, error: 'Room not found' }.to_json
        end

        r.is do
          r.get do
            # Get full room details
            { success: true, room: RoomBuilderService.room_to_api_hash(room) }.to_json
          end

          r.post do
            # Update room properties
            result = RoomBuilderService.update_room(room, r.params)
            result.to_json
          end
        end

        r.on 'place' do
          r.is do
            r.post do
              # Add furniture/place
              result = RoomBuilderService.create_place(room, r.params)
              result.to_json
            end
          end

          r.on Integer do |place_id|
            place = Place[place_id]
            unless place && place.room_id == room.id
              response.status = 404
              next { success: false, error: 'Place not found' }.to_json
            end

            r.post do
              result = RoomBuilderService.update_place(place, r.params)
              result.to_json
            end

            r.delete do
              place.destroy
              { success: true, deleted: place_id }.to_json
            rescue StandardError => e
              warn "[BuilderAPI] route error: #{e.message}"
              response.status = 500
              { success: false, error: e.message }.to_json
            end
          end
        end

        r.on 'exit' do
          legacy_error = {
            success: false,
            error: 'Room exit CRUD has been removed. Exits are spatial and derived from room geometry; use room features for doors/openings.'
          }

          r.is do
            r.post do
              response.status = 410
              legacy_error.to_json
            end
          end

          r.on Integer do |_exit_id|
            r.post do
              response.status = 410
              legacy_error.to_json
            end

            r.delete do
              response.status = 410
              legacy_error.to_json
            end
          end
        end

        r.on 'feature' do
          r.is do
            r.post do
              # Add door/window
              result = RoomBuilderService.create_feature(room, r.params)
              result.to_json
            end
          end

          r.on Integer do |feature_id|
            feature = RoomFeature[feature_id]
            unless feature && feature.room_id == room.id
              response.status = 404
              next { success: false, error: 'Feature not found' }.to_json
            end

            r.post do
              result = RoomBuilderService.update_feature(feature, r.params)
              result.to_json
            end

            r.delete do
              affected_location_ids = [room.location_id]
              if feature.connected_room_id
                connected = Room[feature.connected_room_id]
                affected_location_ids << connected&.location_id
              end

              feature.destroy
              affected_location_ids.compact.uniq.each do |location_id|
                RoomExitCacheService.invalidate_location!(location_id)
              end
              { success: true, deleted: feature_id }.to_json
            rescue StandardError => e
              warn "[BuilderAPI] route error: #{e.message}"
              response.status = 500
              { success: false, error: e.message }.to_json
            end
          end
        end

        r.on 'decoration' do
          r.post do
            result = RoomBuilderService.create_decoration(room, r.params)
            result.to_json
          end
        end

        r.on 'subroom' do
          r.post do
            result = RoomBuilderService.create_subroom(room, r.params)
            # Invalidation handled inside RoomBuilderService.create_subroom
            result.to_json
          end
        end
      end
    end

    # === MAP RENDERING ===

    r.on 'render_map' do
      r.post do
        map_type = r.params['type'] || 'room'
        target_id = r.params['target_id']&.to_i
        options = r.params['options'] || {}

        width = options['width']&.to_i || 800
        height = options['height']&.to_i || 600

        svg = case map_type
              when 'world'
                world = World[target_id]
                next { success: false, error: 'World not found' }.to_json unless world

                bounds = {
                  min_x: options['min_x']&.to_i || 0,
                  max_x: options['max_x']&.to_i || 20,
                  min_y: options['min_y']&.to_i || 0,
                  max_y: options['max_y']&.to_i || 20
                }
                MapSvgRenderService.render_world(world, bounds: bounds, width: width, height: height)

              when 'city'
                location = Location[target_id]
                next { success: false, error: 'City not found' }.to_json unless location

                MapSvgRenderService.render_city(location, width: width, height: height)

              when 'room', 'minimap'
                room = Room[target_id]
                next { success: false, error: 'Room not found' }.to_json unless room

                MapSvgRenderService.render_room(room, width: width, height: height)

              when 'battle'
                fight = Fight[target_id]
                next { success: false, error: 'Fight not found' }.to_json unless fight

                MapSvgRenderService.render_battle(fight, width: width, height: height)

              else
                next { success: false, error: "Unknown map type: #{map_type}" }.to_json
              end

        { success: true, svg: svg, format: 'svg', width: width, height: height }.to_json
      rescue StandardError => e
        warn "[BuilderApi] render_map error: #{e.message}"
        response.status = 500
        { success: false, error: e.message }.to_json
      end
    end

    # === GENERATION ENDPOINTS ===

    r.on 'generate' do
      r.on 'room_description' do
        r.post do
          room_id = r.params['room_id']&.to_i
          room = room_id ? Room[room_id] : nil
          setting = (r.params['setting'] || r.params['style'] || 'fantasy').to_sym

          context = {
            room_type: r.params['room_type'] || room&.room_type,
            building_type: r.params['building_type'],
            style: r.params['style'] || 'default',
            room_name: room&.name
          }

          description_result = if room
                                 Generators::RoomGeneratorService.generate_description(
                                   room: room,
                                   setting: setting
                                 )
                               else
                                 room_type = context[:room_type] || 'standard'
                                 titleized = room_type.to_s.split('_').map(&:capitalize).join(' ')
                                 room_name = context[:room_name] || "#{titleized} Room"
                                 Generators::RoomGeneratorService.generate_description_for_type(
                                   name: room_name,
                                   room_type: room_type,
                                   parent: { name: 'the area' },
                                   setting: setting,
                                   seed_terms: []
                                 )
                               end

          if description_result.is_a?(Hash)
            if description_result[:success]
              { success: true, description: description_result[:content] }.to_json
            else
              { success: false, error: description_result[:error] || 'Room description generation failed' }.to_json
            end
          else
            { success: true, description: description_result }.to_json
          end
        rescue StandardError => e
          warn "[BuilderApi] generate room_description error: #{e.message}"
          { success: false, error: e.message }.to_json
        end
      end

      r.on 'street_names' do
        r.post do
          location_id = r.params['location_id']&.to_i
          location = Location[location_id]

          unless location
            response.status = 400
            next { success: false, error: 'Location ID required' }.to_json
          end

          count = r.params['count']&.to_i || 10
          direction = r.params['direction']&.to_sym || :street

          names = StreetNameService.generate(
            location: location,
            count: count,
            direction: direction,
            use_llm: parse_boolean_param.call(r.params['use_llm'], default: true)
          )

          { success: true, names: names }.to_json
        rescue StandardError => e
          warn "[BuilderApi] generate street_names error: #{e.message}"
          { success: false, error: e.message }.to_json
        end
      end

      r.on 'building_name' do
        r.post do
          building_type = r.params['building_type']&.to_sym || :shop
          address = r.params['address']

          name = BlockBuilderService.generate_building_name(building_type, address)

          { success: true, name: name }.to_json
        rescue StandardError => e
          warn "[BuilderApi] generate building_name error: #{e.message}"
          { success: false, error: e.message }.to_json
        end
      end

      r.on 'populate_building' do
        r.post do
          room_id = r.params['room_id']&.to_i
          room = Room[room_id]

          unless room
            response.status = 400
            next { success: false, error: 'Room ID required' }.to_json
          end

          include_npcs = parse_boolean_param.call(r.params['include_npcs'], default: true)
          include_items = parse_boolean_param.call(r.params['include_items'], default: true)

          result = WorldBuilderOrchestratorService.populate_room(
            room: room,
            include_npcs: include_npcs,
            include_items: include_items
          )

          response.status = 500 unless result[:success]
          { success: result[:success], result: result }.to_json
        rescue StandardError => e
          warn "[BuilderApi] populate_building error: #{e.message}"
          { success: false, error: e.message }.to_json
        end
      end
    end
  end
end
