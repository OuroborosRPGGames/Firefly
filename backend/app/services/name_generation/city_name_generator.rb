# frozen_string_literal: true

module NameGeneration
  # CityNameGenerator generates city and town names with support for
  # multiple settings and name patterns.
  #
  # Usage:
  #   generator = CityNameGenerator.new
  #   result = generator.generate(setting: :fictional_historic)
  #   result.name # => "Moonshadow"
  #
  class CityNameGenerator < BaseGenerator
    # Probability of generating a novel name (vs selecting from patterns)
    MARKOV_PROBABILITY = 0.15

    # Pattern types and their selection methods
    PATTERN_TYPES = %i[prefix_suffix adjective_noun compound possessive single].freeze

    # Settings that map to data file keys
    VALID_SETTINGS = %i[
      earth_historic
      earth_modern
      earth_future
      fictional_historic
      fictional_contemporary
      fictional_future_human
      fictional_future_alien
    ].freeze

    # Generate a city/town name
    # @param setting [Symbol] the genre/setting
    # @param pattern [Symbol] specific pattern to use (or :random)
    # @param size [Symbol] :city, :town, :village (affects naming style)
    # @return [CityResult]
    def generate(setting: :earth_modern, pattern: :random, size: :city)
      setting = normalize_setting(setting)
      data = load_city_data

      # Get setting-specific components
      components = data[setting] || data[:earth_modern] || {}

      # Select pattern
      selected_pattern = select_pattern(pattern, data[:patterns])

      # Generate name based on pattern
      name = generate_by_pattern(selected_pattern, components, data)

      # Apply size modifiers for smaller settlements
      name = apply_size_modifier(name, size, setting) if size != :city

      CityResult.new(
        name: name,
        metadata: {
          setting: setting,
          pattern: selected_pattern,
          size: size
        }
      )
    end

    private

    def normalize_setting(setting)
      return setting if VALID_SETTINGS.include?(setting)

      :earth_modern
    end

    def load_city_data
      @city_data ||= load_data('locations', 'city_components')
    rescue ArgumentError
      default_city_data
    end

    def default_city_data
      {
        patterns: [{ type: :single, weight: 5 }],
        earth_modern: {
          single_names: [
            { name: 'Springfield', weight: 3 },
            { name: 'Riverside', weight: 3 },
            { name: 'Lakewood', weight: 3 }
          ]
        }
      }
    end

    def select_pattern(requested_pattern, patterns)
      return requested_pattern if PATTERN_TYPES.include?(requested_pattern)

      # Weighted random selection from available patterns
      if patterns&.any?
        weighted_patterns = patterns.map do |p|
          { name: p[:type]&.to_sym || :single, weight: p[:weight] || 3 }
        end
        weighted_select(weighted_patterns, category: :city_pattern)&.to_sym || :single
      else
        PATTERN_TYPES.sample
      end
    end

    def generate_by_pattern(pattern, components, data)
      case pattern
      when :prefix_suffix
        generate_prefix_suffix(components)
      when :adjective_noun
        generate_adjective_noun(components)
      when :compound
        generate_compound(components)
      when :possessive
        generate_possessive(components)
      when :single
        generate_single(components)
      else
        # Try Markov if we have syllables
        syllables = data[:syllables] || {}
        if rand < MARKOV_PROBABILITY && syllables.any?
          generate_markov_city(syllables)
        else
          generate_single(components)
        end
      end
    end

    def generate_prefix_suffix(components)
      prefixes = components[:prefixes] || []
      suffixes = components[:suffixes] || []

      return generate_fallback_city if prefixes.empty? || suffixes.empty?

      prefix = weighted_select(prefixes, category: :city_prefix) || 'River'
      suffix = weighted_select(suffixes, category: :city_suffix) || 'ton'

      "#{prefix}#{suffix}"
    end

    def generate_adjective_noun(components)
      adjectives = components[:adjectives] || []
      nouns = components[:nouns] || []

      return generate_fallback_city if adjectives.empty? || nouns.empty?

      adjective = weighted_select(adjectives, category: :city_adjective) || 'New'
      noun = weighted_select(nouns, category: :city_noun) || 'Haven'

      "#{adjective} #{noun}"
    end

    def generate_compound(components)
      # Use prefixes and suffixes to create compound words
      prefixes = components[:prefixes] || []
      suffixes = components[:suffixes] || []

      return generate_fallback_city if prefixes.empty? || suffixes.empty?

      prefix = weighted_select(prefixes, category: :city_compound_prefix) || 'Black'
      suffix = weighted_select(suffixes, category: :city_compound_suffix) || 'water'

      # Compound names are joined without space
      "#{prefix}#{suffix.downcase}"
    end

    def generate_possessive(components)
      # Generate possessive names like "King's Landing"
      prefixes = components[:prefixes] || []
      nouns = components[:nouns] || []

      return generate_fallback_city if prefixes.empty?

      prefix = weighted_select(prefixes, category: :city_possessive_prefix) || 'King'

      if nouns.any?
        noun = weighted_select(nouns, category: :city_possessive_noun) || 'Landing'
        "#{prefix}'s #{noun}"
      else
        suffixes = components[:suffixes] || []
        suffix = weighted_select(suffixes, category: :city_possessive_suffix) || 'bury'
        "St. #{prefix}#{suffix}"
      end
    end

    def generate_single(components)
      single_names = components[:single_names] || []

      return generate_fallback_city if single_names.empty?

      weighted_select(single_names, category: :city_single) || generate_fallback_city
    end

    def generate_markov_city(syllables)
      markov = MarkovGenerator.new(syllables)
      markov.generate
    end

    def apply_size_modifier(name, size, setting)
      # For smaller settlements, sometimes add modifiers
      case size
      when :town
        rand < 0.3 ? "#{name} Town" : name
      when :village
        modifiers = size_modifiers_for_setting(setting)
        if modifiers.any? && rand < 0.4
          "#{modifiers.sample} #{name}"
        else
          name
        end
      else
        name
      end
    end

    def size_modifiers_for_setting(setting)
      case setting
      when :earth_historic, :fictional_historic
        %w[Little Old Upper Lower]
      when :earth_modern, :fictional_contemporary
        %w[Little Old North South]
      when :earth_future, :fictional_future_human
        %w[Lower Outer Minor]
      when :fictional_future_alien
        %w[Lesser Outer Sub]
      else
        %w[Little Old]
      end
    end

    def generate_fallback_city
      fallback_cities = %w[Riverside Springfield Lakewood Fairview Greendale]
      fallback_cities.sample
    end
  end
end
