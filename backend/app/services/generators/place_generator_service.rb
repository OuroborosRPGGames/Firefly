# frozen_string_literal: true

require_relative '../../../lib/core_extensions'

module Generators
  # PlaceGeneratorService generates complete places (shops, buildings) with rooms and NPCs
  #
  # Can generate:
  # - Place names (via NameGeneratorService + LLM selection)
  # - Building layouts (room configurations)
  # - Interior room descriptions
  # - Shop inventories
  # - Resident/worker NPCs
  #
  # @example Generate a tavern
  #   result = Generators::PlaceGeneratorService.generate(
  #     location: city_location,
  #     place_type: :tavern,
  #     setting: :fantasy
  #   )
  #
  # @example Generate place name only
  #   result = Generators::PlaceGeneratorService.generate_name(
  #     place_type: :blacksmith,
  #     setting: :fantasy
  #   )
  #
  class PlaceGeneratorService
    ROOM_DESC_THREAD_TIMEOUT = 120

    # Place types and their typical room configurations
    PLACE_TYPES = {
      # Service establishments
      tavern: {
        rooms: %w[common_room kitchen storage cellar],
        optional_rooms: %w[private_room upstairs_hall guest_room],
        npc_roles: %w[innkeeper barkeep server cook],
        shop_type: nil
      },
      inn: {
        rooms: %w[lobby common_room kitchen],
        optional_rooms: %w[guest_room guest_room guest_room storage cellar],
        npc_roles: %w[innkeeper server housekeeper],
        shop_type: nil
      },
      restaurant: {
        rooms: %w[dining_room kitchen storage],
        optional_rooms: %w[private_dining pantry],
        npc_roles: %w[proprietor server cook],
        shop_type: nil
      },

      # Shops
      blacksmith: {
        rooms: %w[forge showroom storage],
        optional_rooms: %w[back_room living_quarters],
        npc_roles: %w[blacksmith apprentice],
        shop_type: :blacksmith
      },
      apothecary: {
        rooms: %w[shop_floor preparation_room storage],
        optional_rooms: %w[garden living_quarters],
        npc_roles: %w[apothecary assistant],
        shop_type: :apothecary
      },
      clothier: {
        rooms: %w[showroom fitting_room workroom storage],
        optional_rooms: %w[living_quarters],
        npc_roles: %w[tailor assistant],
        shop_type: :clothier
      },
      jeweler: {
        rooms: %w[showroom workshop vault],
        optional_rooms: %w[office living_quarters],
        npc_roles: %w[jeweler guard],
        shop_type: :jeweler
      },
      general_store: {
        rooms: %w[shop_floor storage],
        optional_rooms: %w[office back_room],
        npc_roles: %w[shopkeeper assistant],
        shop_type: :general
      },

      # Civic buildings
      guild_hall: {
        rooms: %w[main_hall meeting_room office archive],
        optional_rooms: %w[vault training_room quarters],
        npc_roles: %w[guild_master clerk guard],
        shop_type: nil
      },
      temple: {
        rooms: %w[sanctuary altar_room meditation_chamber],
        optional_rooms: %w[library quarters garden crypt],
        npc_roles: %w[priest acolyte],
        shop_type: nil
      },
      bank: {
        rooms: %w[lobby vault_entrance office],
        optional_rooms: %w[private_vault meeting_room],
        npc_roles: %w[banker clerk guard],
        shop_type: nil
      },
      library: {
        rooms: %w[reading_room stacks archive],
        optional_rooms: %w[rare_books office study_room],
        npc_roles: %w[librarian scribe],
        shop_type: nil
      },

      # Residential
      townhouse: {
        rooms: %w[entry_hall parlor kitchen],
        optional_rooms: %w[dining_room bedroom bedroom study],
        npc_roles: %w[servant],
        shop_type: nil
      },
      mansion: {
        rooms: %w[grand_foyer ballroom dining_hall kitchen],
        optional_rooms: %w[study library bedroom bedroom bedroom servant_quarters],
        npc_roles: %w[butler maid guard],
        shop_type: nil
      },

      # Industrial
      warehouse: {
        rooms: %w[main_floor loading_dock office],
        optional_rooms: %w[storage storage basement],
        npc_roles: %w[foreman laborer guard],
        shop_type: nil
      }
    }.freeze

    # Map place types to BlockBuilderService building types
    BUILDING_TYPE_MAP = {
      tavern: :bar,
      inn: :hotel,
      restaurant: :restaurant,
      blacksmith: :shop,
      apothecary: :shop,
      clothier: :shop,
      jeweler: :shop,
      general_store: :shop,
      guild_hall: :government,
      temple: :temple,
      bank: :government,
      library: :library,
      townhouse: :townhouse,
      mansion: :house,
      warehouse: :warehouse,
      cinema: :cinema,
      gym: :gym,
      mall: :mall,
      parking_garage: :parking_garage,
      fire_station: :fire_station,
      police_station: :police_station,
      school: :school,
      hospital: :hospital,
      hotel: :hotel,
      cafe: :cafe,
      bar: :bar
    }.freeze

    class << self
      # Generate a complete place
      # @param location [Location, nil] where to create the place (OR use coordinates)
      # @param longitude [Float, nil] longitude for new location
      # @param latitude [Float, nil] latitude for new location
      # @param place_type [Symbol] type of place
      # @param parent_room [Room, nil] parent room to connect to (intersection/street)
      # @param setting [Symbol] world setting
      # @param generate_rooms [Boolean] whether to generate room descriptions
      # @param create_building [Boolean] whether to create actual Room records in database
      # @param generate_npcs [Boolean] whether to generate NPCs
      # @param generate_inventory [Boolean] whether to generate shop inventory
      # @param options [Hash] additional options
      # @return [Hash] { success:, place:, building:, rooms:, npcs:, errors: }
      def generate(location: nil, longitude: nil, latitude: nil, place_type:, parent_room: nil, setting: :fantasy,
                   generate_rooms: true, create_building: false, generate_npcs: false,
                   generate_inventory: false, generate_furniture: false, name: nil, options: {})
        results = { success: false, errors: [] }
        place_type = place_type.to_sym

        config = PLACE_TYPES[place_type]
        unless config
          return results.merge(error: "Unknown place type: #{place_type}")
        end

        # Get seed terms (5 terms, LLM picks 1-2)
        seed_terms = options[:seed_terms] || SeedTermService.for_generation(:place, count: 5)
        results[:seed_terms] = seed_terms

        # Use pre-assigned name or generate one
        place_name = nil
        if name
          place_name = name
        else
          name_result = generate_name(
            place_type: place_type,
            setting: setting,
            seed_terms: seed_terms
          )

          unless name_result[:success]
            results[:errors] << name_result[:error]
            return results
          end
          place_name = name_result[:name]
        end
        results[:name] = place_name

        # Resolve location from coordinates if not provided
        if location.nil?
          if longitude.nil? || latitude.nil?
            results[:errors] << 'Either location or coordinates (longitude, latitude) must be provided'
            return results
          end

          location_result = LocationResolverService.resolve(
            longitude: longitude,
            latitude: latitude,
            name: place_name,
            location_type: 'building',
            options: {
              area_name: options[:area_name] || "#{place_name} Area",
              area_type: 'city'
            }
          )

          unless location_result[:success]
            results[:errors] << "Failed to create location: #{location_result[:error]}"
            return results
          end

          location = location_result[:location]
          results[:location_created] = location_result[:created]
          results[:location_id] = location.id
        end

        # Plan room layout
        layout = plan_layout(
          place_type: place_type,
          config: config,
          size: options[:size] || :standard,
          setting: setting
        )
        results[:layout] = layout

        # Generate room descriptions if requested (always do this before creating rooms)
        if generate_rooms || create_building
          rooms_result = generate_room_descriptions(
            place_name: place_name,
            place_type: place_type,
            layout: layout,
            setting: setting,
            seed_terms: seed_terms
          )

          results[:room_descriptions] = rooms_result[:descriptions]
          results[:errors].concat(rooms_result[:errors])
        end

        # Create actual Room records if requested
        if create_building
          building_result = create_building_rooms(
            location: location,
            parent_room: parent_room,
            place_name: place_name,
            place_type: place_type,
            layout: layout,
            room_descriptions: results[:room_descriptions] || {},
            setting: setting,
            options: options
          )

          results[:building] = building_result[:building]
          results[:rooms] = building_result[:rooms]
          results[:errors].concat(building_result[:errors])
        end

        # Generate NPCs if requested
        if generate_npcs
          npcs_result = generate_place_npcs(
            place_name: place_name,
            place_type: place_type,
            npc_roles: config[:npc_roles],
            location: location,
            rooms: results[:rooms],
            setting: setting
          )

          results[:npcs] = npcs_result[:npcs]
          results[:errors].concat(npcs_result[:errors])
        end

        # Generate inventory if this is a shop
        if generate_inventory && config[:shop_type]
          # Use the first room (main shop floor) for the shop record
          shop_room = results[:rooms]&.first
          inventory_result = generate_shop_inventory(
            shop_type: config[:shop_type],
            place_name: place_name,
            room: shop_room,
            setting: setting,
            persist: create_building && shop_room
          )

          results[:shop] = inventory_result[:shop]
          results[:inventory] = inventory_result[:items]
          results[:errors].concat(inventory_result[:errors]) if inventory_result[:errors]&.any?
        end

        # Generate furniture/places and decorations if requested
        if generate_furniture && create_building && results[:rooms]&.any?
          furniture_result = generate_room_furniture(
            place_type: place_type,
            rooms: results[:rooms],
            layout: layout,
            setting: setting
          )

          results[:furniture] = furniture_result[:furniture]
          results[:decorations] = furniture_result[:decorations]
          results[:errors].concat(furniture_result[:errors]) if furniture_result[:errors]&.any?

          # Generate room features (doors, windows) after furniture
          features_result = generate_room_features(
            place_type: place_type,
            rooms: results[:rooms],
            layout: layout,
            setting: setting
          )
          results[:room_features] = features_result[:features]
          results[:errors].concat(features_result[:errors]) if features_result[:errors]&.any?
        end

        results[:success] = !results[:name].nil? && !results[:layout].nil?
        results
      end

      # Generate place name using NameGeneratorService + LLM selection
      # @param place_type [Symbol] type of place
      # @param setting [Symbol] world setting
      # @param seed_terms [Array<String>]
      # @return [Hash] { success:, name:, error: }
      def generate_name(place_type:, setting: :fantasy, seed_terms: [])
        # Map place type to shop generator type
        shop_type = map_place_to_shop_type(place_type)

        begin
          # Get multiple name options
          options = NameGeneratorService.shop_options(
            count: 5,
            shop_type: shop_type,
            setting: setting
          )

          if options.empty?
            return { success: false, error: 'No name options generated' }
          end

          # Format for LLM selection
          name_strings = options.map(&:name)

          # Use LLM to select best name
          selection_result = GenerationPipelineService.select_best_name(
            options: name_strings,
            context: {
              place_type: place_type.to_s.tr('_', ' '),
              setting: setting,
              vibe: seed_terms.first(2).join(', ')
            }
          )

          {
            success: true,
            name: selection_result[:selected] || name_strings.first,
            alternatives: name_strings,
            reasoning: selection_result[:reasoning]
          }
        rescue StandardError => e
          { success: false, error: "Name generation failed: #{e.message}" }
        end
      end

      # Plan room layout for a place
      # @param place_type [Symbol]
      # @param config [Hash] place configuration
      # @param size [Symbol] :small, :standard, :large
      # @param setting [Symbol]
      # @return [Array<Hash>] room layout plan
      def plan_layout(place_type:, config:, size: :standard, setting: :fantasy)
        required = config[:rooms]
        optional = config[:optional_rooms] || []

        # Determine how many optional rooms based on size
        optional_count = case size
                         when :small then 0
                         when :standard then [optional.length / 2, 1].max
                         when :large then optional.length
                         else 1
                         end

        # Select optional rooms
        selected_optional = optional.sample(optional_count)

        # Build layout with room details
        all_rooms = required + selected_optional

        # First pass: assign floors
        rooms_with_floors = all_rooms.map.with_index do |room_type, index|
          {
            room_type: room_type,
            floor: calculate_floor(room_type, index, all_rooms.length),
            main_room: required.include?(room_type)
          }
        end

        # Second pass: assign floor-relative positions
        # Track position counter per floor
        floor_positions = Hash.new(0)
        rooms_with_floors.map do |room_info|
          floor = room_info[:floor]
          position = floor_positions[floor]
          floor_positions[floor] += 1
          room_info.merge(position: position)
        end
      end

      # Generate descriptions for all rooms in layout
      # @param place_name [String]
      # @param place_type [Symbol]
      # @param layout [Array<Hash>]
      # @param setting [Symbol]
      # @param seed_terms [Array<String>]
      # @return [Hash] { descriptions: {room_type: desc}, errors: }
      def generate_room_descriptions(place_name:, place_type:, layout:, setting: :fantasy, seed_terms: [])
        results = { descriptions: {}, errors: [] }

        # Generate all room descriptions in parallel
        threads = layout.map do |room_info|
          Thread.new(room_info) do |ri|
            room_type = ri[:room_type]
            Thread.current[:room_type] = room_type
            Thread.current[:result] = RoomGeneratorService.generate_description_for_type(
              name: format_room_name(room_type, place_name),
              room_type: map_to_room_type(room_type),
              parent: { name: place_name },
              setting: setting,
              seed_terms: seed_terms,
              options: {}
            )
          end
        end

        threads.each { |t| t.join(ROOM_DESC_THREAD_TIMEOUT) }

        threads.each do |t|
          room_type = t[:room_type]
          if t.alive?
            t.kill
            results[:errors] << "#{room_type || 'unknown'}: generation timed out"
            next
          end

          desc_result = t[:result]
          unless desc_result
            results[:errors] << "#{room_type || 'unknown'}: no generation result returned"
            next
          end

          if desc_result[:success] || desc_result[:content]
            results[:descriptions][room_type] = desc_result[:content]
          else
            results[:errors] << "#{room_type}: #{desc_result[:error]}"
          end
        end

        results
      end

      # Generate NPCs for the place and optionally create database records
      # @param place_name [String]
      # @param place_type [Symbol]
      # @param npc_roles [Array<String>]
      # @param location [Location]
      # @param rooms [Array<Room>, nil] rooms to place NPCs in (first room used as default)
      # @param setting [Symbol]
      # @param persist [Boolean] whether to create database records (default: true)
      # @return [Hash] { npcs: [{character:, instance:, role:, name:}], errors: }
      def generate_place_npcs(place_name:, place_type:, npc_roles:, location:, rooms: nil, setting: :fantasy, persist: true)
        results = { npcs: [], errors: [] }

        # Get or create a default reality for spawning (only if persisting)
        reality = nil
        spawn_room = nil
        if persist
          reality = Reality.first(reality_type: 'primary') || Reality.first
          spawn_room = rooms&.first
          # Try to find a spawn room from the location if not provided
          if spawn_room.nil? && location.respond_to?(:rooms_dataset)
            spawn_room = location.rooms_dataset.where(city_role: 'building').first
          end
        end

        # Generate all NPCs in parallel
        threads = npc_roles.map do |role|
          Thread.new(role) do |r|
            Thread.current[:role] = r
            Thread.current[:result] = NPCGeneratorService.generate(
              location: location,
              role: r,
              setting: setting,
              generate_portrait: false,
              generate_schedule: true
            )
          end
        end

        threads.each { |t| t.join(300) }

        # Collect results and persist sequentially (DB writes not parallelized)
        threads.each do |t|
          role = t[:role]
          npc_result = t[:result]

          unless npc_result
            results[:errors] << "NPC #{role}: generation timed out"
            next
          end

          if npc_result[:success]
            name_data = npc_result[:name] || {}
            full_name = name_data[:full_name] || 'Unknown NPC'
            forename = name_data[:forename] || full_name.split.first || 'Unknown'
            surname = name_data[:surname] || full_name.split[1..].join(' ')

            character = nil
            instance = nil

            if persist && reality
              begin
                character = Character.create(
                  name: full_name,
                  forename: forename,
                  surname: surname.to_s.strip.empty? ? nil : surname,
                  session_id: SecureRandom.hex(16),
                  gender: name_data[:gender_used]&.to_s || 'neutral',
                  is_npc: true,
                  short_desc: npc_result[:short_desc] || build_npc_short_desc(npc_result[:appearance], name_data[:gender_used]),
                  personality: npc_result[:personality],
                  home_room_id: spawn_room&.id
                )

                if spawn_room && character
                  instance = CharacterInstance.create(
                    character_id: character.id,
                    reality_id: reality.id,
                    current_room_id: spawn_room.id,
                    level: 1,
                    health: 100,
                    max_health: 100,
                    mana: 50,
                    max_mana: 50,
                    online: true,
                    status: 'alive',
                    stance: 'standing'
                  )
                end
              rescue StandardError => e
                results[:errors] << "NPC #{role} creation failed: #{e.message}"
              end
            end

            results[:npcs] << {
              character: character,
              instance: instance,
              role: role,
              name: full_name,
              appearance: npc_result[:appearance],
              personality: npc_result[:personality],
              schedule: npc_result[:schedule]
            }
          else
            results[:errors] << "NPC #{role}: #{npc_result[:errors].join(', ')}"
          end
        end

        results
      end

      # Generate shop inventory from existing patterns
      # @param shop_type [Symbol] Type of shop (:blacksmith, :apothecary, :clothier, :jeweler, :general)
      # @param place_name [String] Name for the shop
      # @param room [Room, nil] Room to create shop in (required if persist: true)
      # @param setting [Symbol] Game setting (unused, for future AI generation)
      # @param persist [Boolean] Whether to create database records
      # @return [Hash] { shop:, items: [Hash], errors: [] }
      def generate_shop_inventory(shop_type:, place_name:, room: nil, setting: :fantasy, persist: true)
        results = { shop: nil, items: [], errors: [] }

        # Get patterns for this shop type
        patterns = patterns_for_shop_type(shop_type)
        if patterns.empty?
          results[:errors] << "No patterns found for shop type: #{shop_type}"
          return results
        end

        # Select 5-10 random patterns for inventory
        selected_patterns = patterns.sample(rand(5..10))

        # Create Shop record if persisting
        shop = nil
        if persist && room
          begin
            # Check if shop already exists for this room
            existing_shop = Shop.first(room_id: room.id)
            if existing_shop
              results[:shop] = existing_shop
              shop = existing_shop
            else
              shop = Shop.create(
                room_id: room.id,
                name: place_name,
                shopkeeper_name: "#{place_name} Keeper",
                is_open: true
              )
              results[:shop] = shop
            end
          rescue StandardError => e
            results[:errors] << "Shop creation failed: #{e.message}"
            warn "[PlaceGeneratorService] Shop creation failed: #{e.message}"
            return results
          end
        end

        # Create ShopItem records for each pattern
        selected_patterns.each do |pattern|
          item_data = {
            pattern_id: pattern.id,
            description: pattern.description.to_s[0..100],
            price: (pattern.price && pattern.price.positive?) ? pattern.price.to_i : rand(5..50),
            stock: rand(3..15)
          }

          if persist && shop
            begin
              # Check if this pattern is already in the shop
              existing_item = ShopItem.first(shop_id: shop.id, pattern_id: pattern.id)
              unless existing_item
                ShopItem.create(
                  shop_id: shop.id,
                  pattern_id: pattern.id,
                  price: item_data[:price],
                  stock: item_data[:stock]
                )
              end
            rescue StandardError => e
              results[:errors] << "ShopItem creation failed: #{e.message}"
              warn "[PlaceGeneratorService] ShopItem creation failed: #{e.message}"
            end
          end

          results[:items] << item_data
        end

        results
      end

      # Get patterns appropriate for a shop type using unified_object_type categories
      # @param shop_type [Symbol]
      # @return [Array<Pattern>]
      def patterns_for_shop_type(shop_type)
        categories = case shop_type.to_sym
                     when :blacksmith
                       # Weapons
                       %w[Sword Knife Firearm]
                     when :apothecary, :general, :tavern, :inn, :bar, :restaurant
                       # Consumables (food, drink, etc.)
                       %w[consumable]
                     when :clothier
                       # Clothing
                       %w[Top Pants Dress Skirt Underwear Outerwear Swimwear Fullbody Shoes Accessory]
                     when :jeweler
                       # Jewelry
                       %w[Ring Necklace Bracelet Piercing]
                     else
                       # Default to consumables
                       %w[consumable]
                     end

        Pattern.join(:unified_object_types, id: :unified_object_type_id)
               .where(Sequel[:unified_object_types][:category] => categories)
               .select_all(:patterns)
               .all
      end

      # Generate furniture (places) and decorations for rooms
      # @param place_type [Symbol]
      # @param rooms [Array<Room>]
      # @param layout [Array<Hash>]
      # @param setting [Symbol]
      # @return [Hash] { furniture: [], decorations: [], errors: [] }
      def generate_room_furniture(place_type:, rooms:, layout:, setting: :fantasy)
        results = { furniture: [], decorations: [], errors: [] }

        rooms.each_with_index do |room, index|
          room_info = layout[index]
          room_type = room_info&.dig(:room_type) || room.room_type

          # Get furniture templates for this room type
          furniture_specs = furniture_for_room_type(room_type, place_type)

          # Pre-calculate distributed positions to avoid clustering
          positions = distribute_furniture_positions(
            count: furniture_specs.length,
            min_x: (room.min_x || 0).to_i,
            max_x: (room.max_x || 100).to_i,
            min_y: (room.min_y || 0).to_i,
            max_y: (room.max_y || 100).to_i
          )

          furniture_specs.each_with_index do |spec, fi|
            begin
              pos = positions[fi] || positions.last || { x: (room.min_x.to_i + room.max_x.to_i) / 2, y: (room.min_y.to_i + room.max_y.to_i) / 2 }

              place = Place.create(
                room_id: room.id,
                name: spec[:name],
                description: spec[:description],
                x: spec[:x] || pos[:x],
                y: spec[:y] || pos[:y],
                z: 0,
                capacity: spec[:capacity] || 1,
                is_furniture: true,
                invisible: false,
                default_sit_action: spec[:sit_action] || 'on'
              )
              results[:furniture] << { room_id: room.id, place_id: place.id, name: place.name }
            rescue StandardError => e
              results[:errors] << "Furniture creation failed in #{room.name}: #{e.message}"
            end
          end

          # Get decoration templates for this room type
          decoration_specs = decorations_for_room_type(room_type, place_type, setting)

          decoration_specs.each do |spec|
            begin
              decoration = Decoration.create(
                room_id: room.id,
                name: spec[:name],
                description: spec[:description],
                display_order: spec[:display_order] || 0
              )
              results[:decorations] << { room_id: room.id, decoration_id: decoration.id, name: decoration.name }
            rescue StandardError => e
              results[:errors] << "Decoration creation failed in #{room.name}: #{e.message}"
            end
          end
        end

        results
      end

      # Tool schema for LLM-driven room feature generation
      # Uses wall + wall_position (percentage) for wall-mounted features,
      # and floor_x/floor_y (percentage) for floor features like hatches and stairs.
      FEATURE_TOOL_SCHEMA = {
        type: 'object',
        properties: {
          features: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                feature_type: { type: 'string', enum: %w[door window opening archway gate hatch stairs] },
                name: { type: 'string' },
                description: { type: 'string' },
                wall: { type: 'string', enum: %w[north south east west], description: 'Which wall this feature is on (for doors, windows, openings, archways, gates)' },
                wall_position: { type: 'integer', description: 'Position along the wall as percentage 0-100 (for wall-mounted features)' },
                floor_x: { type: 'integer', description: 'X position as percentage 0-100 of room width (for floor features like hatches and stairs)' },
                floor_y: { type: 'integer', description: 'Y position as percentage 0-100 of room depth (for floor features like hatches and stairs)' },
                allows_movement: { type: 'boolean' },
                allows_sight: { type: 'boolean' },
                has_curtains: { type: 'boolean' },
                has_lock: { type: 'boolean' }
              },
              required: %w[feature_type name description]
            }
          }
        },
        required: ['features']
      }.freeze

      # Feature types that go on the floor rather than walls
      FLOOR_FEATURES = %w[hatch stairs].freeze

      # Generate room features (doors, windows, openings) for rooms using LLM tool_use
      # @param place_type [Symbol]
      # @param rooms [Array<Room>]
      # @param layout [Array<Hash>]
      # @param setting [Symbol]
      # @return [Hash] { features: [], errors: [] }
      def generate_room_features(place_type:, rooms:, layout:, setting: :fantasy)
        results = { features: [], errors: [] }

        rooms.each_with_index do |room, index|
          room_info = layout[index]
          room_type = room_info&.dig(:room_type) || room.room_type
          environment = room_environment(room_type, room_info)

          # Outdoor rooms have no walls, so no doors/windows/openings
          next if environment == 'outdoor'

          min_x = room.min_x.to_i
          max_x = room.max_x.to_i
          min_y = room.min_y.to_i
          max_y = room.max_y.to_i

          # Build prompt from prompts.yml
          prompt = GamePrompts.get('room_generation.features',
            room_name: room.name,
            room_type: room_type,
            setting: setting,
            environment: environment,
            description: room.long_description.to_s[0..200],
            min_x: min_x, max_x: max_x,
            min_y: min_y, max_y: max_y,
            width_ft: max_x - min_x,
            height_ft: max_y - min_y
          )

          # Use generate_structured for LLM-driven door/window/opening generation
          llm_result = GenerationPipelineService.generate_structured(
            prompt: prompt,
            tool_name: 'describe_room_openings',
            tool_description: 'Describe the doors, windows, and openings in a room',
            parameters: FEATURE_TOOL_SCHEMA
          )

          feature_specs = if llm_result[:success] && llm_result[:data].is_a?(Hash)
                            Array(llm_result[:data]['features'])
                          else
                            results[:errors] << "LLM features failed for #{room.name}: #{llm_result[:error]}"
                            default_room_features(room_type, environment, min_x, max_x, min_y, max_y)
                          end

          # Create RoomFeature records from specs
          feature_specs.each do |spec|
            begin
              ft = sanitize_feature_type(spec['feature_type'] || spec[:feature_type])

              if FLOOR_FEATURES.include?(ft)
                # Floor features (hatches, stairs) use floor_x/floor_y percentages
                floor_x_pct = [[((spec['floor_x'] || spec[:floor_x] || 50).to_i), 0].max, 100].min
                floor_y_pct = [[((spec['floor_y'] || spec[:floor_y] || 50).to_i), 0].max, 100].min
                fx = (min_x + (max_x - min_x) * floor_x_pct / 100.0).round
                fy = (min_y + (max_y - min_y) * floor_y_pct / 100.0).round
                dir = sanitize_direction(spec['wall'] || spec[:wall] || 'south')
              else
                # Wall features use wall + wall_position percentage
                dir = sanitize_direction(spec['wall'] || spec[:wall] || spec['direction'] || spec[:direction])
                pct = [[((spec['wall_position'] || spec[:wall_position] || 50).to_i), 0].max, 100].min
                fx, fy = wall_position_to_coords(dir, pct, min_x, max_x, min_y, max_y)
              end

              feature = RoomFeature.create(
                room_id: room.id,
                feature_type: ft,
                name: (spec['name'] || spec[:name] || ft).to_s[0..50],
                description: (spec['description'] || spec[:description] || '').to_s[0..200],
                x: fx, y: fy, z: 0,
                direction: dir,
                open_state: 'closed',
                allows_movement: spec['allows_movement'] != false && %w[door opening archway gate hatch stairs].include?(ft),
                allows_sight: spec['allows_sight'] != false && %w[window opening archway].include?(ft),
                has_curtains: spec['has_curtains'] == true,
                has_lock: spec['has_lock'] == true
              )
              results[:features] << { room_id: room.id, feature_id: feature.id, type: ft }
            rescue StandardError => e
              results[:errors] << "Feature creation failed in #{room.name}: #{e.message}"
            end
          end
        end

        results
      end

      # Determine room environment type
      # @param room_type [String]
      # @param room_info [Hash, nil]
      # @return [String] 'indoor', 'outdoor', or 'underground'
      def room_environment(room_type, room_info = nil)
        floor = room_info&.dig(:floor) || 0
        return 'underground' if floor < 0

        case room_type.to_s
        when /cellar|basement|crypt|dungeon|mine|tunnel|sewer|cave/
          'underground'
        when /forest|meadow|field|hillside|courtyard|plaza|garden|beach|swamp|desert|mountain/
          'outdoor'
        else
          'indoor'
        end
      end

      # Convert wall + percentage position to actual room coordinates.
      # @param wall [String] 'north', 'south', 'east', 'west'
      # @param pct [Integer] 0-100 position along the wall
      # @param min_x [Integer] room min X
      # @param max_x [Integer] room max X
      # @param min_y [Integer] room min Y
      # @param max_y [Integer] room max Y
      # @return [Array(Integer, Integer)] [x, y] coordinates
      def wall_position_to_coords(wall, pct, min_x, max_x, min_y, max_y)
        frac = pct / 100.0
        case wall
        when 'south'
          x = (min_x + (max_x - min_x) * frac).round
          [x, min_y]
        when 'north'
          x = (min_x + (max_x - min_x) * frac).round
          [x, max_y]
        when 'west'
          y = (min_y + (max_y - min_y) * frac).round
          [min_x, y]
        when 'east'
          y = (min_y + (max_y - min_y) * frac).round
          [max_x, y]
        else
          # Fallback: center of south wall
          [(min_x + max_x) / 2, min_y]
        end
      end

      # Default room features when LLM is unavailable (uses wall+percentage format)
      # @return [Array<Hash>] feature specs
      def default_room_features(room_type, environment, min_x, max_x, min_y, max_y)
        case environment
        when 'outdoor'
          [
            { 'feature_type' => 'opening', 'name' => 'natural gap', 'description' => 'A gap between the trees',
              'wall' => 'south', 'wall_position' => 50 },
            { 'feature_type' => 'opening', 'name' => 'trail opening', 'description' => 'A narrow path leading away',
              'wall' => 'north', 'wall_position' => 40 }
          ]
        when 'underground'
          [
            { 'feature_type' => 'archway', 'name' => 'stone archway', 'description' => 'A rough-hewn archway',
              'wall' => 'south', 'wall_position' => 50 },
            { 'feature_type' => 'archway', 'name' => 'passage arch', 'description' => 'A dark passage continues',
              'wall' => 'east', 'wall_position' => 60 }
          ]
        else
          [
            { 'feature_type' => 'door', 'name' => 'front door', 'description' => 'A sturdy wooden door',
              'wall' => 'south', 'wall_position' => 50, 'has_lock' => true },
            { 'feature_type' => 'window', 'name' => 'side window', 'description' => 'A window looking outside',
              'wall' => 'east', 'wall_position' => 40 }
          ]
        end
      end

      # Sanitize feature type to valid values
      # @param ft [String]
      # @return [String]
      def sanitize_feature_type(ft)
        valid = %w[door window opening archway gate hatch stairs]
        valid.include?(ft.to_s) ? ft.to_s : 'door'
      end

      # Sanitize direction to valid values
      # @param dir [String]
      # @return [String]
      def sanitize_direction(dir)
        valid = %w[north south east west]
        valid.include?(dir.to_s) ? dir.to_s : 'south'
      end

      # Clamp coordinate within room bounds
      # @param val [Integer]
      # @param min_val [Integer]
      # @param max_val [Integer]
      # @return [Integer]
      def clamp_coordinate(val, min_val, max_val)
        [[val, min_val].max, max_val].min
      end

      # Distribute furniture positions across a room to avoid clustering.
      # Divides the usable room area into a grid and assigns each item to a different cell
      # with some randomness within each cell.
      # @param count [Integer] number of positions needed
      # @param min_x [Integer] room min X
      # @param max_x [Integer] room max X
      # @param min_y [Integer] room min Y
      # @param max_y [Integer] room max Y
      # @return [Array<Hash>] array of {x:, y:} positions
      def distribute_furniture_positions(count:, min_x:, max_x:, min_y:, max_y:)
        return [] if count <= 0

        # Inset from walls so furniture isn't flush against edges
        padding = 5
        usable_min_x = min_x + padding
        usable_max_x = max_x - padding
        usable_min_y = min_y + padding
        usable_max_y = max_y - padding

        # Clamp if room is too small for padding
        if usable_min_x >= usable_max_x
          usable_min_x = min_x + 1
          usable_max_x = max_x - 1
        end
        if usable_min_y >= usable_max_y
          usable_min_y = min_y + 1
          usable_max_y = max_y - 1
        end

        width = usable_max_x - usable_min_x
        height = usable_max_y - usable_min_y
        return [{ x: (min_x + max_x) / 2, y: (min_y + max_y) / 2 }] * count if width <= 0 || height <= 0

        # Calculate grid dimensions based on item count
        # For n items, use ceil(sqrt(n)) columns and enough rows
        cols = Math.sqrt(count).ceil
        rows = (count.to_f / cols).ceil

        cell_w = width.to_f / cols
        cell_h = height.to_f / rows

        positions = []
        count.times do |i|
          col = i % cols
          row = i / cols

          # Position within cell with some randomness (center +/- 30% of cell size)
          jitter_x = (cell_w * 0.3 * (rand - 0.5)).round
          jitter_y = (cell_h * 0.3 * (rand - 0.5)).round

          x = (usable_min_x + (col + 0.5) * cell_w + jitter_x).round
          y = (usable_min_y + (row + 0.5) * cell_h + jitter_y).round

          # Clamp to usable bounds
          x = [[x, usable_min_x].max, usable_max_x].min
          y = [[y, usable_min_y].max, usable_max_y].min

          positions << { x: x, y: y }
        end

        positions
      end

      # Snap a feature to the nearest wall edge. Doors, windows, gates, and hatches
      # must be on room boundaries. Openings and archways are also snapped for consistency.
      # @param x [Integer] raw x coordinate
      # @param y [Integer] raw y coordinate
      # @param dir [String] declared direction
      # @param feature_type [String] the feature type
      # @param min_x [Integer] room min_x
      # @param max_x [Integer] room max_x
      # @param min_y [Integer] room min_y
      # @param max_y [Integer] room max_y
      # @return [Array(Integer, Integer, String)] snapped [x, y, direction]
      def snap_to_wall(x, y, dir, feature_type, min_x, max_x, min_y, max_y)
        x = [[x, min_x].max, max_x].min
        y = [[y, min_y].max, max_y].min

        width = max_x - min_x
        height = max_y - min_y
        return [x, y, dir] if width <= 0 || height <= 0

        # Find which wall is closest
        dist_south = (y - min_y).abs
        dist_north = (max_y - y).abs
        dist_west  = (x - min_x).abs
        dist_east  = (max_x - x).abs

        min_dist = [dist_south, dist_north, dist_west, dist_east].min

        case min_dist
        when dist_south
          [x, min_y, 'south']
        when dist_north
          [x, max_y, 'north']
        when dist_west
          [min_x, y, 'west']
        when dist_east
          [max_x, y, 'east']
        else
          [x, min_y, 'south']
        end
      end

      # Get furniture specs appropriate for a room type
      # @param room_type [String] the room type
      # @param place_type [Symbol] the place type for context
      # @return [Array<Hash>] furniture specs with name, description, capacity, sit_action
      def furniture_for_room_type(room_type, place_type)
        # Common furniture by room function
        furniture = case room_type.to_s
                    when /common_room|taproom|lounge/
                      [
                        { name: 'long wooden table', description: 'A sturdy oak table scarred by years of use', capacity: 6, sit_action: 'at' },
                        { name: 'round corner table', description: 'A smaller table tucked away for private conversations', capacity: 4, sit_action: 'at' },
                        { name: 'worn bench', description: 'A well-worn wooden bench along the wall', capacity: 3, sit_action: 'on' },
                        { name: 'high-backed chair', description: 'A creaky chair by the fireplace', capacity: 1, sit_action: 'in' }
                      ]
                    when /kitchen|cooking/
                      [
                        { name: 'preparation table', description: 'A heavy butcher block table', capacity: 2, sit_action: 'at' },
                        { name: 'stool', description: 'A simple wooden stool', capacity: 1, sit_action: 'on' }
                      ]
                    when /storage|cellar|warehouse/
                      [
                        { name: 'wooden crate', description: 'A sturdy crate that could serve as a seat', capacity: 1, sit_action: 'on' }
                      ]
                    when /shop|showroom|forge/
                      [
                        { name: 'display counter', description: 'A long wooden counter displaying wares', capacity: 2, sit_action: 'at' },
                        { name: 'customer bench', description: 'A small bench for waiting customers', capacity: 2, sit_action: 'on' }
                      ]
                    when /guest_room|bedroom|private_room/
                      [
                        { name: 'bed', description: 'A simple bed with a straw mattress', capacity: 2, sit_action: 'on' },
                        { name: 'wooden chair', description: 'A plain wooden chair', capacity: 1, sit_action: 'on' }
                      ]
                    when /lobby|entrance|hall/
                      [
                        { name: 'waiting bench', description: 'A bench for visitors', capacity: 3, sit_action: 'on' }
                      ]
                    when /dining|restaurant/
                      [
                        { name: 'dining table', description: 'A well-set dining table', capacity: 4, sit_action: 'at' },
                        { name: 'dining table', description: 'Another dining table for guests', capacity: 4, sit_action: 'at' },
                        { name: 'cushioned chair', description: 'A comfortable dining chair', capacity: 1, sit_action: 'on' }
                      ]
                    when /temple|chapel|sanctuary/
                      [
                        { name: 'prayer bench', description: 'A wooden pew for worshippers', capacity: 4, sit_action: 'on' },
                        { name: 'meditation cushion', description: 'A simple cushion for contemplation', capacity: 1, sit_action: 'on' }
                      ]
                    when /forest|meadow|field|hillside/
                      [
                        { name: 'fallen log', description: 'A moss-covered fallen tree trunk', capacity: 3, sit_action: 'on' }
                      ]
                    when /cave|mine|tunnel/
                      [
                        { name: 'flat rock ledge', description: 'A natural ledge of stone jutting from the wall', capacity: 2, sit_action: 'on' }
                      ]
                    when /crypt|dungeon/
                      [
                        { name: 'stone sarcophagus', description: 'A heavy stone coffin with a carved lid', capacity: 0, sit_action: 'on' },
                        { name: 'iron cage', description: 'A rusted iron cage bolted to the floor', capacity: 1, sit_action: 'in' },
                        { name: 'stone bench', description: 'A cold stone slab set against the wall', capacity: 2, sit_action: 'on' }
                      ]
                    when /swamp|beach/
                      [
                        { name: 'driftwood log', description: 'A salt-bleached log washed ashore', capacity: 2, sit_action: 'on' }
                      ]
                    when /desert|mountain/
                      []
                    when /courtyard|plaza|garden/
                      [
                        { name: 'stone bench', description: 'A weathered stone bench beneath an overhang', capacity: 2, sit_action: 'on' }
                      ]
                    when /sewer/
                      []
                    else
                      [
                        { name: 'simple chair', description: 'A plain wooden chair', capacity: 1, sit_action: 'on' }
                      ]
                    end

        # All defined furniture is appropriate for the room type — return it all.
        # The `furniture_for_room_type` method already curates the right items per type.
        furniture
      end

      # Get decoration specs appropriate for a room type
      # @param room_type [String] the room type
      # @param place_type [Symbol] the place type for context
      # @param setting [Symbol] world setting
      # @return [Array<Hash>] decoration specs with name, description
      def decorations_for_room_type(room_type, place_type, setting)
        # Setting-appropriate decorations
        setting_items = case setting.to_sym
                        when :fantasy
                          ['iron chandelier', 'tapestry', 'mounted antlers', 'herb bundle', 'candle sconce']
                        when :medieval
                          ['torch bracket', 'coat of arms', 'woven banner', 'iron candelabra']
                        when :modern
                          ['pendant light', 'framed print', 'potted plant', 'wall clock']
                        else
                          ['wall decoration', 'hanging ornament']
                        end

        # Room-specific decorations
        decorations = case room_type.to_s
                      when /common_room|taproom|lounge/
                        [
                          { name: 'stone fireplace', description: 'A large hearth with a crackling fire' },
                          { name: setting_items.sample, description: 'Adds character to the room' },
                          { name: 'notice board', description: 'A board covered in pinned notices and wanted posters' }
                        ]
                      when /kitchen/
                        [
                          { name: 'hanging pots', description: 'Copper pots and pans dangling from hooks' },
                          { name: 'spice rack', description: 'A rack of dried herbs and spices' }
                        ]
                      when /storage|cellar/
                        [
                          { name: 'dusty shelves', description: 'Wooden shelves holding various supplies' }
                        ]
                      when /shop|showroom/
                        [
                          { name: 'display case', description: 'A glass-fronted case showing fine wares' },
                          { name: 'shop sign', description: 'The establishment\'s sign hangs proudly' }
                        ]
                      when /forge/
                        [
                          { name: 'anvil', description: 'A heavy iron anvil bearing the marks of countless hammer strikes' },
                          { name: 'weapon rack', description: 'A rack displaying finished weapons' }
                        ]
                      when /temple|chapel/
                        [
                          { name: 'altar', description: 'A sacred altar adorned with offerings' },
                          { name: 'stained glass window', description: 'Colored light streams through the ornate window' }
                        ]
                      when /forest|meadow|field|hillside/
                        [
                          { name: 'gnarled tree', description: 'An ancient tree with twisted branches' },
                          { name: 'wildflower patch', description: 'A cluster of colourful wildflowers' },
                          { name: 'bird nest', description: 'A woven nest tucked in the branches above' }
                        ]
                      when /cave|mine|tunnel/
                        [
                          { name: 'glowing fungus', description: 'Bioluminescent fungi casting a faint blue-green glow' },
                          { name: 'mineral vein', description: 'A streak of glittering mineral in the rock wall' },
                          { name: 'dripping stalactite', description: 'Water drips steadily from a pointed formation' }
                        ]
                      when /crypt|dungeon/
                        [
                          { name: 'crumbling inscription', description: 'Faded letters carved into the stone wall' },
                          { name: 'rusted chain', description: 'A length of corroded chain dangling from the ceiling' },
                          { name: 'skull alcove', description: 'A niche in the wall holding yellowed bones' }
                        ]
                      when /swamp|beach/
                        [
                          { name: 'tide pool', description: 'A shallow pool left by the retreating water' },
                          { name: 'tangled roots', description: 'A web of exposed roots stretching across the ground' }
                        ]
                      when /desert|mountain/
                        [
                          { name: 'wind-scoured cairn', description: 'A stack of stones left by previous travelers' },
                          { name: 'dry shrub', description: 'A tough, thorny bush clinging to the rocky soil' }
                        ]
                      when /courtyard|plaza|garden/
                        [
                          { name: 'cracked fountain', description: 'A dry fountain basin choked with moss' },
                          { name: 'vine-covered wall', description: 'Thick ivy cascades down the stonework' },
                          { name: 'weathered statue', description: 'A time-worn statue missing one arm' }
                        ]
                      when /sewer/
                        [
                          { name: 'slick moss', description: 'Dark green moss coating the damp walls' },
                          { name: 'rat nest', description: 'A mound of shredded material and debris' }
                        ]
                      else
                        [
                          { name: setting_items.sample, description: 'A fitting decoration for the space' }
                        ]
                      end

        # All defined decorations are appropriate — return them all with ordering.
        decorations.each_with_index.map do |d, i|
          d.merge(display_order: i + 1)
        end
      end

      # Create actual Room records for the place using BlockBuilderService
      # @param location [Location]
      # @param parent_room [Room, nil] intersection or street room to connect to
      # @param place_name [String]
      # @param place_type [Symbol]
      # @param layout [Array<Hash>] planned room layout
      # @param room_descriptions [Hash] generated descriptions by room_type
      # @param setting [Symbol]
      # @param options [Hash]
      # @return [Hash] { building:, rooms:, errors: }
      def create_building_rooms(location:, parent_room:, place_name:, place_type:,
                                layout:, room_descriptions:, setting:, options: {})
        results = { building: nil, rooms: [], errors: [] }

        # Get the BlockBuilderService building type
        building_type = BUILDING_TYPE_MAP[place_type] || :shop

        begin
          # Calculate building bounds
          # If we have a parent room (intersection), use its grid coordinates
          if parent_room
            grid_x = parent_room.grid_x || 0
            grid_y = parent_room.grid_y || 0

            # Use GridCalculationService if available
            block_bounds = if defined?(GridCalculationService)
                             GridCalculationService.block_bounds(
                               intersection_x: grid_x,
                               intersection_y: grid_y
                             )
                           else
                             # Fallback bounds for simple building
                             { min_x: 0, max_x: 50, min_y: 0, max_y: 50, min_z: 0, max_z: 30 }
                           end

            # Get building footprint - use lot_bounds if provided, otherwise full block
            building_bounds = if options[:lot_bounds]
                                lot = options[:lot_bounds]
                                {
                                  min_x: lot[:min_x], max_x: lot[:max_x],
                                  min_y: lot[:min_y], max_y: lot[:max_y],
                                  min_z: 0,
                                  max_z: options[:max_height] || location.max_building_height || 100
                                }
                              elsif defined?(GridCalculationService)
                                config = GridCalculationService.building_config(building_type)
                                GridCalculationService.building_footprint(
                                  block_bounds: block_bounds,
                                  building_type: building_type,
                                  position: :full,
                                  max_height: options[:max_height] || location.max_building_height || 100
                                )
                              else
                                block_bounds
                              end
            # Generate address from street name
            street_name = parent_room.street_name || "#{CoreExtensions.ordinalize(grid_y + 1)} Street"
            address = if defined?(GridCalculationService)
                        GridCalculationService.format_address(
                          street_name: street_name,
                          grid_x: grid_x,
                          grid_y: grid_y
                        )
                      else
                        "#{street_name} #{grid_x + 1}"
                      end
          else
            # No parent room - use simple bounds
            grid_x = 0
            grid_y = 0
            building_bounds = { min_x: 0, max_x: 50, min_y: 0, max_y: 50, min_z: 0, max_z: 30 }
            address = place_name
          end

          # Create the main building room using BlockBuilderService
          building = BlockBuilderService.create_building(
            location: location,
            parent_room: parent_room,
            building_type: building_type,
            bounds: building_bounds,
            address: address,
            name: place_name,
            grid_x: grid_x,
            grid_y: grid_y
          )

          # Store original place_type for visual distinction (e.g., blacksmith vs generic shop)
          building.update(building_type: place_type.to_s) if building

          results[:building] = building

          # Create interior rooms using FloorPlanService
          floors = layout.group_by { |r| r[:floor] || 0 }
          floors.each do |floor_num, floor_rooms|
            room_list = floor_rooms.map do |room_info|
              {
                name: format_room_name(room_info[:room_type], place_name),
                type: map_to_room_type(room_info[:room_type])
              }
            end

            plan = FloorPlanService.generate(
              building_bounds: building_bounds,
              floor_number: floor_num,
              building_type: building_type,
              room_list: room_list
            )

            non_hallway_idx = 0
            plan.each do |room_def|
              if room_def[:is_hallway]
                room = Room.create(
                  location_id: location.id,
                  name: "#{place_name} - #{room_def[:name]}",
                  room_type: room_def[:room_type],
                  long_description: "The #{room_def[:name].downcase} of #{place_name}.",
                  min_x: room_def[:bounds][:min_x], max_x: room_def[:bounds][:max_x],
                  min_y: room_def[:bounds][:min_y], max_y: room_def[:bounds][:max_y],
                  min_z: room_def[:bounds][:min_z], max_z: room_def[:bounds][:max_z],
                  grid_x: grid_x, grid_y: grid_y,
                  city_role: 'building', building_type: building_type.to_s,
                  floor_number: floor_num
                )
                results[:rooms] << room
              else
                room_info = floor_rooms[non_hallway_idx] if non_hallway_idx < floor_rooms.length
                non_hallway_idx += 1
                room_type_key = room_info ? room_info[:room_type] : nil
                description = if room_type_key && room_descriptions[room_type_key]
                                room_descriptions[room_type_key]
                              elsif room_type_key
                                generate_simple_room_description(room_type: room_type_key, place_type: place_type, setting: setting)
                              else
                                "A room in #{place_name}."
                              end
                room_name = room_type_key ? "#{place_name} - #{format_room_name(room_type_key, place_name)}" :
                            "#{place_name} - #{room_def[:name]}"
                room = Room.create(
                  location_id: location.id, name: room_name,
                  room_type: room_def[:room_type], long_description: description,
                  min_x: room_def[:bounds][:min_x], max_x: room_def[:bounds][:max_x],
                  min_y: room_def[:bounds][:min_y], max_y: room_def[:bounds][:max_y],
                  min_z: room_def[:bounds][:min_z], max_z: room_def[:bounds][:max_z],
                  grid_x: grid_x, grid_y: grid_y,
                  city_role: 'building', building_type: building_type.to_s,
                  floor_number: floor_num
                )
                results[:rooms] << room
              end
            end
          end

          # Link all interior rooms to their parent building shell as subrooms
          if results[:rooms].any? && building
            room_ids = results[:rooms].map(&:id).compact
            Room.where(id: room_ids).update(inside_room_id: building.id) if room_ids.any?
            results[:rooms].each { |r| r.values[:inside_room_id] = building.id if r.respond_to?(:values) }
          end
        rescue StandardError => e
          results[:errors] << "Building creation failed: #{e.message}"
        end

        results
      end

      private

      # Generate a simple room description without LLM (fallback)
      # @param room_type [String]
      # @param place_type [Symbol]
      # @param setting [Symbol]
      # @return [String]
      def generate_simple_room_description(room_type:, place_type:, setting:)
        type_name = room_type.to_s.tr('_', ' ')
        place_name = place_type.to_s.tr('_', ' ')

        case room_type.to_s
        when 'common_room'
          "A bustling common room filled with tables and chairs. The air is warm with the smell of food and drink."
        when 'kitchen'
          "A working kitchen with pots, pans, and cooking implements. Heat radiates from the hearth."
        when 'storage', 'cellar'
          "A dimly lit storage area packed with crates, barrels, and supplies."
        when 'showroom', 'shop_floor'
          "A well-organized display area showcasing wares for sale. Shelves and counters line the walls."
        when 'forge'
          "A hot forge with an anvil at its center. Tools hang from pegs on soot-stained walls."
        when 'lobby', 'main_hall'
          "An entrance hall welcoming visitors. Doors lead to various parts of the establishment."
        when 'guest_room', 'bedroom'
          "A private room with a bed and basic furnishings. A window provides natural light."
        when 'office'
          "A working office with a desk, chair, and paperwork. Ledgers and documents are neatly organized."
        when 'sanctuary', 'altar_room'
          "A sacred space for worship and contemplation. An altar stands at the focal point."
        else
          "The #{type_name} of this #{setting} #{place_name}."
        end
      end

      # Map place type to shop generator type
      def map_place_to_shop_type(place_type)
        case place_type.to_sym
        when :tavern then :tavern
        when :inn then :inn
        when :restaurant then :restaurant
        when :blacksmith then :blacksmith
        when :apothecary then :apothecary
        when :clothier then :clothier
        when :jeweler then :jeweler
        when :general_store then :general_store
        when :guild_hall then :guild
        when :temple then :temple
        when :bank then :bank
        when :library then :library
        else :general_store
        end
      end

      # Calculate which floor a room should be on
      def calculate_floor(room_type, index, total)
        underground = %w[cellar basement crypt vault]
        upper = %w[upstairs_hall guest_room bedroom]

        if underground.include?(room_type.to_s)
          -1
        elsif upper.include?(room_type.to_s)
          1 + (index / 3)
        else
          0
        end
      end

      # Format room name for display
      def format_room_name(room_type, place_name)
        room_type.to_s.tr('_', ' ').split.map(&:capitalize).join(' ')
      end

      # Map internal room type to Room model type
      def map_to_room_type(room_type)
        mapping = {
          'common_room' => 'bar',
          'kitchen' => 'kitchen',
          'storage' => 'warehouse',
          'cellar' => 'basement',
          'private_room' => 'living_room',
          'upstairs_hall' => 'hallway',
          'guest_room' => 'bedroom',
          'lobby' => 'lobby',
          'dining_room' => 'restaurant',
          'forge' => 'factory',
          'showroom' => 'shop',
          'workroom' => 'office',
          'shop_floor' => 'shop',
          'preparation_room' => 'office',
          'fitting_room' => 'office',
          'workshop' => 'office',
          'vault' => 'basement',
          'main_hall' => 'lobby',
          'meeting_room' => 'office',
          'office' => 'office',
          'archive' => 'library',
          'training_room' => 'gym',
          'quarters' => 'bedroom',
          'sanctuary' => 'temple',
          'altar_room' => 'temple',
          'meditation_chamber' => 'temple',
          'garden' => 'garden',
          'reading_room' => 'library',
          'stacks' => 'library',
          'rare_books' => 'library',
          'study_room' => 'library',
          'entry_hall' => 'hallway',
          'parlor' => 'living_room',
          'bedroom' => 'bedroom',
          'study' => 'office',
          'grand_foyer' => 'lobby',
          'ballroom' => 'theater',
          'dining_hall' => 'restaurant',
          'servant_quarters' => 'bedroom',
          'main_floor' => 'warehouse',
          'loading_dock' => 'warehouse',
          'pantry' => 'storage',
          'back_room' => 'storage',
          'private_vault' => 'basement',
          'vault_entrance' => 'lobby',
          'living_quarters' => 'apartment'
        }

        mapping[room_type.to_s] || 'standard'
      end

      # Get item categories for a shop type
      def shop_inventory_categories(shop_type)
        case shop_type.to_sym
        when :blacksmith then %i[weapon misc]
        when :apothecary then %i[consumable misc]
        when :clothier then %i[clothing]
        when :jeweler then %i[jewelry]
        when :general then %i[misc consumable]
        else %i[misc]
        end
      end
      # Build a brief short_desc for an NPC from their appearance text.
      # Short_desc is used as a fallback display name for characters the viewer
      # doesn't know, so it should be a brief physical description without the name.
      # @param appearance [String, nil] LLM-generated appearance text
      # @param gender [String, nil] NPC gender
      # @return [String, nil]
      def build_npc_short_desc(appearance, gender)
        return nil if appearance.nil? || appearance.strip.empty?

        # Extract key physical traits from first sentence
        first_sentence = appearance.split('.').first&.strip || ''

        # Remove the NPC's name from the start (e.g., "Emma Buckridge stands at...")
        # Names are typically 1-3 words before a verb
        desc = first_sentence.sub(/\A[A-Z][a-z]+(?:\s+[A-Z][a-z'-]+){0,2},?\s+/, '')

        # Build a brief "a <description> <gender_word>" format
        gender_word = case gender&.to_s&.downcase
                      when 'male' then 'man'
                      when 'female' then 'woman'
                      else 'person'
                      end

        # Take the first meaningful chunk, truncate to ~60 chars
        if desc.length > 60
          truncated = desc[0..59]
          last_space = truncated.rindex(' ')
          desc = last_space && last_space > 15 ? truncated[0...last_space] : truncated
        end

        "a #{desc.downcase.sub(/\A(a |an |the )/, '')} #{gender_word}".strip
      rescue StandardError => e
        warn "[PlaceGeneratorService] Failed to build short description: #{e.message}"
        nil
      end
    end
  end
end
