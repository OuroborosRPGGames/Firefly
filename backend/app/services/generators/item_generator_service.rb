# frozen_string_literal: true

module Generators
  # ItemGeneratorService generates item descriptions and images
  #
  # Can generate:
  # - Item names/strings (short identifiers)
  # - Item descriptions (full prose descriptions)
  # - Item images (product shots on black/gray backgrounds)
  #
  # @example Generate item description
  #   result = Generators::ItemGeneratorService.generate_description(
  #     pattern: pattern,
  #     setting: :fantasy,
  #     seed_terms: ['ornate', 'mysterious']
  #   )
  #
  # @example Generate clothing with image
  #   result = Generators::ItemGeneratorService.generate(
  #     category: :clothing,
  #     subcategory: 'dress',
  #     setting: :fantasy,
  #     generate_image: true
  #   )
  #
  class ItemGeneratorService
    CATEGORIES = %i[clothing jewelry weapon consumable furniture misc].freeze

    # Image styles for different item types
    IMAGE_STYLES = {
      clothing: :item_on_model,
      jewelry: :item_on_black,
      weapon: :item_on_black,
      consumable: :item_on_black,
      furniture: :furniture,
      misc: :item_on_black
    }.freeze

    class << self
      # Generate a complete item (description + optional image)
      # @param category [Symbol] item category
      # @param subcategory [String, nil] more specific type
      # @param setting [Symbol] world setting (:fantasy, :modern, :scifi)
      # @param seed_terms [Array<String>, nil] optional seed terms (auto-generated if nil)
      # @param generate_image [Boolean] whether to generate image
      # @param options [Hash] additional options
      # @return [Hash] { success:, description:, name:, image_url:, seed_terms:, errors: }
      def generate(category:, subcategory: nil, setting: :fantasy, seed_terms: nil,
                   generate_image: false, options: {})
        results = { success: false, errors: [] }

        # Get seed terms if not provided (5 terms, LLM picks 1-2)
        seed_terms ||= SeedTermService.for_generation(:item, count: 5)
        results[:seed_terms] = seed_terms

        # Generate name + description in a single call for consistency
        profile_result = generate_item_profile(
          category: category,
          subcategory: subcategory,
          setting: setting,
          seed_terms: seed_terms
        )

        if profile_result[:success]
          results[:name] = profile_result[:name]
          results[:description] = profile_result[:description]
        else
          results[:errors] << profile_result[:error]
          return results
        end

        # Generate image if requested
        if generate_image && results[:description]
          image_result = generate_image(
            description: results[:description],
            category: category,
            options: options
          )

          results[:image_url] = image_result[:local_url] || image_result[:url]
          results[:errors] << image_result[:error] if image_result[:error]
        end

        results[:success] = !results[:description].nil?
        results
      end

      # Generate item name + description in a single LLM call for consistency
      # @param category [Symbol]
      # @param subcategory [String, nil]
      # @param setting [Symbol]
      # @param seed_terms [Array<String>]
      # @return [Hash] { success:, name:, description:, error: }
      def generate_item_profile(category:, subcategory: nil, setting: :fantasy, seed_terms: [])
        type_str = subcategory || category.to_s
        category_config = CATEGORY_CONFIGS[category] || CATEGORY_CONFIGS[:misc]

        prompt = GamePrompts.get('generators.item_profile',
                                 setting: setting,
                                 type_str: type_str,
                                 terms_str: seed_terms.join(', '),
                                 mandatory_attributes: category_config[:mandatory].map { |attr| "- #{attr}" }.join("\n"),
                                 style_guidance: category_config[:guidance])

        result = GenerationPipelineService.generate_structured(
          prompt: prompt,
          tool_name: 'save_item',
          tool_description: 'Save the generated item name and description',
          parameters: {
            type: 'object',
            properties: {
              name: { type: 'string', description: 'Short descriptive item name, 5-12 words' },
              description: { type: 'string', description: 'Detailed item description, 2-3 sentences' }
            },
            required: %w[name description]
          }
        )

        unless result[:success] && result[:data]
          return { success: false, error: result[:error] || 'Item generation failed' }
        end

        data = result[:data]
        # Clean up name same as generate_name does
        name = (data['name'] || '').strip.downcase.gsub(/^["']|["']$/, '').gsub(/^(a |an |the )/, '')

        {
          success: true,
          name: name,
          description: data['description']
        }
      rescue StandardError => e
        warn "[ItemGeneratorService] Item profile generation failed: #{e.message}"
        { success: false, error: "Item generation failed: #{e.message}" }
      end

      # Generate item name/short identifier
      # @param category [Symbol]
      # @param subcategory [String, nil]
      # @param setting [Symbol]
      # @param seed_terms [Array<String>]
      # @return [Hash] { success:, name:, error: }
      def generate_name(category:, subcategory: nil, setting: :fantasy, seed_terms: [])
        type_str = subcategory || category.to_s
        terms_str = seed_terms.join(', ')

        prompt = GamePrompts.get(
          'generators.item_name',
          setting: setting,
          type_str: type_str,
          terms_str: terms_str
        )

        result = GenerationPipelineService.generate_simple(prompt: prompt)

        if result[:success]
          # Clean up the response
          name = result[:content].to_s.strip.downcase
          name = name.gsub(/^["']|["']$/, '') # Remove quotes
          name = name.gsub(/^(a |an |the )/, '') # Remove articles
          { success: true, name: name }
        else
          { success: false, name: nil, error: result[:error] }
        end
      end

      # Generate description for existing pattern
      # @param pattern [Pattern] the pattern to describe
      # @param setting [Symbol] world setting
      # @param seed_terms [Array<String>, nil]
      # @param options [Hash]
      # @return [Hash] { success:, content:, validated:, error: }
      def generate_description(pattern:, setting: :fantasy, seed_terms: nil, options: {})
        seed_terms ||= SeedTermService.for_generation(:item, count: 5)

        category = pattern_category(pattern)
        subcategory = pattern.subcategory || pattern.name

        generate_description_for(
          name: pattern.description || pattern.name,
          category: category,
          subcategory: subcategory,
          setting: setting,
          seed_terms: seed_terms,
          options: options
        )
      end

      # Generate item image
      # @param description [String] item description
      # @param category [Symbol] for style selection
      # @param options [Hash] image options
      # @return [Hash] { success:, url:, local_url:, error: }
      def generate_image(description:, category: :misc, options: {})
        style = options[:style] || IMAGE_STYLES[category.to_sym] || :item_on_black

        WorldBuilderImageService.generate(
          type: style,
          description: description,
          options: options
        )
      end

      # Generate multiple item descriptions (batch)
      # @param patterns [Array<Pattern>]
      # @param setting [Symbol]
      # @param options [Hash]
      # @return [Array<Hash>]
      def generate_descriptions_batch(patterns:, setting: :fantasy, options: {})
        patterns.map do |pattern|
          result = generate_description(pattern: pattern, setting: setting, options: options)
          { pattern_id: pattern.id, **result }
        end
      end

      private

      # Generate description with pipeline validation
      def generate_description_for(name:, category:, subcategory:, setting:, seed_terms:, options:)
        terms_str = seed_terms.join(', ')
        type_str = subcategory || category.to_s

        prompt = build_description_prompt(
          name: name,
          type_str: type_str,
          setting: setting,
          terms_str: terms_str,
          category: category
        )

        GenerationPipelineService.generate_with_validation(
          prompt: prompt,
          content_type: :item_description,
          max_retries: options[:max_retries] || 2
        )
      end

      # Build the description generation prompt
      def build_description_prompt(name:, type_str:, setting:, terms_str:, category:)
        # Category-specific mandatory attributes and guidance
        category_config = CATEGORY_CONFIGS[category] || CATEGORY_CONFIGS[:misc]

        GamePrompts.get(
          'generators.item_description',
          setting: setting,
          type_str: type_str,
          name: name,
          terms_str: terms_str,
          mandatory_attributes: category_config[:mandatory].map { |attr| "- #{attr}" }.join("\n"),
          style_guidance: category_config[:guidance]
        )
      end

      # Category configuration for mandatory attributes
      CATEGORY_CONFIGS = {
        clothing: {
          mandatory: [
            'Primary COLOR (specific shade like "deep burgundy" not just "red")',
            'MATERIAL/FABRIC (silk, linen, wool, velvet, leather, etc.)',
            'FIT/SILHOUETTE (fitted, loose, flowing, structured)',
            'LENGTH or COVERAGE (floor-length, knee-length, cropped, etc.)',
            'One DECORATIVE DETAIL (embroidery, buttons, trim, pattern)'
          ],
          guidance: 'Focus on how the garment looks when worn. Describe cut, drape, and distinctive features.'
        },
        jewelry: {
          mandatory: [
            'Primary METAL or MATERIAL (gold, silver, bronze, bone, etc.)',
            'GEMSTONE or CENTERPIECE if any (or "unadorned")',
            'FINISH (polished, matte, tarnished, oxidized)',
            'SIZE/WEIGHT impression (delicate, substantial, chunky)',
            'CRAFTSMANSHIP style (filigree, hammered, cast, woven)'
          ],
          guidance: 'Focus on materials and how light interacts with surfaces. Note any symbolic elements.'
        },
        weapon: {
          mandatory: [
            'BLADE/HEAD MATERIAL (steel, iron, bronze, obsidian)',
            'HANDLE MATERIAL (wood, leather, bone, wrapped)',
            'OVERALL LENGTH impression (short, long, balanced)',
            'CONDITION (new, well-used, battle-worn, pristine)',
            'One DISTINCTIVE FEATURE (guard style, pommel, engravings)'
          ],
          guidance: 'Focus on functional features and what suggests its purpose and history.'
        },
        furniture: {
          mandatory: [
            'Primary WOOD or MATERIAL (oak, mahogany, wrought iron)',
            'FINISH (polished, painted, lacquered, raw)',
            'STYLE period (rustic, ornate, simple, elegant)',
            'CONDITION (new, worn, antique, weathered)',
            'UPHOLSTERY if applicable (fabric, leather, none)'
          ],
          guidance: 'Focus on construction quality and what mood it creates in a space.'
        },
        consumable: {
          mandatory: [
            'PRIMARY COLOR of contents/wrapper',
            'CONTAINER type (bottle, vial, pouch, wrapped)',
            'AROMA hint (sweet, herbal, acrid, none)',
            'TEXTURE/CONSISTENCY if visible (liquid, powder, solid)',
            'LABEL or MARKING if any'
          ],
          guidance: 'Focus on what makes it appealing or distinctive. Suggest quality level.'
        },
        misc: {
          mandatory: [
            'Primary COLOR',
            'Main MATERIAL (wood, metal, stone, cloth)',
            'SIZE impression (palm-sized, substantial, bulky)',
            'CONDITION (new, worn, antique)',
            'One NOTABLE FEATURE'
          ],
          guidance: 'Focus on what someone would first notice when picking it up.'
        }
      }.freeze

      # Determine category from pattern
      def pattern_category(pattern)
        return :clothing if pattern.clothing?
        return :jewelry if pattern.jewelry?
        return :weapon if pattern.weapon?
        return :consumable if pattern.consumable?

        :misc
      end
    end
  end
end
