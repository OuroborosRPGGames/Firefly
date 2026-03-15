# frozen_string_literal: true

module Generators
  # CityGeneratorService generates complete cities with names, layout, places, and NPCs
  #
  # Orchestrates the full city generation pipeline:
  # 1. Generate city name
  # 2. Generate street names
  # 3. Build city grid (via CityBuilderService)
  # 4. Plan places based on city size and setting
  # 5. Generate places with optional NPCs and rooms
  #
  # @example Generate a complete city
  #   result = Generators::CityGeneratorService.generate(
  #     location: location,
  #     setting: :fantasy,
  #     size: :medium
  #   )
  #
  # @example Generate city name only
  #   result = Generators::CityGeneratorService.generate_name(
  #     setting: :fantasy,
  #     seed_terms: ['ancient', 'prosperous']
  #   )
  #
  class CityGeneratorService
    # City sizes and their corresponding parameters
    CITY_SIZES = {
      village: { streets: 3, avenues: 3, places: 5..10, max_height: 40 },
      town: { streets: 5, avenues: 5, places: 15..25, max_height: 60 },
      small_city: { streets: 7, avenues: 7, places: 30..50, max_height: 100 },
      medium: { streets: 10, avenues: 10, places: 50..80, max_height: 150 },
      large_city: { streets: 15, avenues: 15, places: 80..120, max_height: 200 },
      metropolis: { streets: 20, avenues: 20, places: 150..250, max_height: 300 }
    }.freeze

    # Place distribution by city type
    PLACE_DISTRIBUTION = {
      village: {
        tavern: 1, inn: 0..1, general_store: 1, blacksmith: 0..1,
        temple: 0..1, townhouse: 2..4
      },
      town: {
        tavern: 1..2, inn: 1, restaurant: 0..1, general_store: 1..2,
        blacksmith: 1, apothecary: 0..1, clothier: 0..1,
        temple: 1, guild_hall: 0..1, townhouse: 5..10
      },
      small_city: {
        tavern: 2..4, inn: 1..2, restaurant: 1..2, general_store: 2..3,
        blacksmith: 1..2, apothecary: 1, clothier: 1, jeweler: 0..1,
        bank: 0..1, temple: 1..2, guild_hall: 1, library: 0..1,
        townhouse: 10..15, warehouse: 1..2
      },
      medium: {
        tavern: 4..6, inn: 2..3, restaurant: 2..4, general_store: 3..5,
        blacksmith: 2..3, apothecary: 1..2, clothier: 2..3, jeweler: 1,
        bank: 1, temple: 2..3, guild_hall: 1..2, library: 1,
        townhouse: 15..25, mansion: 1..3, warehouse: 2..4
      },
      large_city: {
        tavern: 6..10, inn: 3..5, restaurant: 5..8, general_store: 5..8,
        blacksmith: 3..5, apothecary: 2..4, clothier: 4..6, jeweler: 2..3,
        bank: 2..3, temple: 3..5, guild_hall: 2..3, library: 1..2,
        townhouse: 25..40, mansion: 3..6, warehouse: 4..8
      },
      metropolis: {
        tavern: 10..15, inn: 5..8, restaurant: 8..12, general_store: 8..12,
        blacksmith: 5..8, apothecary: 4..6, clothier: 6..10, jeweler: 3..5,
        bank: 3..5, temple: 5..8, guild_hall: 3..5, library: 2..4,
        townhouse: 40..60, mansion: 6..12, warehouse: 8..15
      }
    }.freeze

    class << self
      # Generate a complete city
      # @param location [Location, nil] the location to build in (OR use coordinates)
      # @param longitude [Float, nil] longitude for new location
      # @param latitude [Float, nil] latitude for new location
      # @param setting [Symbol] world setting
      # @param size [Symbol] city size
      # @param generate_places [Boolean] whether to generate places
      # @param generate_place_rooms [Boolean] whether to generate room descriptions
      # @param create_buildings [Boolean] whether to create actual Room records for places
      # @param generate_npcs [Boolean] whether to generate NPCs for places
      # @param job [GenerationJob, nil] optional job for progress tracking
      # @param options [Hash] additional options
      # @return [Hash] { success:, city_name:, streets:, places:, errors: }
      def generate(location: nil, longitude: nil, latitude: nil, setting: :fantasy, size: :medium,
                   generate_places: true, generate_place_rooms: false, create_buildings: false,
                   generate_npcs: false, job: nil, options: {})
        results = { success: false, errors: [] }
        size_config = CITY_SIZES[size.to_sym] || CITY_SIZES[:medium]
        generate_inventory = options.fetch(:generate_inventory, true)
        use_ai_names = options[:use_ai_names]

        # Get seed terms for city character (5 terms, LLM picks 1-2)
        seed_terms = options[:seed_terms] || SeedTermService.for_generation(:city, count: 5)
        results[:seed_terms] = seed_terms

        # Step 1: Generate city name FIRST (we need it for location creation)
        update_progress(job, 1, 7, 'Generating city name...')
        name_result = generate_name(setting: setting, seed_terms: seed_terms)

        unless name_result[:success]
          results[:errors] << name_result[:error]
          return results
        end
        results[:city_name] = name_result[:name]

        # Resolve location from coordinates if not provided
        if location.nil?
          if longitude.nil? || latitude.nil?
            results[:errors] << 'Either location or coordinates (longitude, latitude) must be provided'
            return results
          end

          update_progress(job, 2, 7, 'Creating location...')
          location_result = LocationResolverService.resolve(
            longitude: longitude,
            latitude: latitude,
            name: name_result[:name],
            location_type: 'building',
            options: {
              area_name: "#{name_result[:name]} Region",
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

        # Step 3: Generate street and avenue names
        update_progress(job, 3, 7, 'Generating street names...')
        all_names_result = generate_street_names(
          count: size_config[:streets] + size_config[:avenues],
          setting: setting,
          seed_terms: seed_terms
        )
        all_names = all_names_result[:names] || []

        planned_street_names = all_names.first(size_config[:streets])
        planned_avenue_names = all_names.drop(size_config[:streets]).first(size_config[:avenues])

        # If we didn't get enough avenue names from the combined batch, request more.
        if planned_avenue_names.length < size_config[:avenues]
          missing_avenues = size_config[:avenues] - planned_avenue_names.length
          avenue_fill_result = generate_street_names(
            count: missing_avenues,
            setting: setting,
            seed_terms: seed_terms
          )
          planned_avenue_names.concat(Array(avenue_fill_result[:names]).first(missing_avenues))
          results[:errors] << avenue_fill_result[:error] if avenue_fill_result[:error]
        end
        planned_avenue_names = planned_avenue_names.first(size_config[:avenues])

        # Hard fallback for any remaining missing names to preserve deterministic sizing.
        while planned_street_names.length < size_config[:streets]
          planned_street_names << "Street #{planned_street_names.length + 1}"
        end
        while planned_avenue_names.length < size_config[:avenues]
          planned_avenue_names << "Avenue #{planned_avenue_names.length + 1}"
        end

        results[:errors] << all_names_result[:error] if all_names_result[:error]

        # Step 4: Build city grid
        update_progress(job, 4, 7, 'Building city grid...')
        grid_result = build_city_grid(
          location: location,
          city_name: name_result[:name],
          size_config: size_config,
          street_names: planned_street_names,
          avenue_names: planned_avenue_names,
          use_ai_names: use_ai_names
        )

        if grid_result[:success]
          results[:streets] = grid_result[:street_count]
          results[:intersections] = grid_result[:intersection_count]
          results[:street_names] = grid_result[:street_names]
          results[:avenue_names] = grid_result[:avenue_names]
        else
          results[:errors] << grid_result[:error]
          return results.merge(success: false)
        end

        # Step 5: Plan places — try LLM manifest first, fall back to random distribution
        update_progress(job, 5, 7, 'Planning city places...')

        intersection_count = if create_buildings
                               Room.where(location_id: location.id, city_role: 'intersection').count
                             else
                               0
                             end
        green_ratio = options[:green_space_ratio] || 0.2
        default_slot_count = if size_config[:places].is_a?(Range)
                               ((size_config[:places].begin + size_config[:places].end) / 2.0).round
                             else
                               size_config[:places].to_i
                             end
        slot_count = if create_buildings && intersection_count.positive?
                       [intersection_count - (intersection_count * green_ratio).round, 1].max
                     else
                       [default_slot_count, 1].max
                     end

        manifest = plan_building_manifest(
          city_name: results[:city_name],
          city_size: size,
          setting: setting,
          slot_count: slot_count,
          seed_terms: seed_terms
        )

        if manifest
          places_plan = manifest.map do |entry|
            {
              place_type: entry[:place_type].to_sym,
              tier: select_tier(entry[:place_type].to_sym),
              priority: place_priority(entry[:place_type].to_sym),
              pre_assigned_name: entry[:name],
              character: entry[:character]
            }
          end
        else
          places_plan = plan_places(size: size, setting: setting, seed_terms: seed_terms)
        end
        results[:places_plan] = places_plan

        # Step 6: Generate places if requested
        if generate_places
          update_progress(job, 6, 7, 'Generating places...')

          # Get intersection rooms for building placement if we're creating buildings
          intersection_rooms = if create_buildings
                                  Room.where(location_id: location.id, city_role: 'intersection').all
                                else
                                  []
                                end

          places_result = generate_city_places(
            location: location,
            places_plan: places_plan,
            intersection_rooms: intersection_rooms,
            setting: setting,
            generate_rooms: generate_place_rooms,
            create_buildings: create_buildings,
            generate_npcs: generate_npcs,
            generate_inventory: generate_inventory,
            green_space_ratio: options[:green_space_ratio],
            job: job
          )

          results[:places] = places_result[:places]
          results[:errors].concat(places_result[:errors])
        end

        # Step 7: Done
        update_progress(job, 7, 7, 'City generation complete!')
        results[:success] = true
        results
      end

      # Generate city name using NameGeneratorService + LLM selection
      # @param setting [Symbol] world setting
      # @param seed_terms [Array<String>]
      # @return [Hash] { success:, name:, error: }
      def generate_name(setting: :fantasy, seed_terms: [])
        begin
          # Get multiple city name options
          options = NameGeneratorService.city_options(
            count: 5,
            setting: setting
          )

          if options.empty?
            return { success: false, error: 'No city name options generated' }
          end

          # Format for LLM selection
          name_strings = options.map(&:name)

          # Use LLM to select best name
          selection_result = GenerationPipelineService.select_best_name(
            options: name_strings,
            context: {
              type: 'city',
              setting: setting,
              character: seed_terms.first(2).join(', ')
            }
          )

          {
            success: true,
            name: selection_result[:selected] || name_strings.first,
            alternatives: name_strings,
            reasoning: selection_result[:reasoning]
          }
        rescue StandardError => e
          { success: false, error: "City name generation failed: #{e.message}" }
        end
      end

      # Generate street names for the city
      # @param count [Integer] number of street names needed
      # @param setting [Symbol] world setting
      # @param seed_terms [Array<String>]
      # @return [Hash] { names: [], error: }
      def generate_street_names(count:, setting: :fantasy, seed_terms: [])
        begin
          names = []

          # Generate in batches
          (count / 5.0).ceil.times do
            batch = NameGeneratorService.street_options(
              count: 5,
              setting: setting
            )
            names.concat(batch.map(&:name))
          end

          { names: names.first(count), error: nil }
        rescue StandardError => e
          { names: [], error: "Street name generation failed: #{e.message}" }
        end
      end

      # Plan places for the city
      # @param size [Symbol] city size
      # @param setting [Symbol] world setting
      # @param seed_terms [Array<String>]
      # @return [Array<Hash>] planned places
      def plan_places(size:, setting: :fantasy, seed_terms: [])
        distribution = PLACE_DISTRIBUTION[size.to_sym] || PLACE_DISTRIBUTION[:medium]
        places = []

        distribution.each do |place_type, count_range|
          count = case count_range
                  when Range then rand(count_range)
                  when Integer then count_range
                  else 0
                  end

          count.times do
            places << {
              place_type: place_type,
              tier: select_tier(place_type),
              priority: place_priority(place_type)
            }
          end
        end

        # Sort by priority (essential places first)
        places.sort_by { |p| -p[:priority] }
      end

      # Plan all buildings for the city via a single LLM call.
      # Returns an array of hashes: [{name:, place_type:, character:}, ...]
      # Falls back to nil on failure (caller should use plan_places as fallback).
      def plan_building_manifest(city_name:, city_size:, setting:, slot_count:, seed_terms: [])
        prompt = GamePrompts.get_safe('city_generation.building_manifest',
          city_name: city_name,
          city_size: city_size,
          setting: setting,
          slot_count: slot_count,
          seed_terms: seed_terms.join(', ')
        )

        unless prompt
          warn "[CityGenerator] Building manifest prompt not found, falling back to distribution"
          return nil
        end

        begin
          response = LLM::Client.generate(
            prompt: prompt,
            options: { max_tokens: 4000 }
          )
          unless response[:success]
            warn "[CityGenerator] Building manifest LLM call failed: #{response[:error]}"
            return nil
          end

          json_str = response[:text].to_s.strip

          # Extract JSON array if wrapped in markdown code block
          if json_str =~ /```(?:json)?\s*\n?(.*?)\n?```/m
            json_str = $1.strip
          end

          manifest = JSON.parse(json_str, symbolize_names: true)
          return nil unless manifest.is_a?(Array) && manifest.length > 0

          # Normalize place_type aliases (e.g. cafe -> restaurant) before validation
          manifest = manifest.map do |entry|
            next nil unless entry.is_a?(Hash)

            normalized_type = canonical_manifest_place_type(entry[:place_type])
            next nil unless normalized_type

            entry.merge(place_type: normalized_type)
          end.compact

          # Validate place_types against known types
          valid_types = PLACE_DISTRIBUTION.values.flat_map(&:keys).uniq.map(&:to_s)
          manifest.select! { |b| valid_types.include?(b[:place_type].to_s) }

          return nil if manifest.empty?

          # Ensure we have the right count (trim or pad)
          if manifest.length > slot_count
            manifest = manifest.first(slot_count)
          elsif manifest.length < slot_count
            (slot_count - manifest.length).times do
              manifest << { name: nil, place_type: :townhouse, character: 'residential' }
            end
          end

          manifest
        rescue JSON::ParserError => e
          warn "[CityGenerator] Failed to parse building manifest JSON: #{e.message}"
          nil
        rescue StandardError => e
          warn "[CityGenerator] Building manifest LLM call failed: #{e.message}"
          nil
        end
      end

      # Generate all planned places
      # @param location [Location]
      # @param places_plan [Array<Hash>]
      # @param intersection_rooms [Array<Room>] available intersections for building placement
      # @param setting [Symbol]
      # @param generate_rooms [Boolean]
      # @param create_buildings [Boolean] whether to create Room records
      # @param generate_npcs [Boolean]
      # @param job [GenerationJob, nil]
      # @return [Hash] { places: [], errors: [] }
      def generate_city_places(location:, places_plan:, intersection_rooms: [], setting:,
                               generate_rooms:, create_buildings: false, generate_npcs:,
                               generate_inventory: true, green_space_ratio: nil, job: nil)
        results = { places: [], errors: [] }
        total = places_plan.length

        # Track NPC names and summaries across buildings for cross-building awareness
        all_npc_names = []
        all_npc_summaries = []

        # Use block-lot planning when creating buildings with available intersections
        if create_buildings && intersection_rooms.any?
          generate_with_block_lots(
            location: location,
            places_plan: places_plan,
            intersection_rooms: intersection_rooms,
            setting: setting,
            generate_rooms: generate_rooms,
            generate_npcs: generate_npcs,
            generate_inventory: generate_inventory,
            green_space_ratio: green_space_ratio,
            all_npc_names: all_npc_names,
            all_npc_summaries: all_npc_summaries,
            results: results,
            job: job
          )
        else
          # Simple path: no building creation or no intersections available
          generate_without_block_lots(
            location: location,
            places_plan: places_plan,
            intersection_rooms: intersection_rooms,
            setting: setting,
            generate_rooms: generate_rooms,
            create_buildings: create_buildings,
            generate_npcs: generate_npcs,
            generate_inventory: generate_inventory,
            all_npc_names: all_npc_names,
            all_npc_summaries: all_npc_summaries,
            results: results,
            job: job
          )
        end

        results
      end

      # Generate places using block-lot planning for proper lot subdivision
      def generate_with_block_lots(location:, places_plan:, intersection_rooms:, setting:,
                                   generate_rooms:, generate_npcs:, generate_inventory: true,
                                   green_space_ratio: nil,
                                   all_npc_names:, all_npc_summaries:, results:, job:)
        # Convert place types to building types for BlockLotService
        building_types = places_plan.map do |plan|
          PlaceGeneratorService::BUILDING_TYPE_MAP[plan[:place_type]] || :shop
        end

        # Determine city size from location
        city_size = detect_city_size(location)

        # Plan block allocations
        block_assignments = BlockLotService.plan_blocks(
          buildings: building_types,
          available_blocks: intersection_rooms.length,
          city_size: city_size,
          green_space_ratio: green_space_ratio
        )

        # Track used intersections
        used_intersections = []
        # Track which places have been generated (index into places_plan)
        place_index = 0

        # Green space types that don't come from place plans
        green_types = BlockLotService::GREEN_SPACE_TYPES.values.flatten.uniq

        block_assignments.each do |assignment|
          # Skip vacant and green space blocks (these don't have place plan entries)
          next if assignment[:buildings].all? { |b| b == :vacant || green_types.include?(b) }

          # Pick an available intersection for this block
          available = intersection_rooms.reject { |r| used_intersections.include?(r.id) }
          break if available.empty?

          parent_room = select_intersection_for_place(available, assignment[:buildings].first, location)
          used_intersections << parent_room.id

          grid_x = parent_room.grid_x || 0
          grid_y = parent_room.grid_y || 0

          # Calculate block bounds
          block_bounds = if defined?(GridCalculationService)
                           GridCalculationService.block_bounds(
                             intersection_x: grid_x,
                             intersection_y: grid_y
                           )
                         else
                           { min_x: 25, max_x: 175, min_y: 25, max_y: 175, width: 150, height: 150 }
                         end

          # Create alleys for this block type only if none exist yet
          existing_alleys = Room.where(
            location_id: location.id,
            grid_x: grid_x,
            grid_y: grid_y,
            room_type: 'alley'
          ).count

          if existing_alleys == 0
            BlockLotService.create_alleys(
              location: location,
              block_bounds: block_bounds,
              block_type: assignment[:block_type],
              grid_x: grid_x,
              grid_y: grid_y
            )
          end

          # Get lot bounds for this block type
          max_height = location.max_building_height || 100
          lots = BlockLotService.lot_bounds(
            block_bounds: block_bounds,
            block_type: assignment[:block_type],
            max_height: max_height
          )

          # Match buildings to lots
          lot_keys = lots.keys
          assignment[:buildings].each_with_index do |_building_type, idx|
            break if place_index >= places_plan.length

            plan = places_plan[place_index]
            place_index += 1

            lot_key = lot_keys[idx]
            lot = lot_key ? lots[lot_key] : nil

            update_progress(job, place_index, places_plan.length, "Generating #{plan[:place_type]}...") if job

            place_options = {
              tier: plan[:tier],
              existing_npc_names: all_npc_names,
              city_npc_summary: all_npc_summaries.join("\n"),
              max_height: max_height
            }
            place_options[:lot_bounds] = lot if lot

            place_result = PlaceGeneratorService.generate(
              location: location,
              place_type: plan[:place_type],
              parent_room: parent_room,
              setting: setting,
              generate_rooms: generate_rooms,
              create_building: true,
              generate_npcs: generate_npcs,
              generate_inventory: generate_inventory,
              generate_furniture: true,
              name: plan[:pre_assigned_name],
              options: place_options
            )

            collect_place_result(place_result, plan, all_npc_names, all_npc_summaries, results, create_buildings: true)
          end
        end

        # Generate any remaining places that didn't fit into blocks
        while place_index < places_plan.length
          plan = places_plan[place_index]
          place_index += 1

          available = intersection_rooms.reject { |r| used_intersections.include?(r.id) }
          parent_room = if available.any?
                          room = select_intersection_for_place(available, plan[:place_type], location)
                          used_intersections << room.id
                          room
                        end

          update_progress(job, place_index, places_plan.length, "Generating #{plan[:place_type]}...") if job

          place_result = PlaceGeneratorService.generate(
            location: location,
            place_type: plan[:place_type],
            parent_room: parent_room,
            setting: setting,
            generate_rooms: generate_rooms,
            create_building: true,
            generate_npcs: generate_npcs,
            generate_inventory: generate_inventory,
            generate_furniture: true,
            name: plan[:pre_assigned_name],
            options: {
              tier: plan[:tier],
              existing_npc_names: all_npc_names,
              city_npc_summary: all_npc_summaries.join("\n")
            }
          )

          collect_place_result(place_result, plan, all_npc_names, all_npc_summaries, results, create_buildings: true)
        end
      end

      # Generate places without block-lot planning (simple path)
      def generate_without_block_lots(location:, places_plan:, intersection_rooms:, setting:,
                                      generate_rooms:, create_buildings:, generate_npcs:,
                                      generate_inventory: true,
                                      all_npc_names:, all_npc_summaries:, results:, job:)
        used_intersections = []

        places_plan.each_with_index do |plan, index|
          update_progress(job, index + 1, places_plan.length, "Generating #{plan[:place_type]}...") if job

          # Find an available intersection for this building
          parent_room = nil
          if create_buildings && intersection_rooms.any?
            available = intersection_rooms.reject { |r| used_intersections.include?(r.id) }
            if available.any?
              parent_room = select_intersection_for_place(available, plan[:place_type], location)
              used_intersections << parent_room.id
            end
          end

          place_result = PlaceGeneratorService.generate(
            location: location,
            place_type: plan[:place_type],
            parent_room: parent_room,
            setting: setting,
            generate_rooms: generate_rooms,
            create_building: create_buildings,
            generate_npcs: generate_npcs,
            generate_inventory: generate_inventory,
            generate_furniture: true,
            options: {
              tier: plan[:tier],
              existing_npc_names: all_npc_names,
              city_npc_summary: all_npc_summaries.join("\n")
            }
          )

          collect_place_result(place_result, plan, all_npc_names, all_npc_summaries, results, create_buildings: create_buildings)
        end
      end

      # Collect results from a single place generation
      def collect_place_result(place_result, plan, all_npc_names, all_npc_summaries, results, create_buildings: false)
        if place_result[:success]
          place_info = {
            type: plan[:place_type],
            name: place_result[:name],
            rooms: place_result[:layout]&.length || 0
          }

          # Include building info if created
          if create_buildings && place_result[:building]
            place_info[:building_id] = place_result[:building].id
            place_info[:room_ids] = place_result[:rooms]&.map(&:id) || []
          end

          # Collect NPC names/summaries for subsequent buildings
          if place_result[:npcs]
            place_result[:npcs].each do |npc|
              npc_name = npc[:name].is_a?(String) ? npc[:name] : npc[:name]&.dig(:full_name) || npc[:name].to_s
              next if npc_name.empty?

              all_npc_names << npc_name
              all_npc_summaries << "- #{npc_name} (#{npc[:role]}, #{place_result[:name]})"
            end
          end

          results[:places] << place_info
        else
          results[:errors] << "#{plan[:place_type]}: #{place_result[:errors]&.first}"
        end
      end

      private

      # Detect city size from location attributes
      def detect_city_size(location)
        streets = location.horizontal_streets || 3
        case streets
        when 1..3 then :village
        when 4..5 then :town
        when 6..7 then :small_city
        when 8..10 then :medium
        when 11..15 then :large_city
        else :metropolis
        end
      end

      # Build city grid using CityBuilderService
      def build_city_grid(location:, city_name:, size_config:, street_names:, avenue_names:, use_ai_names: nil)
        result = CityBuilderService.build_city(
          location: location,
          params: {
            city_name: city_name,
            horizontal_streets: size_config[:streets],
            vertical_streets: size_config[:avenues],
            max_building_height: size_config[:max_height],
            use_llm_names: use_ai_names,
            street_names: street_names,
            avenue_names: avenue_names
          }
        )

        if result[:success]
          {
            success: true,
            street_count: (result[:streets]&.length || 0) + (result[:avenues]&.length || 0),
            intersection_count: result[:intersections]&.length || 0,
            street_names: result[:street_names] || street_names,
            avenue_names: result[:avenue_names] || avenue_names
          }
        else
          { success: false, error: result[:error] }
        end
      end

      # Update job progress
      def update_progress(job, step, total, message)
        return unless job

        ProgressTrackerService.update_progress(
          job: job,
          step: step,
          total: total,
          message: message
        )
      end

      # Select tier for a place based on place type
      def select_tier(place_type)
        tiers = case place_type.to_sym
                when :warehouse, :barn, :stable
                  [:common] * 8 + [:fine] * 2
                when :jeweler, :mansion, :bank
                  [:common] * 2 + [:fine] * 5 + [:luxury] * 3
                when :temple, :guild_hall, :library
                  [:common] * 3 + [:fine] * 5 + [:luxury] * 2
                when :tavern, :inn, :restaurant
                  [:common] * 4 + [:fine] * 4 + [:luxury] * 2
                else
                  [:common] * 5 + [:fine] * 3 + [:luxury] * 1
                end
        tiers.sample
      end

      # Get priority for place ordering (higher = more essential)
      def place_priority(place_type)
        case place_type.to_sym
        when :tavern, :inn then 100
        when :general_store, :blacksmith then 90
        when :temple, :bank then 80
        when :apothecary, :clothier then 70
        when :guild_hall, :library then 60
        when :restaurant, :jeweler then 50
        when :townhouse then 30
        when :mansion, :warehouse then 20
        else 10
        end
      end

      # Select an intersection for a place based on priority.
      # Commercial/civic types get central intersections; residential/warehouse get peripheral ones.
      # @param available [Array<Room>] available intersection rooms
      # @param place_type [Symbol, String] the type of place being built
      # @param location [Location] the city location
      # @return [Room] selected intersection
      def select_intersection_for_place(available, place_type, location)
        return available.first if available.length <= 1

        # Calculate grid center from location dimensions
        h_streets = location.horizontal_streets || 10
        v_streets = location.vertical_streets || 10
        center_x = (v_streets - 1) / 2.0
        center_y = (h_streets - 1) / 2.0

        # Sort by distance from center (closest first)
        sorted = available.sort_by do |room|
          gx = room.grid_x || 0
          gy = room.grid_y || 0
          ((gx - center_x)**2 + (gy - center_y)**2)
        end

        # High-priority types (commercial, civic) get central placement
        # Low-priority types (residential, warehouse) get peripheral placement
        type_sym = place_type.to_s.to_sym
        case type_sym
        when :tavern, :inn, :restaurant, :bank, :temple, :guild_hall,
             :library, :jeweler, :general_store, :blacksmith, :apothecary,
             :clothier, :shop, :bar, :cafe, :mall, :hotel
          sorted.first
        when :warehouse, :townhouse, :mansion, :house, :barn, :stable
          sorted.last
        else
          sorted[sorted.length / 2]
        end
      end

      # Normalize prompt-level place aliases to canonical place types.
      def canonical_manifest_place_type(place_type)
        type = place_type.to_s.strip.downcase
        return nil if type.empty?

        case type
        when 'cafe', 'coffee_shop', 'coffeehouse' then :restaurant
        when 'bar' then :tavern
        when 'shop', 'store', 'mall' then :general_store
        when 'church' then :temple
        when 'office', 'office_tower' then :guild_hall
        else
          type.to_sym
        end
      end
    end
  end
end
