# frozen_string_literal: true

# WorldBuilderOrchestratorService is the main entry point for LLM-driven world building
#
# Provides a unified interface for generating any type of world content:
# - Items (descriptions, images)
# - NPCs (names, descriptions, portraits, schedules)
# - Rooms (descriptions, seasonal variants, backgrounds)
# - Places (buildings with rooms, NPCs, inventory)
# - Cities (full city generation with streets, places)
#
# All operations use async job tracking via GenerationJob.
#
# @example Generate a room description
#   result = WorldBuilderOrchestratorService.generate_description(
#     target: room,
#     setting: :fantasy
#   )
#
# @example Generate a complete city asynchronously
#   job = WorldBuilderOrchestratorService.generate_city(
#     location: location,
#     size: :medium,
#     created_by: character
#   )
#   # Check job.status later
#
class WorldBuilderOrchestratorService
  class << self
    # ========================================
    # Item Generation
    # ========================================

    # Generate a complete item
    # @param category [Symbol] :clothing, :jewelry, :weapon, :consumable, :furniture, :misc
    # @param subcategory [String, nil] more specific type
    # @param setting [Symbol] world setting
    # @param generate_image [Boolean] whether to generate image
    # @param created_by [Character, nil] character initiating generation
    # @param options [Hash] additional options
    # @return [Hash] { job:, result: }
    def generate_item(category:, subcategory: nil, setting: :fantasy,
                      generate_image: false, created_by: nil, options: {})
      ProgressTrackerService.with_job(
        type: :item,
        config: { category: category, subcategory: subcategory, setting: setting },
        created_by: created_by,
        total_steps: generate_image ? 3 : 2
      ) do |job|
        Generators::ItemGeneratorService.generate(
          category: category,
          subcategory: subcategory,
          setting: setting,
          generate_image: generate_image,
          options: options
        )
      end
    end

    # ========================================
    # NPC Generation
    # ========================================

    # Generate a complete NPC
    # @param location [Location] where the NPC exists
    # @param role [String, nil] NPC role/occupation
    # @param gender [Symbol] :male, :female, :neutral, :any
    # @param culture [Symbol] cultural background
    # @param setting [Symbol] world setting
    # @param generate_portrait [Boolean] whether to generate portrait
    # @param generate_schedule [Boolean] whether to generate schedule
    # @param created_by [Character, nil]
    # @param options [Hash]
    # @return [GenerationJob]
    def generate_npc(location:, role: nil, gender: :any, culture: :western,
                     setting: :fantasy, generate_portrait: false,
                     generate_schedule: false, created_by: nil, options: {})
      steps = 2 + (generate_portrait ? 1 : 0) + (generate_schedule ? 1 : 0)

      ProgressTrackerService.with_job(
        type: :npc,
        config: { role: role, gender: gender, culture: culture, setting: setting },
        created_by: created_by,
        total_steps: steps
      ) do |job|
        Generators::NPCGeneratorService.generate(
          location: location,
          role: role,
          gender: gender,
          culture: culture,
          setting: setting,
          generate_portrait: generate_portrait,
          generate_schedule: generate_schedule,
          options: options
        )
      end
    end

    # ========================================
    # Room Generation
    # ========================================

    # Generate a room with description
    # @param parent [Location, Room] parent container
    # @param room_type [String] room type
    # @param name [String, nil] room name
    # @param setting [Symbol] world setting
    # @param generate_background [Boolean] whether to generate background image
    # @param created_by [Character, nil]
    # @param options [Hash]
    # @return [GenerationJob]
    def generate_room(parent:, room_type:, name: nil, setting: :fantasy,
                      generate_background: false, created_by: nil, options: {})
      steps = generate_background ? 3 : 2

      ProgressTrackerService.with_job(
        type: :room,
        config: { room_type: room_type, name: name, setting: setting },
        created_by: created_by,
        total_steps: steps
      ) do |job|
        Generators::RoomGeneratorService.generate(
          parent: parent,
          room_type: room_type,
          name: name,
          setting: setting,
          generate_background: generate_background,
          options: options
        )
      end
    end

    # Generate seasonal descriptions for a room
    # @param room [Room] the room
    # @param setting [Symbol] world setting
    # @param times [Array<Symbol>] times of day to generate
    # @param seasons [Array<Symbol>] seasons to generate
    # @param created_by [Character, nil]
    # @param options [Hash]
    # @return [GenerationJob]
    def generate_seasonal_descriptions(room:, setting: :fantasy,
                                        times: nil, seasons: nil,
                                        created_by: nil, options: {})
      times ||= Generators::RoomGeneratorService::TIMES_OF_DAY
      seasons ||= Generators::RoomGeneratorService::SEASONS
      total_variants = times.length * seasons.length

      ProgressTrackerService.with_job(
        type: :description,
        config: { target_type: 'room', target_id: room.id, seasonal: true },
        created_by: created_by,
        total_steps: total_variants
      ) do |job|
        Generators::RoomGeneratorService.generate_seasonal_descriptions(
          room: room,
          setting: setting,
          times: times,
          seasons: seasons,
          options: options
        )
      end
    end

    # ========================================
    # Place Generation
    # ========================================

    # Generate a complete place (building with rooms)
    # @param location [Location, nil] where to create the place (or use coordinates)
    # @param longitude [Float, nil] longitude for new location
    # @param latitude [Float, nil] latitude for new location
    # @param place_type [Symbol] type of place
    # @param setting [Symbol] world setting
    # @param generate_rooms [Boolean] whether to generate room descriptions
    # @param generate_npcs [Boolean] whether to generate NPCs
    # @param generate_inventory [Boolean] whether to generate shop inventory
    # @param created_by [Character, nil]
    # @param options [Hash]
    # @return [GenerationJob]
    def generate_place(location: nil, longitude: nil, latitude: nil, place_type:, setting: :fantasy,
                       generate_rooms: true, generate_npcs: false,
                       generate_inventory: false, created_by: nil, options: {})
      steps = 2 + (generate_rooms ? 3 : 0) + (generate_npcs ? 3 : 0) + (generate_inventory ? 2 : 0)

      ProgressTrackerService.with_job(
        type: :place,
        config: { place_type: place_type, setting: setting, longitude: longitude, latitude: latitude },
        created_by: created_by,
        total_steps: steps
      ) do |job|
        Generators::PlaceGeneratorService.generate(
          location: location,
          longitude: longitude,
          latitude: latitude,
          place_type: place_type,
          setting: setting,
          generate_rooms: generate_rooms,
          generate_npcs: generate_npcs,
          generate_inventory: generate_inventory,
          options: options
        )
      end
    end

    # ========================================
    # City Generation
    # ========================================

    # Generate a complete city (async - long operation)
    # @param location [Location, nil] the location to build in (or use coordinates)
    # @param longitude [Float, nil] longitude for new location
    # @param latitude [Float, nil] latitude for new location
    # @param setting [Symbol] world setting
    # @param size [Symbol] city size
    # @param generate_places [Boolean] whether to generate places
    # @param generate_place_rooms [Boolean] whether to generate room descriptions
    # @param generate_npcs [Boolean] whether to generate NPCs
    # @param created_by [Character, nil]
    # @param options [Hash]
    # @return [GenerationJob] the tracking job (runs in background)
    def generate_city(location: nil, longitude: nil, latitude: nil, setting: :fantasy, size: :medium,
                      generate_places: true, generate_place_rooms: false,
                      generate_npcs: false, created_by: nil, options: {})
      job = ProgressTrackerService.create_job(
        type: :city,
        config: {
          location_id: location&.id,
          longitude: longitude,
          latitude: latitude,
          setting: setting,
          size: size,
          generate_places: generate_places,
          generate_place_rooms: generate_place_rooms,
          generate_npcs: generate_npcs
        },
        created_by: created_by
      )

      # Run in background thread due to long operation
      ProgressTrackerService.spawn_async(job: job) do |j|
        ProgressTrackerService.start(job: j, total_steps: 7)

        result = Generators::CityGeneratorService.generate(
          location: location,
          longitude: longitude,
          latitude: latitude,
          setting: setting,
          size: size,
          generate_places: generate_places,
          generate_place_rooms: generate_place_rooms,
          generate_npcs: generate_npcs,
          job: j,
          options: options
        )

        if result[:success]
          ProgressTrackerService.complete(job: j, results: result)
        else
          ProgressTrackerService.fail(job: j, error: result[:errors]&.join(', ') || 'Unknown error')
        end
      end

      job
    end

    # ========================================
    # Description Generation (any target)
    # ========================================

    # Generate description for any target
    # @param target [Room, Character, Item, Pattern] the target object
    # @param setting [Symbol] world setting
    # @param created_by [Character, nil]
    # @param options [Hash]
    # @return [GenerationJob]
    def generate_description(target:, setting: :fantasy, created_by: nil, options: {})
      # Convert class name to snake_case without Rails
      target_type = target.class.name.gsub(/::/, '_').gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase

      ProgressTrackerService.with_job(
        type: :description,
        config: { target_type: target_type, target_id: target.id, setting: setting },
        created_by: created_by,
        total_steps: 2
      ) do |job|
        case target
        when Room
          Generators::RoomGeneratorService.generate_description(
            room: target,
            setting: setting,
            options: options
          )
        when Character
          Generators::NPCGeneratorService.generate_description(
            character: target,
            options: options.merge(setting: setting)
          )
        when Pattern
          Generators::ItemGeneratorService.generate_description(
            pattern: target,
            setting: setting,
            options: options
          )
        else
          { success: false, error: "Unsupported target type: #{target_type}" }
        end
      end
    end

    # ========================================
    # Image Generation (any target)
    # ========================================

    # Generate image for any target
    # @param target [Room, Character, Pattern] the target object
    # @param image_type [Symbol, nil] specific image type or auto-detect
    # @param setting [Symbol] world setting
    # @param created_by [Character, nil]
    # @param options [Hash]
    # @return [GenerationJob]
    def generate_image(target:, image_type: nil, setting: :fantasy, created_by: nil, options: {})
      target_type = NamingHelper.underscore_class_name(target)

      ProgressTrackerService.with_job(
        type: :image,
        config: { target_type: target_type, target_id: target.id, image_type: image_type },
        created_by: created_by,
        total_steps: 2
      ) do |job|
        case target
        when Room
          Generators::RoomGeneratorService.generate_background(
            room: target,
            options: options.merge(setting: setting)
          )
        when Location
          Generators::RoomGeneratorService.generate_location_background(
            location: target,
            options: options.merge(setting: setting)
          )
        when Character
          Generators::NPCGeneratorService.generate_portrait(
            character: target,
            options: options.merge(setting: setting)
          )
        when Pattern
          Generators::ItemGeneratorService.generate_image(
            description: target.description || target.name,
            category: pattern_category(target),
            options: options
          )
        else
          { success: false, error: "Unsupported target type: #{target_type}" }
        end
      end
    end

    # Populate an existing building room with generated content.
    # This is a synchronous helper used by BuilderApi.
    #
    # @param room [Room] building shell or room to populate
    # @param include_npcs [Boolean] whether to generate NPCs
    # @param include_items [Boolean] whether to generate shop inventory
    # @param setting [Symbol] world setting
    # @return [Hash] result payload with created content summaries
    def populate_room(room:, include_npcs: true, include_items: true, setting: :fantasy)
      place_type = infer_place_type_for_room(room)
      config = Generators::PlaceGeneratorService::PLACE_TYPES[place_type] || {}
      rooms = room.contained_rooms_dataset.order(:id).all
      rooms = [room] if rooms.empty?

      result = {
        success: true,
        room_id: room.id,
        place_type: place_type,
        npcs: [],
        items: [],
        errors: []
      }

      if include_npcs
        npc_result = Generators::PlaceGeneratorService.generate_place_npcs(
          place_name: room.name,
          place_type: place_type,
          npc_roles: config[:npc_roles] || ['worker'],
          location: room.location,
          rooms: rooms,
          setting: setting,
          persist: true
        )

        result[:npcs] = Array(npc_result[:npcs]).map do |npc|
          {
            role: npc[:role],
            name: npc[:name],
            character_id: npc[:character]&.id,
            instance_id: npc[:instance]&.id
          }
        end
        result[:errors].concat(Array(npc_result[:errors]))
      end

      if include_items && config[:shop_type]
        inventory_result = Generators::PlaceGeneratorService.generate_shop_inventory(
          shop_type: config[:shop_type],
          place_name: room.name,
          room: rooms.first,
          setting: setting,
          persist: true
        )

        result[:shop] = {
          id: inventory_result[:shop]&.id,
          name: inventory_result[:shop]&.name
        } if inventory_result[:shop]
        result[:items] = inventory_result[:items] || []
        result[:errors].concat(Array(inventory_result[:errors]))
      end

      result[:success] = result[:errors].empty?
      result
    rescue StandardError => e
      warn "[WorldBuilderOrchestratorService] populate_room failed for room #{room&.id}: #{e.message}"
      { success: false, error: e.message, room_id: room&.id, npcs: [], items: [] }
    end

    # ========================================
    # Utility Methods
    # ========================================

    # Check if generation services are available
    # @return [Boolean]
    def available?
      GenerationPipelineService.available?
    end

    # Get active jobs for a character
    # @param character [Character]
    # @return [Array<Hash>]
    def active_jobs_for(character)
      ProgressTrackerService.active_jobs_for(character)
    end

    # Get recent jobs for a character
    # @param character [Character]
    # @param limit [Integer]
    # @return [Array<Hash>]
    def recent_jobs_for(character, limit: 20)
      ProgressTrackerService.recent_jobs_for(character, limit: limit)
    end

    # Get job status
    # @param job_id [Integer]
    # @return [Hash, nil]
    def job_status(job_id)
      job = GenerationJob[job_id]
      return nil unless job

      ProgressTrackerService.progress(job: job)
    end

    # Get job status with authorization check
    # @param job_id [Integer]
    # @param character [Character]
    # @return [Hash, nil] nil when job not found or unauthorized
    def job_status_for(job_id, character)
      job = GenerationJob[job_id]
      return nil unless job
      return nil unless character
      return nil unless job.created_by_id == character.id || character.admin?

      ProgressTrackerService.progress(job: job)
    end

    # Cancel a job
    # @param job_id [Integer]
    # @param character [Character] must be creator or admin
    # @return [Boolean]
    def cancel_job(job_id, character)
      job = GenerationJob[job_id]
      return false unless job
      return false unless job.created_by_id == character.id || character.admin?

      ProgressTrackerService.cancel(job: job)
      true
    end

    private

    # Infer a best-fit place type from an existing room/building.
    def infer_place_type_for_room(room)
      return :general_store unless room

      case room.building_type.to_s
      when 'bar', 'tavern' then :tavern
      when 'hotel', 'inn' then :inn
      when 'restaurant', 'cafe' then :restaurant
      when 'blacksmith' then :blacksmith
      when 'apothecary', 'clinic', 'hospital' then :apothecary
      when 'clothier', 'tailor' then :clothier
      when 'jeweler', 'jewellery' then :jeweler
      when 'temple', 'church' then :temple
      when 'library' then :library
      when 'warehouse', 'factory' then :warehouse
      when 'bank', 'government', 'police_station', 'fire_station' then :bank
      when 'guild_hall', 'office_tower', 'office', 'school' then :guild_hall
      when 'house', 'townhouse', 'brownstone', 'terrace', 'cottage', 'apartment_tower', 'condo_tower' then :townhouse
      when 'mansion' then :mansion
      when 'shop', 'mall', 'store', 'general_store', 'gas_station', 'subway_entrance' then :general_store
      else
        :general_store
      end
    end

    # Determine pattern category
    def pattern_category(pattern)
      return :clothing if pattern.respond_to?(:clothing?) && pattern.clothing?
      return :jewelry if pattern.respond_to?(:jewelry?) && pattern.jewelry?
      return :weapon if pattern.respond_to?(:weapon?) && pattern.weapon?

      :misc
    end
  end
end
