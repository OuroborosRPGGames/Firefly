# frozen_string_literal: true

module NameGeneration
  # StreetNameGenerator generates street names with support for
  # multiple settings and naming styles.
  #
  # Usage:
  #   generator = StreetNameGenerator.new
  #   result = generator.generate(setting: :earth_modern, style: :named)
  #   result.name # => "Oak Street"
  #
  class StreetNameGenerator < BaseGenerator
    # Probability of generating a novel name (vs selecting from data)
    MARKOV_PROBABILITY = 0.1

    # Street naming styles
    STYLE_TYPES = %i[named numbered directional memorial descriptive].freeze

    # Valid settings
    VALID_SETTINGS = %i[
      earth_historic
      earth_modern
      earth_future
      fictional_historic
      fictional_contemporary
      fictional_future_human
      fictional_future_alien
    ].freeze

    # Generate a street name
    # @param setting [Symbol] the genre/setting
    # @param style [Symbol] naming style (:named, :numbered, :directional, :memorial, :descriptive, :random)
    # @return [StreetResult]
    def generate(setting: :earth_modern, style: :random)
      setting = normalize_setting(setting)
      data = load_street_data

      # Get setting-specific components
      components = data[setting] || data[:earth_modern] || {}

      # Select style
      selected_style = select_style(style, data[:styles])

      # Generate name based on style
      name = generate_by_style(selected_style, components, data, setting)

      StreetResult.new(
        name: name,
        metadata: {
          setting: setting,
          style: selected_style
        }
      )
    end

    private

    def normalize_setting(setting)
      return setting if VALID_SETTINGS.include?(setting)

      :earth_modern
    end

    def load_street_data
      @street_data ||= load_data('locations', 'street_components')
    rescue ArgumentError
      default_street_data
    end

    def default_street_data
      {
        styles: [{ type: :named, weight: 5 }],
        earth_modern: {
          names: [
            { name: 'Main', weight: 5 },
            { name: 'Oak', weight: 4 },
            { name: 'Maple', weight: 4 }
          ]
        },
        street_types: {
          common: [
            { name: 'Street', weight: 5 },
            { name: 'Avenue', weight: 5 },
            { name: 'Road', weight: 4 }
          ]
        }
      }
    end

    def select_style(requested_style, styles)
      return requested_style if STYLE_TYPES.include?(requested_style)

      # Weighted random selection from available styles
      if styles&.any?
        weighted_styles = styles.map do |s|
          { name: s[:type]&.to_sym || :named, weight: s[:weight] || 3 }
        end
        weighted_select(weighted_styles, category: :street_style)&.to_sym || :named
      else
        STYLE_TYPES.sample
      end
    end

    def generate_by_style(style, components, data, setting)
      case style
      when :named
        generate_named_street(components, data, setting)
      when :numbered
        generate_numbered_street(components, data, setting)
      when :directional
        generate_directional_street(components, data, setting)
      when :memorial
        generate_memorial_street(components, data, setting)
      when :descriptive
        generate_descriptive_street(data, setting)
      else
        generate_named_street(components, data, setting)
      end
    end

    def generate_named_street(components, data, setting)
      names = components[:names] || []
      street_type = select_street_type(data, setting)

      if names.any?
        name = weighted_select(names, category: :street_name) || 'Main'
        "#{name} #{street_type}"
      else
        # Try Markov or fallback
        syllables = data[:syllables] || {}
        if rand < MARKOV_PROBABILITY && syllables.any?
          markov_name = generate_markov_street(syllables)
          "#{markov_name} #{street_type}"
        else
          "#{generate_fallback_street_name} #{street_type}"
        end
      end
    end

    def generate_numbered_street(components, data, setting)
      # Generate numbered streets like "42nd Street" or "5th Avenue"
      numbered_prefixes = components[:numbered_prefixes] || []
      street_type = select_street_type(data, setting)

      number = rand(1..100)
      ordinal_number = ordinal(number)

      if numbered_prefixes.any?
        prefix = weighted_select(numbered_prefixes, category: :street_numbered_prefix)
        "#{prefix} #{ordinal_number}"
      else
        "#{ordinal_number} #{street_type}"
      end
    end

    def generate_directional_street(components, data, setting)
      adjectives = components[:adjectives] || []
      names = components[:names] || []
      street_type = select_street_type(data, setting)

      if adjectives.any? && names.any?
        adjective = weighted_select(adjectives, category: :street_direction) || 'North'
        name = weighted_select(names, category: :street_name) || 'Main'
        "#{adjective} #{name} #{street_type}"
      elsif adjectives.any?
        adjective = weighted_select(adjectives, category: :street_direction) || 'North'
        "#{adjective} #{street_type}"
      else
        generate_named_street(components, data, setting)
      end
    end

    def generate_memorial_street(components, data, setting)
      memorial_names = components[:memorial_names] || []
      street_type = select_street_type(data, setting)

      if memorial_names.any?
        name = weighted_select(memorial_names, category: :street_memorial) || 'Washington'
        "#{name} #{street_type}"
      else
        generate_named_street(components, data, setting)
      end
    end

    def generate_descriptive_street(data, setting)
      descriptive = data[:descriptive] || {}
      adjectives = descriptive[:adjectives] || []
      nouns = descriptive[:nouns] || []

      if adjectives.any? && nouns.any?
        adjective = weighted_select(adjectives, category: :street_descriptive_adj) || 'Winding'
        noun = weighted_select(nouns, category: :street_descriptive_noun) || 'Way'
        "#{adjective} #{noun}"
      else
        street_type = select_street_type(data, setting)
        "#{generate_fallback_street_name} #{street_type}"
      end
    end

    def select_street_type(data, setting)
      street_types = data[:street_types] || {}

      # Select appropriate category based on setting
      type_category = case setting
                      when :earth_historic
                        street_types[:historic] || street_types[:common]
                      when :fictional_historic
                        street_types[:fantasy] || street_types[:historic] || street_types[:common]
                      when :earth_future, :fictional_future_human, :fictional_future_alien
                        street_types[:scifi] || street_types[:common]
                      else
                        street_types[:common]
                      end

      type_category ||= [{ name: 'Street', weight: 5 }]

      weighted_select(type_category, category: :street_type) || 'Street'
    end

    def generate_markov_street(syllables)
      markov = MarkovGenerator.new(syllables)
      markov.generate
    end

    def generate_fallback_street_name
      fallback_names = %w[Main Oak Maple Elm Park]
      fallback_names.sample
    end
  end
end
