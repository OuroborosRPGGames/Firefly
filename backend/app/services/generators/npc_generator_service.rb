# frozen_string_literal: true

module Generators
  # NPCGeneratorService generates NPC characters with descriptions, portraits, and schedules
  #
  # Can generate:
  # - NPC names (via NameGeneratorService + LLM selection)
  # - Physical appearance descriptions
  # - Personality traits
  # - Character portraits
  # - Daily schedules
  #
  # @example Generate a complete NPC
  #   result = Generators::NPCGeneratorService.generate(
  #     location: room.location,
  #     role: 'shopkeeper',
  #     setting: :fantasy
  #   )
  #
  # @example Generate portrait for existing NPC
  #   result = Generators::NPCGeneratorService.generate_portrait(
  #     character: npc,
  #     options: { setting: :fantasy }
  #   )
  #
  class NPCGeneratorService
    # Common NPC roles for generation
    NPC_ROLES = {
      service: %w[shopkeeper innkeeper barkeep server cook stable_hand],
      guard: %w[guard soldier watchman bouncer bodyguard],
      craft: %w[blacksmith tailor cobbler jeweler carpenter mason],
      learned: %w[scribe scholar librarian healer priest mage],
      street: %w[beggar urchin street_vendor entertainer thief],
      noble: %w[noble merchant banker guild_master diplomat],
      common: %w[farmer laborer miner fisherman hunter],
      misc: %w[traveler pilgrim refugee adventurer mercenary]
    }.freeze

    class << self
      # Generate a complete NPC
      # @param location [Location] where the NPC should exist
      # @param role [String, nil] NPC role/occupation
      # @param gender [Symbol] :male, :female, :neutral, :any
      # @param culture [Symbol] cultural background for naming
      # @param setting [Symbol] world setting
      # @param generate_portrait [Boolean] whether to generate portrait
      # @param generate_schedule [Boolean] whether to generate schedule
      # @param options [Hash] additional options
      # @return [Hash] { success:, character:, description:, portrait_url:, schedule:, errors: }
      def generate(location:, role: nil, gender: :any, culture: :western, setting: :fantasy,
                   generate_portrait: false, generate_schedule: false, options: {})
        results = { success: false, errors: [] }

        # Get seed terms for personality/appearance (5 terms, LLM picks 1-2)
        seed_terms = options[:seed_terms] || SeedTermService.for_generation(:npc, count: 5)
        results[:seed_terms] = seed_terms

        # Determine role if not specified
        role ||= select_random_role(setting)
        results[:role] = role

        # Generate name using NameGeneratorService + LLM selection
        name_result = generate_name(
          gender: gender,
          culture: culture,
          role: role,
          setting: setting,
          seed_terms: seed_terms
        )

        unless name_result[:success]
          results[:errors] << name_result[:error]
          return results
        end
        results[:name] = name_result

        full_name = name_result[:full_name]
        gender_str = gender_string(gender, name_result[:gender_used])

        # Generate profile and schedule in parallel (profile is a single combined call)
        threads = []

        threads << Thread.new do
          Thread.current[:key] = :profile
          Thread.current[:result] = generate_character_profile(
            name: full_name, gender: gender_str, role: role,
            setting: setting, seed_terms: seed_terms
          )
        end

        if generate_schedule
          threads << Thread.new do
            Thread.current[:key] = :schedule
            Thread.current[:result] = generate_daily_schedule(
              name: full_name, role: role, location: location, setting: setting
            )
          end
        end

        threads.each { |t| t.join(120) }

        # Collect results from threads
        threads.each do |t|
          key = t[:key]
          res = t[:result]
          next unless res

          case key
          when :profile
            if res[:success]
              results[:appearance] = res[:appearance]
              results[:short_desc] = res[:short_desc]
              results[:personality] = res[:personality]
            end
            results[:errors] << res[:error] if res[:error]
          when :schedule
            results[:schedule] = res[:schedule] if res[:success]
            results[:errors] << res[:error] if res[:error]
          end
        end

        # Generate portrait if requested (depends on appearance)
        if generate_portrait && results[:appearance]
          portrait_result = generate_portrait_image(
            appearance: results[:appearance],
            setting: setting,
            options: options
          )

          results[:portrait_url] = portrait_result[:local_url] || portrait_result[:url]
          results[:errors] << portrait_result[:error] if portrait_result[:error]
        end

        results[:success] = results[:name] && results[:appearance]
        results
      end

      # Generate NPC name using NameGeneratorService + LLM selection
      # @param gender [Symbol] :male, :female, :neutral, :any
      # @param culture [Symbol] culture for name generation
      # @param role [String] NPC role for context
      # @param setting [Symbol] world setting
      # @param seed_terms [Array<String>]
      # @return [Hash] { success:, forename:, surname:, full_name:, gender_used:, error: }
      def generate_name(gender: :any, culture: :western, role: nil, setting: :fantasy, seed_terms: [])
        # Get multiple name options
        begin
          options = NameGeneratorService.character_options(
            count: 5,
            gender: gender,
            culture: culture,
            setting: setting
          )

          if options.empty?
            return { success: false, error: 'No name options generated' }
          end

          # Format options for LLM selection
          name_strings = options.map do |opt|
            opt.respond_to?(:full_name) ? opt.full_name : "#{opt.forename} #{opt.surname}".strip
          end

          # Use LLM to select best name
          selection_result = GenerationPipelineService.select_best_name(
            options: name_strings,
            context: {
              role: role || 'NPC',
              setting: setting,
              vibe: seed_terms.first(2).join(', ')
            }
          )

          selected_name = selection_result[:selected] || name_strings.first
          selected_option = options.find do |opt|
            full = opt.respond_to?(:full_name) ? opt.full_name : "#{opt.forename} #{opt.surname}".strip
            full == selected_name
          end || options.first

          {
            success: true,
            forename: selected_option.forename,
            surname: selected_option.respond_to?(:surname) ? selected_option.surname : nil,
            full_name: selected_name,
            gender_used: selected_option.respond_to?(:gender) ? selected_option.gender : gender,
            reasoning: selection_result[:reasoning]
          }
        rescue StandardError => e
          { success: false, error: "Name generation failed: #{e.message}" }
        end
      end

      # Generate combined character profile (appearance + short_desc + personality)
      # Single LLM call for consistency across all character attributes
      # @param name [String] NPC's name
      # @param gender [String] gender string
      # @param role [String] NPC role
      # @param setting [Symbol] world setting
      # @param seed_terms [Array<String>]
      # @return [Hash] { success:, appearance:, short_desc:, personality:, error: }
      def generate_character_profile(name:, gender:, role:, setting: :fantasy, seed_terms: [])
        prompt = GamePrompts.get('npc_generation.character_profile',
                                 name: name,
                                 gender: gender,
                                 role: role,
                                 setting: setting,
                                 terms_str: seed_terms.join(', '))

        result = GenerationPipelineService.generate_structured(
          prompt: prompt,
          tool_name: 'save_character_profile',
          tool_description: 'Save the generated character profile with appearance, short description, and personality',
          parameters: {
            type: 'object',
            properties: {
              appearance: { type: 'string', description: '3-5 sentences describing physical appearance' },
              short_desc: { type: 'string', description: 'Brief descriptor like "a grizzled old blacksmith", max 60 chars' },
              personality: { type: 'string', description: '2-4 sentences describing personality traits and behavior' }
            },
            required: %w[appearance short_desc personality]
          }
        )

        unless result[:success] && result[:data]
          return { success: false, error: result[:error] || 'Character profile generation failed' }
        end

        data = result[:data]

        # Post-process short_desc (same rules as before)
        short_desc = (data['short_desc'] || '').strip.downcase.gsub(/[""".]/, '')
        short_desc = "a #{short_desc}" unless short_desc.start_with?('a ') || short_desc.start_with?('an ')
        short_desc = short_desc[0..59] if short_desc.length > 60

        {
          success: true,
          appearance: data['appearance'],
          short_desc: short_desc,
          personality: data['personality'],
          error: nil
        }
      rescue StandardError => e
        warn "[NPCGeneratorService] Character profile failed: #{e.message}"
        { success: false, error: "Character profile failed: #{e.message}" }
      end

      # Generate physical appearance description
      # @param name [String] NPC's name
      # @param gender [String] gender string
      # @param role [String] NPC role
      # @param setting [Symbol] world setting
      # @param seed_terms [Array<String>]
      # @return [Hash] { success:, content:, error: }
      def generate_appearance(name:, gender:, role:, setting: :fantasy, seed_terms: [])
        prompt = GamePrompts.get('npc_generation.physical_appearance',
                                 name: name,
                                 gender: gender,
                                 role: role,
                                 setting: setting,
                                 terms_str: seed_terms.join(', '))

        GenerationPipelineService.generate_with_validation(
          prompt: prompt,
          content_type: :npc_description,
          max_retries: 2
        )
      end

      # Generate a brief short description (e.g., "a buxom barmaid")
      # @param name [String] NPC's name
      # @param gender [String] gender string
      # @param role [String] NPC role
      # @return [Hash] { success:, content:, error: }
      def generate_short_desc(name:, gender:, role:)
        prompt = GamePrompts.get('npc_generation.short_description',
                                 name: name,
                                 gender: gender,
                                 role: role)

        result = GenerationPipelineService.generate_with_validation(
          prompt: prompt,
          max_retries: 1
        )

        # Clean up the result - ensure it starts with "a"/"an" and is brief
        if result[:success] && result[:content]
          desc = result[:content].strip.downcase.gsub(/[""".]/, '')
          desc = "a #{desc}" unless desc.start_with?('a ') || desc.start_with?('an ')
          desc = desc[0..59] if desc.length > 60 # Hard cap
          result[:content] = desc
        end

        result
      end

      # Generate personality traits
      # @param name [String] NPC's name
      # @param role [String] NPC role
      # @param setting [Symbol] world setting
      # @param seed_terms [Array<String>]
      # @return [Hash] { success:, content:, error: }
      def generate_personality(name:, role:, setting: :fantasy, seed_terms: [])
        prompt = GamePrompts.get('npc_generation.personality',
                                 name: name,
                                 role: role,
                                 setting: setting,
                                 terms_str: seed_terms.join(', '))

        GenerationPipelineService.generate_with_validation(
          prompt: prompt,
          max_retries: 1
        )
      end

      # Generate portrait image for NPC
      # @param appearance [String] appearance description
      # @param setting [Symbol] world setting
      # @param options [Hash]
      # @return [Hash] { success:, url:, local_url:, error: }
      def generate_portrait_image(appearance:, setting: :fantasy, options: {})
        WorldBuilderImageService.generate(
          type: :npc_portrait,
          description: appearance,
          options: options.merge(
            setting: setting,
            save_locally: true
          )
        )
      end

      # Generate portrait for existing character
      # @param character [Character] the character
      # @param options [Hash]
      # @return [Hash]
      def generate_portrait(character:, options: {})
        # Use existing description or generate one
        appearance = character.long_desc || character.short_desc

        unless appearance
          gender = character.is_female? ? 'female' : (character.is_male? ? 'male' : 'person')
          seed_terms = SeedTermService.for_generation(:npc, count: 5)

          appearance_result = generate_appearance(
            name: character.full_name,
            gender: gender,
            role: character.npc_archetype&.name || 'NPC',
            setting: options[:setting] || :fantasy,
            seed_terms: seed_terms
          )

          appearance = appearance_result[:content] if appearance_result[:success]
        end

        return { success: false, error: 'No appearance description available' } unless appearance

        generate_portrait_image(
          appearance: appearance,
          setting: options[:setting] || :fantasy,
          options: options
        )
      end

      # Generate daily schedule for NPC
      # @param name [String] NPC's name
      # @param role [String] NPC role
      # @param location [Location] where they live/work
      # @param setting [Symbol] world setting
      # @return [Hash] { success:, schedule: [{time:, activity:, location:}], error: }
      def generate_daily_schedule(name:, role:, location:, setting: :fantasy)
        location_name = location.respond_to?(:name) ? location.name : 'the area'

        prompt = GamePrompts.get('npc_generation.daily_schedule',
                                 name: name,
                                 role: role,
                                 location_name: location_name,
                                 setting: setting)

        result = GenerationPipelineService.generate_simple(prompt: prompt)

        unless result[:success]
          return { success: false, schedule: nil, error: result[:error] }
        end

        begin
          # Parse JSON from response
          json_match = result[:content].match(/\[[\s\S]*\]/)
          schedule = JSON.parse(json_match[0]) if json_match

          if schedule && schedule.is_a?(Array) && schedule.any?
            { success: true, schedule: schedule }
          else
            { success: false, schedule: nil, error: 'Invalid schedule format' }
          end
        rescue JSON::ParserError => e
          { success: false, schedule: nil, error: "Schedule parse error: #{e.message}" }
        end
      end

      # Generate description for existing NPC
      # @param character [Character] the NPC
      # @param options [Hash]
      # @return [Hash]
      def generate_description(character:, options: {})
        seed_terms = options[:seed_terms] || SeedTermService.for_generation(:npc, count: 5)
        gender = character.is_female? ? 'female' : (character.is_male? ? 'male' : 'person')
        role = character.npc_archetype&.name || 'NPC'

        generate_appearance(
          name: character.full_name,
          gender: gender,
          role: role,
          setting: options[:setting] || :fantasy,
          seed_terms: seed_terms
        )
      end

      private

      # Select a random role appropriate for the setting
      def select_random_role(setting)
        # Weight toward common and service roles
        weighted_categories = [:service] * 3 + [:craft] * 2 + [:common] * 2 +
                              [:guard] + [:learned] + [:street] + [:noble] + [:misc]

        category = weighted_categories.sample
        NPC_ROLES[category].sample
      end

      # Convert gender symbol to string
      def gender_string(requested, used)
        gender = used || requested
        case gender.to_sym
        when :male then 'male'
        when :female then 'female'
        when :neutral then 'non-binary'
        else 'person'
        end
      end

      # Check if a term is personality-related
      def personality_term?(term)
        personality_words = %w[
          bold cautious clever cunning curious friendly grumpy honest
          humble kind lazy loyal nervous patient proud quiet reckless
          secretive shy stubborn suspicious timid wise witty zealous
        ]
        personality_words.any? { |w| term.to_s.downcase.include?(w) }
      end
    end
  end
end
