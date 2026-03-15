# frozen_string_literal: true

require_relative '../../../lib/core_extensions'

# StreetNameService generates street and avenue names for city building.
#
# Supports three generation modes:
# 1. LLM generation - for Earth-based worlds with realistic names
# 2. Local generation - using NameGeneratorService for fantasy/themed worlds
# 3. Numbered fallback - for test universes
#
# @example Generate streets for a city
#   streets = StreetNameService.generate(
#     location: location,
#     count: 10,
#     direction: :street
#   )
#
# @example Force LLM generation
#   avenues = StreetNameService.generate(
#     location: location,
#     count: 8,
#     direction: :avenue,
#     use_llm: true
#   )
#
class StreetNameService
  class << self
    # Generate street/avenue names for a city
    # @param location [Location] the city location
    # @param count [Integer] number of names needed
    # @param direction [Symbol] :street (E-W running) or :avenue (N-S running)
    # @param use_llm [Boolean, nil] nil = auto-detect, true/false = force
    # @return [Array<String>] list of street/avenue names
    def generate(location:, count:, direction:, use_llm: nil, exclude_bases: [])
      world = location.zone&.world
      use_llm = should_use_llm?(world) if use_llm.nil?

      if use_llm && llm_available?
        world = location.zone&.world
        year = world.respond_to?(:year) ? world&.year : nil
        generate_with_llm(
          zone_name: build_zone_name(location),
          count: count,
          direction: direction,
          year: year,
          exclude_bases: exclude_bases
        )
      elsif test_universe?(world)
        generate_numbered(count: count, direction: direction)
      else
        generate_local(count: count, direction: direction, setting: world&.universe&.theme&.to_sym || :fantasy, exclude_bases: exclude_bases)
      end
    rescue StandardError => e
      # Fallback to numbered on any error
      warn "[StreetNameService] Error generating names: #{e.message}"
      generate_numbered(count: count, direction: direction)
    end

    # Generate names using LLM (for Earth-based worlds)
    # @param zone_name [String] city/country name for context
    # @param count [Integer] number of names
    # @param direction [Symbol] :street or :avenue
    # @param year [Integer, nil] historical year context
    # @return [Array<String>]
    def generate_with_llm(zone_name:, count:, direction:, year: nil, exclude_bases: [])
      prompt = build_llm_prompt(zone_name: zone_name, count: count, direction: direction, year: year)
      if exclude_bases.any?
        prompt += " Avoid using these words as base names: #{exclude_bases.join(', ')}."
      end

      result = LLM::Client.generate(
        prompt: prompt,
        options: { max_tokens: 256, temperature: 0 }
      )

      return generate_numbered(count: count, direction: direction) unless result[:success]

      parse_llm_response(result[:text], count, direction)
    end

    # Generate names using the local NameGeneratorService
    # @param count [Integer] number of names
    # @param direction [Symbol] :street or :avenue
    # @param setting [Symbol] the world setting/theme
    # @return [Array<String>]
    def generate_local(count:, direction:, setting: :fantasy, exclude_bases: [])
      # Use NameGeneratorService to generate street names
      # The street generator already has logic for different styles
      names = []
      attempts = 0
      while names.length < count && attempts < count * 3
        attempts += 1
        result = NameGeneratorService.street(setting: setting)
        name_str = result.to_s
        base = extract_base_name(name_str)
        next if exclude_bases.any? { |eb| eb.casecmp?(base) }

        names << name_str
      end

      # Ensure uniqueness
      ensure_unique(names, count, direction)
    end

    # Generate numbered fallback names (for test universes)
    # @param count [Integer] number of names
    # @param direction [Symbol] :street or :avenue
    # @return [Array<String>]
    def generate_numbered(count:, direction:)
      suffix = direction == :avenue ? 'Avenue' : 'Street'

      count.times.map do |i|
        "#{CoreExtensions.ordinalize(i + 1)} #{suffix}"
      end
    end

    # Street/avenue suffixes for base name extraction
    STREET_SUFFIXES = /\s+(Street|Avenue|Road|Lane|Drive|Boulevard|Way|Place|Court|Circle|Terrace|Trail|Parkway|Plaza|Alley)\s*$/i

    # Extract the base name from a street/avenue name (e.g., "Oak Avenue" -> "Oak")
    # @param name [String] the full street/avenue name
    # @return [String] the base name without suffix
    def extract_base_name(name)
      name.sub(STREET_SUFFIXES, '').strip
    end

    # Check if LLM should be used based on world settings
    # @param world [World, nil] the world
    # @return [Boolean]
    def should_use_llm?(world)
      return false unless world
      return false unless llm_available?

      theme = world.universe&.theme&.to_s&.downcase

      # Earth-based themes benefit from LLM-generated names
      %w[modern contemporary urban real_world earth_like historical].include?(theme)
    end

    # Check if any LLM provider is configured
    # @return [Boolean]
    def llm_available?
      AIProviderService.any_available?
    rescue StandardError => e
      warn "[StreetNameService] Failed to check LLM availability: #{e.message}"
      false
    end

    private

    # Check if this is a test universe (uses numbered names)
    def test_universe?(world)
      return true unless world

      theme = world.universe&.theme&.to_s&.downcase
      name = world.universe&.name&.to_s&.downcase

      # Test universes typically have these indicators
      name&.include?('test') || theme == 'test' || theme.nil?
    end

    # Build a zone name string for LLM context
    def build_zone_name(location)
      parts = []
      parts << location.name if location.name && !location.name.empty?

      zone = location.zone
      if zone
        parts << zone.name if zone.name && !zone.name.empty? && zone.name != location.name

        world = zone.world
        if world
          # Include world name if it's a real place name
          parts << world.name if world.name && !world.name.empty? && !generic_world_name?(world.name)
        end
      end

      parts.uniq.join(', ')
    end

    # Check if a world name is generic (not a real place)
    def generic_world_name?(name)
      generic_names = %w[world earth realm land domain territory kingdom empire]
      generic_names.any? { |g| name.downcase.include?(g) }
    end

    # Build the LLM prompt for street generation
    def build_llm_prompt(zone_name:, count:, direction:, year:)
      if direction == :avenue
        type_desc = 'avenue names for north-south running avenues'
        position_desc = 'starting with the westernmost avenue name and ending with the easternmost'
        examples = 'Smith Avenue, Fairfield Avenue, Baker Avenue'
      else
        type_desc = 'street names for east-west running streets'
        position_desc = 'starting with the southernmost street name and ending with the northernmost'
        examples = 'Park Street, Whitechapel Street, Vicarage Street'
      end

      year_context = if year
                       year_str = year > 0 ? "#{year} AD" : "#{year.abs} BC"
                       " in the year #{year_str}"
                     else
                       ''
                     end

      GamePrompts.get('street_names.generate',
                       count: count,
                       type_desc: type_desc,
                       zone_name: zone_name,
                       year_context: year_context,
                       position_desc: position_desc,
                       examples: examples)
    end

    # Parse the LLM response into an array of names
    def parse_llm_response(text, count, direction)
      return generate_numbered(count: count, direction: direction) if text.nil? || text.empty?

      names = if text.include?("\n")
                # Handle numbered list format (e.g., "1. First Avenue\n2. Second Avenue")
                text.split("\n").map do |line|
                  line = line.strip
                  next if line.empty?

                  # Remove leading numbers like "1. " or "1) "
                  line.sub(/^\d+[.)]\s*/, '').strip
                end.compact.reject(&:empty?)
              else
                # Handle comma-separated format
                text.split(',').map(&:strip).reject(&:empty?)
              end

      # Ensure we have enough names
      if names.length < count
        suffix = direction == :avenue ? 'Avenue' : 'Street'
        (names.length...count).each do |i|
          names << "#{CoreExtensions.ordinalize(i + 1)} #{suffix}"
        end
      end

      names.first(count)
    end

    # Ensure names are unique
    def ensure_unique(names, count, direction)
      unique = names.uniq

      while unique.length < count
        suffix = direction == :avenue ? 'Avenue' : 'Street'
        fallback = "#{CoreExtensions.ordinalize(unique.length + 1)} #{suffix}"
        unique << fallback unless unique.include?(fallback)
      end

      unique.first(count)
    end

  end
end
