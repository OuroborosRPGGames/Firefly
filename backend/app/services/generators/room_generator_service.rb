# frozen_string_literal: true

module Generators
  # RoomGeneratorService generates room descriptions, seasonal variants, and images
  #
  # Can generate:
  # - Room descriptions (short/long based on room type)
  # - Seasonal description variants (dawn/day/dusk/night × spring/summer/fall/winter)
  # - Room background images (HD or 4K)
  #
  # @example Generate room description
  #   result = Generators::RoomGeneratorService.generate_description(
  #     room: room,
  #     setting: :fantasy
  #   )
  #
  # @example Generate seasonal descriptions
  #   result = Generators::RoomGeneratorService.generate_seasonal_descriptions(
  #     room: room,
  #     setting: :fantasy
  #   )
  #
  # @example Generate room with background
  #   result = Generators::RoomGeneratorService.generate(
  #     parent: location,
  #     room_type: 'tavern',
  #     generate_background: true
  #   )
  #
  class RoomGeneratorService
    # Room type categories for description styling
    ROOM_CATEGORIES = {
      residential: %w[bedroom bathroom kitchen living_room basement attic garage apartment residence],
      commercial: %w[shop office commercial restaurant bar lobby warehouse factory],
      service: %w[guild temple bank hospital],
      entertainment: %w[arena dojo gym nightclub theater museum library],
      outdoor_urban: %w[street avenue intersection alley parking_lot rooftop courtyard plaza garden],
      outdoor_nature: %w[forest beach field swamp meadow hillside mountain desert],
      underground: %w[cave sewer tunnel mine crypt dungeon],
      water: %w[water lake river ocean pool]
    }.freeze

    # Map room categories to photographic framing categories
    FRAMING_CATEGORY_MAP = {
      outdoor_urban: :outdoor_urban,
      outdoor_nature: :outdoor_nature,
      water: :outdoor_nature,
      underground: :underground
    }.freeze

    # Times of day for seasonal generation
    TIMES_OF_DAY = %i[dawn day dusk night].freeze

    # Seasons for seasonal generation
    SEASONS = %i[spring summer fall winter].freeze

    class << self
      # Generate a complete room (description + optional background)
      # @param parent [Location, Room] parent container
      # @param room_type [String] room type
      # @param name [String, nil] room name (generated if not provided)
      # @param setting [Symbol] world setting
      # @param generate_background [Boolean] whether to generate background image
      # @param options [Hash] additional options
      # @return [Hash] { success:, room:, description:, background_url:, errors: }
      def generate(parent:, room_type:, name: nil, setting: :fantasy,
                   generate_background: false, options: {})
        results = { success: false, errors: [] }

        # Get seed terms (5 terms, LLM picks 1-2)
        seed_terms = options[:seed_terms] || SeedTermService.for_generation(:room, count: 5)
        results[:seed_terms] = seed_terms

        if name
          # Name already provided — only generate description
          results[:name] = name

          desc_result = generate_description_for_type(
            name: name,
            room_type: room_type,
            parent: parent,
            setting: setting,
            seed_terms: seed_terms,
            options: options
          )

          results[:description] = desc_result[:content]
          results[:errors] << desc_result[:error] if desc_result[:error]
        else
          # No name — generate name + description together for consistency
          profile_result = generate_named_room(
            room_type: room_type,
            parent: parent,
            setting: setting,
            seed_terms: seed_terms
          )

          if profile_result[:success]
            results[:name] = profile_result[:name]
            results[:description] = profile_result[:description]
          else
            results[:errors] << profile_result[:error]
            # Fallback name
            results[:name] = "#{NamingHelper.titleize(room_type.to_s)} Room"
          end
        end

        # Generate background if requested
        if generate_background && results[:description]
          room_stub = Struct.new(:description, :short_description, :name, :room_type, :visible_places, :visible_decorations)
                            .new(results[:description], nil, results[:name], room_type, [], [])
          bg_result = generate_background(
            room: room_stub,
            options: options.merge(setting: setting)
          )

          results[:background_url] = bg_result[:local_url] || bg_result[:url]
          results[:errors] << bg_result[:error] if bg_result[:error]
        end

        results[:success] = !results[:description].nil?
        results
      end

      # Generate room name + description in a single LLM call for consistency
      # @param room_type [String] type of room
      # @param parent [Location, Hash] parent location
      # @param setting [Symbol] world setting
      # @param seed_terms [Array<String>]
      # @return [Hash] { success:, name:, description:, error: }
      def generate_named_room(room_type:, parent:, setting: :fantasy, seed_terms: [])
        category = categorize_room_type(room_type)
        parent_name = parent.respond_to?(:name) ? parent.name : 'the building'
        parent_context = parent_name ? "within #{parent_name}" : ''

        prompt = GamePrompts.get('room_generation.name_and_description',
                                 setting: setting,
                                 room_type: room_type,
                                 parent_context: parent_context,
                                 tech_constraints: tech_constraints_for_setting(setting),
                                 terms_str: seed_terms.join(', '),
                                 category_guidance: room_category_guidance(category, room_type))

        result = GenerationPipelineService.generate_structured(
          prompt: prompt,
          tool_name: 'save_room',
          tool_description: 'Save the generated room name and description',
          parameters: {
            type: 'object',
            properties: {
              name: { type: 'string', description: 'Room name, 1-4 words' },
              description: { type: 'string', description: 'Room description, 2-4 sentences' }
            },
            required: %w[name description]
          }
        )

        unless result[:success] && result[:data]
          return { success: false, error: result[:error] || 'Room generation failed' }
        end

        data = result[:data]
        name = (data['name'] || '').strip.gsub(/^["']|["']$/, '')

        {
          success: true,
          name: name,
          description: data['description']
        }
      rescue StandardError => e
        warn "[RoomGeneratorService] Named room generation failed: #{e.message}"
        { success: false, error: "Room generation failed: #{e.message}" }
      end

      # Generate room name
      # @param room_type [String]
      # @param parent_name [String, nil] name of containing location/building
      # @param setting [Symbol]
      # @param seed_terms [Array<String>]
      # @return [Hash] { success:, name:, error: }
      def generate_name(room_type:, parent_name: nil, setting: :fantasy, seed_terms: [])
        parent_context = parent_name ? "within #{parent_name}" : ''

        prompt = GamePrompts.get('room_generation.name',
                                 setting: setting,
                                 room_type: room_type,
                                 parent_context: parent_context,
                                 terms_str: seed_terms.join(', '))

        result = GenerationPipelineService.generate_simple(prompt: prompt)

        if result[:success]
          name = result[:content].to_s.strip
          name = name.gsub(/^[\"']|[\"']$/, '') # Remove quotes
          { success: true, name: name }
        else
          { success: false, name: nil, error: result[:error] }
        end
      end

      # Generate description for an existing room
      # @param room [Room] the room to describe
      # @param setting [Symbol] world setting
      # @param seed_terms [Array<String>, nil]
      # @param options [Hash]
      # @return [Hash] { success:, content:, validated:, error: }
      def generate_description(room:, setting: :fantasy, seed_terms: nil, options: {})
        seed_terms ||= SeedTermService.for_generation(:room, count: 5)

        generate_description_for_type(
          name: room.name,
          room_type: room.room_type,
          parent: room.location,
          setting: setting,
          seed_terms: seed_terms,
          existing_description: room.description,
          options: options
        )
      end

      # Generate seasonal description variants for a room
      # @param room [Room] the room
      # @param setting [Symbol] world setting
      # @param times [Array<Symbol>] times of day to generate (default: all)
      # @param seasons [Array<Symbol>] seasons to generate (default: all)
      # @param options [Hash]
      # @return [Hash] { success:, descriptions: {time_season: desc}, errors: }
      def generate_seasonal_descriptions(room:, setting: :fantasy,
                                         times: TIMES_OF_DAY, seasons: SEASONS, options: {})
        results = { success: false, descriptions: {}, errors: [] }
        base_desc = room.description || room.short_description

        # Generate base if needed
        unless base_desc
          base_result = generate_description(room: room, setting: setting, options: options)
          base_desc = base_result[:content]
          results[:errors] << base_result[:error] if base_result[:error]
        end

        return results.merge(success: false, error: 'No base description') unless base_desc

        # Generate variants for each time/season combo
        times.each do |time|
          seasons.each do |season|
            variant_result = generate_seasonal_variant(
              base_description: base_desc,
              room_type: room.room_type,
              time_of_day: time,
              season: season,
              setting: setting
            )

            key = "#{time}_#{season}"
            if variant_result[:success]
              results[:descriptions][key] = variant_result[:content]
            else
              results[:errors] << "#{key}: #{variant_result[:error]}"
            end
          end
        end

        results[:success] = results[:descriptions].any?
        results
      end

      # Generate a single seasonal variant
      # @param base_description [String] the base room description
      # @param room_type [String]
      # @param time_of_day [Symbol] :dawn, :day, :dusk, :night
      # @param season [Symbol] :spring, :summer, :fall, :winter
      # @param setting [Symbol]
      # @return [Hash] { success:, content:, error: }
      def generate_seasonal_variant(base_description:, room_type:, time_of_day:, season:, setting: :fantasy)
        prompt = GamePrompts.get('room_generation.seasonal_variant',
                                 time_of_day: time_of_day,
                                 season: season,
                                 base_description: base_description,
                                 lighting: lighting_for_time(time_of_day),
                                 weather: weather_hints_for_season(season),
                                 room_type: room_type,
                                 setting: setting)

        GenerationPipelineService.generate_with_validation(
          prompt: prompt,
          content_type: :room_description,
          max_retries: 1
        )
      end

      # Generate background image for room using structured prompt
      # @param room [Room] the room to generate background for
      # @param options [Hash] additional options
      # @return [Hash] { success:, url:, local_url:, error: }
      def generate_background(room:, options: {})
        image_type = options[:resolution] == :hd_4k ? :room_background_4k : :room_background

        setting = (options[:setting] || :fantasy).to_sym
        prompt = build_room_image_prompt(room, setting: setting)

        result = WorldBuilderImageService.generate(
          type: image_type,
          description: prompt,
          options: { save_locally: true }
        )

        return result unless result[:success]

        # Upscale to 4K via Replicate if available
        upscale_result = maybe_upscale(result[:local_path])
        if upscale_result
          result[:url] = upscale_result
          result[:local_url] = upscale_result
        end

        # Queue async mask generation (non-blocking)
        queue_mask_generation(room) if result[:success]

        result
      end

      # Generate background image for a location/area using structured prompt
      # @param location [Location] the location to generate background for
      # @param options [Hash] additional options
      # @return [Hash] { success:, url:, local_url:, error: }
      def generate_location_background(location:, options: {})
        setting = (options[:setting] || :fantasy).to_sym
        prompt = build_location_image_prompt(location, setting: setting)

        result = WorldBuilderImageService.generate(
          type: :location_background,
          description: prompt,
          options: { save_locally: true }
        )

        return result unless result[:success]

        upscale_result = maybe_upscale(result[:local_path])
        if upscale_result
          result[:url] = upscale_result
          result[:local_url] = upscale_result
        end

        result
      end

      # Generate multiple room descriptions in batch
      # @param rooms [Array<Room>]
      # @param setting [Symbol]
      # @param options [Hash]
      # @return [Array<Hash>]
      def generate_descriptions_batch(rooms:, setting: :fantasy, options: {})
        rooms.map do |room|
          result = generate_description(room: room, setting: setting, options: options)
          { room_id: room.id, **result }
        end
      end

      # Generate description for a room type (also called by PlaceGeneratorService)
      # @param name [String] room name
      # @param room_type [String] type of room
      # @param parent [Location, Hash] parent location (or hash with :name key)
      # @param setting [Symbol] world setting
      # @param seed_terms [Array<String>] seed terms for inspiration
      # @param existing_description [String, nil] description to enhance
      # @param options [Hash] additional options
      # @return [Hash] { success:, content:, error: }
      def generate_description_for_type(name:, room_type:, parent:, setting:, seed_terms:,
                                        existing_description: nil, options: {})
        category = categorize_room_type(room_type)
        terms_str = seed_terms.join(', ')
        parent_name = parent.respond_to?(:name) ? parent.name : 'the building'

        prompt = build_room_description_prompt(
          name: name,
          room_type: room_type,
          category: category,
          parent_name: parent_name,
          setting: setting,
          terms_str: terms_str,
          existing_description: existing_description
        )

        GenerationPipelineService.generate_with_validation(
          prompt: prompt,
          content_type: :room_description,
          max_retries: options[:max_retries] || 2
        )
      end

      private

      # Build the room description prompt
      def build_room_description_prompt(name:, room_type:, category:, parent_name:, setting:, terms_str:, existing_description:)
        category_guidance = room_category_guidance(category, room_type)

        enhancement = if existing_description
                        "\nExisting description to enhance: #{existing_description}"
                      else
                        ''
                      end

        tech_constraints = tech_constraints_for_setting(setting)

        GamePrompts.get('room_generation.description',
                        setting: setting,
                        name: name,
                        room_type: room_type,
                        parent_name: parent_name,
                        tech_constraints: tech_constraints,
                        terms_str: terms_str,
                        category_guidance: category_guidance,
                        enhancement: enhancement)
      end

      # Build photographic prompt for room background generation
      def build_room_image_prompt(room, setting: :fantasy)
        description = room.description || room.short_description || room.name

        # Look up era profile, fallback to fantasy
        profile = GamePrompts.photo_profile(setting) || GamePrompts.photo_profile(:fantasy)

        # Determine framing category from room type
        room_category = categorize_room_type(room.respond_to?(:room_type) ? room.room_type : 'general')
        framing_key = FRAMING_CATEGORY_MAP[room_category] || :indoor
        framing = GamePrompts.room_framing(framing_key) || GamePrompts.room_framing(:indoor)

        # Pick lens: framing override or era default
        lens = framing[:lens_override] || profile[:default_lens]

        # Assemble prompt
        lines = []

        # Opening: film still + camera + lens (separated from description)
        film_stock_part = if profile[:film_stock] && !profile[:film_stock].empty?
                           "shot on #{profile[:film_stock]}"
                         else
                           nil
                         end
        camera_parts = ["Film still from a #{profile[:genre_phrase]} movie production", profile[:camera], lens, film_stock_part].compact
        lines << "#{camera_parts.join(', ')}."

        # Set description separate from camera line
        lines << "Set description: #{description}."

        # Furniture and decorations
        furniture_names = room.visible_places.select { |p| p.is_furniture }.map(&:name)
        decoration_names = room.visible_decorations.map(&:name)
        lines << "Furniture: #{furniture_names.join(', ')}" unless furniture_names.empty?
        lines << "Decorations: #{decoration_names.join(', ')}" unless decoration_names.empty?

        # Lighting + framing
        lighting = [profile[:lighting], framing[:lighting_extra]].compact.join(', ')
        lines << "#{lighting}, #{framing[:framing]}."

        # Imperfections + directives
        lines << "#{profile[:imperfections]}. No people, cast, or film crew currently present on set. 16:9 composition."

        lines.join("\n")
      end

      # Build photographic prompt for location/area background generation
      def build_location_image_prompt(location, setting: :fantasy)
        description = location.default_description || location.name

        # Look up era profile, fallback to fantasy
        profile = GamePrompts.photo_profile(setting) || GamePrompts.photo_profile(:fantasy)

        lens = profile[:default_lens]

        film_stock_part = if profile[:film_stock] && !profile[:film_stock].empty?
                           "shot on #{profile[:film_stock]}"
                         else
                           nil
                         end

        lines = []
        camera_parts = ["Film still from a #{profile[:genre_phrase]} movie production", profile[:camera], lens, film_stock_part].compact
        lines << "#{camera_parts.join(', ')}."
        lines << "Set description: #{description}."
        lines << "#{profile[:lighting]}, panoramic establishing shot."
        lines << "#{profile[:imperfections]}. No people, cast, or film crew currently present on set. 16:9 composition."
        lines.join("\n")
      end

      # Upscale image via Replicate if available, upload to cloud, return URL
      # @param local_path [String, nil] local filesystem path of generated image
      # @return [String, nil] upscaled cloud URL, or nil if skipped/failed
      def maybe_upscale(local_path)
        return nil unless local_path && ReplicateUpscalerService.available?

        upscale_result = ReplicateUpscalerService.upscale(local_path, scale: 4)

        unless upscale_result[:success]
          warn "[RoomGeneratorService] Replicate upscale failed: #{upscale_result[:error]}"
          return nil
        end

        output_path = upscale_result[:output_path]
        ext = File.extname(output_path).downcase

        unless %w[.jpg .jpeg .png .webp].include?(ext)
          warn "[RoomGeneratorService] Unexpected upscaled image extension: #{ext}"
          return nil
        end

        begin
          image_data = File.binread(output_path)
        rescue Errno::ENOENT
          warn "[RoomGeneratorService] Upscaled image file not found: #{output_path}"
          return nil
        end

        mime = case ext
               when '.jpg', '.jpeg' then 'image/jpeg'
               when '.png' then 'image/png'
               when '.webp' then 'image/webp'
               else 'application/octet-stream'
               end
        date_path = Time.now.strftime('%Y/%m')
        key = "generated/#{date_path}/#{SecureRandom.hex(12)}#{ext}"

        CloudStorageService.upload(image_data, key, content_type: mime)
      rescue StandardError => e
        warn "[RoomGeneratorService] Failed to upload upscaled image: #{e.message}"
        nil
      end

      # Queue background mask generation for persisted rooms.
      # Uses Sidekiq when available; falls back to a guarded background thread.
      def queue_mask_generation(room)
        return unless room.is_a?(Room) && room.id

        if defined?(MaskGenerationJob)
          MaskGenerationJob.perform_async(room.id)
        else
          Thread.new do
            Thread.current.report_on_exception = false if Thread.current.respond_to?(:report_on_exception=)
            begin
              MaskGenerationService.generate(room)
            rescue StandardError => e
              warn "[RoomGeneratorService] Async mask generation failed: #{e.message}"
            end
          end
        end
      rescue StandardError => e
        warn "[RoomGeneratorService] Failed to queue mask generation for room #{room&.id}: #{e.message}"
      end

      # Get technology constraints for a setting
      def tech_constraints_for_setting(setting)
        case setting.to_sym
        when :fantasy
          'CRITICAL: This is a medieval fantasy setting. NO electricity, engines, motors, machines, modern technology, or industrial equipment. Use only period-appropriate elements: torches, candles, hearths, hand tools, natural materials.'
        when :scifi
          'Use futuristic technology: holographic displays, energy sources, automated systems.'
        else
          ''
        end
      end

      # Get guidance based on room category
      def room_category_guidance(category, room_type)
        case category
        when :residential
          'Focus on comfort, personalization, and lived-in details. What makes this space a home?'
        when :commercial
          "Focus on purpose and activity. What business happens here? What is the bustle like?"
        when :service
          'Focus on the service provided and the atmosphere. Who comes here and why?'
        when :entertainment
          'Focus on excitement and atmosphere. What draws people here?'
        when :outdoor_urban
          "This is an OUTDOOR urban space — open to the sky. No interior walls, no ceiling, no doors. Focus on the urban landscape, street surfaces, and activity."
        when :outdoor_nature
          'This is an OUTDOOR natural space — open to the sky. No walls, no ceiling, no doors, no windows, no flagstone floors, no built structures. Only describe natural terrain, vegetation, rocks, water, weather, and wildlife.'
        when :underground
          'This is an UNDERGROUND space — no windows, no natural light, no sky. Focus on darkness, stone/earth walls, confined passages, damp air, and subterranean atmosphere.'
        when :water
          "Focus on water features and aquatic atmosphere. What is the water like?"
        else
          "Focus on the distinctive features of this #{room_type}."
        end
      end

      # Categorize room type
      def categorize_room_type(room_type)
        ROOM_CATEGORIES.each do |category, types|
          return category if types.include?(room_type.to_s)
        end
        :general
      end

      # Get lighting description for time of day
      def lighting_for_time(time)
        case time.to_sym
        when :dawn
          'Soft golden light filters in, shadows retreating as the sun rises'
        when :day
          'Bright daylight illuminates the space, casting clear shadows'
        when :dusk
          'Warm orange light streams in at a low angle, long shadows stretching across'
        when :night
          'Darkness prevails, only artificial light sources provide visibility'
        else
          'Natural lighting appropriate to the time'
        end
      end

      # Get weather hints for season
      def weather_hints_for_season(season)
        case season.to_sym
        when :spring
          'Fresh air, new growth sounds from outside, occasional rain on windows'
        when :summer
          'Warm air, sounds of insects and birds, bright harsh light'
        when :fall
          'Crisp air, falling leaves visible outside, golden light quality'
        when :winter
          'Cold seeping in, silence of snow, pale weak light, frost on surfaces'
        else
          'Weather appropriate to the season'
        end
      end
    end
  end
end
