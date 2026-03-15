# frozen_string_literal: true

module Commands
  module Navigation
    class Map < Commands::Base::Command
      command_name 'map'
      aliases 'viewmap', 'maps'
      category :navigation
      output_category :info
      help_text 'View various maps of your surroundings'
      usage 'map [room|area|city|mini|battle]'
      examples 'map', 'map room', 'map area', 'map city', 'map mini', 'map battle'

      protected

      def perform_command(parsed_input)
        map_type = parsed_input[:text]&.strip&.downcase

        # Default to battle map when in a fight with no args
        if (map_type.nil? || map_type.empty?) && character_instance.in_combat?
          return show_battle_map
        end

        if map_type.nil? || map_type.empty?
          return show_map_menu
        end

        case map_type
        when 'room', 'interior', 'floorplan', 'rm'
          render_room_map
        when 'area', 'zone', 'hex', 'zonemap', 'nearby'
          render_zone_map
        when 'city', 'local', 'citymap'
          render_city_map
        when 'mini', 'minimap', 'toggle'
          toggle_minimap
        when 'battle', 'fight', 'combat', 'battlemap'
          show_battle_map
        else
          error_result("Unknown map type '#{map_type}'. Use: map room, map area, map city, map mini, map battle")
        end
      end

      private

      def show_map_menu
        options = [
          { key: 'room', label: 'Room Map', description: 'View interior of current room' },
          { key: 'area', label: 'Area Map', description: 'View surrounding hex terrain' },
          { key: 'city', label: 'City Map', description: 'View city/zone overview' },
          { key: 'mini', label: 'Toggle Minimap', description: 'Enable/disable persistent minimap' }
        ]

        create_quickmenu(
          character_instance,
          'Which map would you like to view?',
          options,
          context: { command: 'map' }
        )
      end

      # ========== Battle Map ==========
      def show_battle_map
        unless character_instance.in_combat?
          return error_result("You're not in combat. Use 'map room', 'map area', or 'map city' instead.")
        end

        success_result(
          'Showing battle map.',
          data: { action: 'show_battle_map' }
        )
      end

      # ========== Room Map ==========
      def render_room_map
        room = location
        return error_result("You're not in a room.") unless room

        if character_instance.blindfolded?
          return error_result("You can't see the room map while blindfolded.")
        end

        # Use the room map render service if available
        if defined?(RoommapRenderService)
          service = RoommapRenderService.new(
            room: room,
            viewer: character_instance
          )

          canvas_string = service.render

          success_result(
            canvas_string,
            type: :canvas,
            target_panel: Firefly::Panels::RIGHT_OBSERVE,
            data: {
              action: 'roommap',
              room_id: room.id,
              room_name: room.name,
              width: service.canvas_width,
              height: service.canvas_height
            }
          )
        else
          # Fallback to simpler canvas rendering
          render_simple_room_map(room)
        end
      end

      def render_simple_room_map(room)
        width = (room.max_x || 100) - (room.min_x || 0)
        height = (room.max_y || 100) - (room.min_y || 0)
        scale = calculate_scale(width, height)

        canvas = generate_room_canvas(room, width, height, scale)

        success_result(
          canvas,
          type: :canvas,
          target_panel: Firefly::Panels::RIGHT_OBSERVE,
          data: {
            action: 'map',
            map_type: 'room',
            room_id: room.id,
            room_name: room.name,
            width: (width * scale).to_i,
            height: (height * scale).to_i
          }
        )
      end

      # ========== Zone/Area Map ==========
      def render_zone_map
        room = location
        return error_result("You're not in a room.") unless room

        loc = room.location
        return error_result('This room has no location data.') unless loc

        unless loc.has_hex_coords? && loc.world_id
          return error_result(
            "This location doesn't have world coordinates. The zone map requires " \
            'a location with world coordinates (globe_hex_id and world_id) defined.'
          )
        end

        if loc.latitude.nil? || loc.longitude.nil?
          return error_result(
            "This location is missing map coordinates. The zone map requires both latitude and longitude."
          )
        end

        if character_instance.blindfolded?
          return error_result("You can't see the zone map while blindfolded.")
        end

        world = loc.world
        return error_result('This location has invalid world data.') unless world

        if defined?(ZonemapService)
          service = ZonemapService.new(
            world: world,
            center_x: loc.longitude,
            center_y: loc.latitude,
            current_location: loc
          )

          svg_string = service.render

          success_result(
            svg_string,
            type: :svg,
            target_panel: Firefly::Panels::RIGHT_OBSERVE,
            data: {
              action: 'zonemap',
              svg: svg_string,
              location_id: loc.id,
              location_name: loc.name,
              world_id: world.id,
              world_name: world.name,
              center_x: loc.longitude,
              center_y: loc.latitude,
              grid_size: ZonemapService::GRID_SIZE,
              width: ZonemapService::CANVAS_SIZE,
              height: ZonemapService::CANVAS_SIZE
            }
          )
        else
          error_result("Zone map service not available.")
        end
      end

      # ========== City Map ==========
      def render_city_map
        loc = location.location
        return error_result("You're not in a location.") unless loc

        result = CityMapRenderService.render(viewer: character_instance, mode: :city)

        success_result(
          result[:svg],
          type: :svg,
          target_panel: Firefly::Panels::RIGHT_OBSERVE,
          data: {
            action: 'citymap',
            svg: result[:svg],
            location_id: loc.id,
            location_name: loc.city_name || loc.name
          }.merge(result[:metadata] || {})
        )
      rescue ArgumentError => e
        error_result(e.message)
      rescue StandardError => e
        warn "[Map] City map render failed: #{e.message}"
        error_result("Failed to render city map.")
      end

      # ========== Minimap Toggle ==========
      def toggle_minimap
        character_instance.toggle_minimap!
        now_enabled = character_instance.minimap_enabled?

        msg = now_enabled ? "Minimap enabled." : "Minimap disabled."

        success_result(
          msg,
          target_panel: Firefly::Panels::LEFT_MINIMAP,
          data: {
            action: 'minimap',
            enabled: now_enabled
          }
        )
      end

      # ========== Helper Methods ==========
      def calculate_scale(width, height)
        max_dim = [width, height].max
        return 3.0 if max_dim < 50
        return 2.0 if max_dim < 100
        return 1.5 if max_dim < 200

        300.0 / max_dim
      end

      def generate_room_canvas(room, width, height, scale)
        sw = (width * scale).to_i
        sh = (height * scale).to_i
        commands = []

        # Draw room boundary
        commands << "line::0,0,#{sw},0"
        commands << "line::0,0,0,#{sh}"
        commands << "line::#{sw},#{sh},#{sw},0"
        commands << "line::#{sw},#{sh},0,#{sh}"

        # Draw exits as openings (from spatial adjacency)
        drawn_directions = Set.new
        room.spatial_exits.each do |direction, _rooms|
          next if drawn_directions.include?(direction.to_s)

          drawn_directions << direction.to_s
          commands << draw_exit(OpenStruct.new(direction: direction.to_s), sw, sh)
        end

        # Draw places (furniture)
        places_in_room.each do |place|
          commands << draw_place(place, room, scale)
        end

        # Draw other characters
        characters_in_room.each do |ci|
          next if ci.id == character_instance.id

          commands << draw_character(ci, room, scale)
        end

        # Draw self as marker
        commands << draw_self(room, scale)

        # Draw room name
        commands << "text::#{sw / 2},#{sh - 5}||Georgia||#{room.name}"

        "#{sw}|||#{sh}|||#{commands.compact.join(';;;')}"
      end

      def draw_exit(exit, sw, sh)
        case exit.direction
        when 'north', 'n'
          "rect::#{sw / 2 - 10},0,#{sw / 2 + 10},3"
        when 'south', 's'
          "rect::#{sw / 2 - 10},#{sh - 3},#{sw / 2 + 10},#{sh}"
        when 'east', 'e'
          "rect::#{sw - 3},#{sh / 2 - 10},#{sw},#{sh / 2 + 10}"
        when 'west', 'w'
          "rect::0,#{sh / 2 - 10},3,#{sh / 2 + 10}"
        when 'up', 'u'
          "text::#{sw - 20},10||Georgia||UP"
        when 'down', 'd'
          "text::#{sw - 25},#{sh - 10}||Georgia||DOWN"
        end
      end

      def draw_place(place, room, scale)
        px = ((place.x || 50) - (room.min_x || 0)) * scale
        py = ((room.max_y || 100) - (place.y || 50)) * scale

        "frect::#663300,#{(px - 10).to_i},#{(py - 5).to_i},#{(px + 10).to_i},#{(py + 5).to_i}"
      end

      def draw_character(ci, room, scale)
        cx = ((ci.x || 50) - (room.min_x || 0)) * scale
        cy = ((room.max_y || 100) - (ci.y || 50)) * scale

        "fcircle::#22cc22,#{cx.to_i},#{cy.to_i},4"
      end

      def draw_self(room, scale)
        cx = ((character_instance.x || 50) - (room.min_x || 0)) * scale
        cy = ((room.max_y || 100) - (character_instance.y || 50)) * scale

        "fcircle::#ff4444,#{cx.to_i},#{cy.to_i},6"
      end

      def places_in_room
        Place.where(room_id: character_instance.current_room_id).all
      rescue StandardError => e
        warn "[Map] Error fetching places: #{e.message}"
        []
      end

      def characters_in_room
        room = character_instance.current_room
        room.characters_here(character_instance.reality_id, viewer: character_instance)
            .exclude(id: character_instance.id)
            .all
      rescue StandardError => e
        warn "[Map] Error fetching characters: #{e.message}"
        []
      end
    end
  end
end

Commands::Base::Registry.register(Commands::Navigation::Map)
