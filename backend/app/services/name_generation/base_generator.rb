# frozen_string_literal: true

module NameGeneration
  # BaseGenerator provides shared functionality for all name generators.
  # Subclasses should implement #generate(options) method.
  #
  class BaseGenerator
    attr_reader :weighting_tracker

    def initialize(weighting_tracker = nil)
      @weighting_tracker = weighting_tracker || WeightingTracker.new
    end

    # Generate a name (subclasses must implement)
    # @param options [Hash] generation options
    # @return [Object] result struct
    def generate(options = {})
      raise NotImplementedError, "#{self.class} must implement #generate"
    end

    # Generate multiple names
    # @param count [Integer] number of names to generate
    # @param options [Hash] generation options
    # @return [Array] array of results
    def generate_batch(count, **options)
      count.times.map { generate(**options) }
    end

    protected

    # Load data from YAML file
    # @param category [String] the category path
    # @param file [String] the file name
    # @return [Hash] the data
    def load_data(category, file)
      DataLoader.load(category, file)
    end

    # Check if data file exists
    # @param category [String] the category path
    # @param file [String] the file name
    # @return [Boolean]
    def data_exists?(category, file)
      DataLoader.exists?(category, file)
    end

    # Select a name using weighted random selection
    # @param names [Array<Hash>] array of name entries with :name and :weight
    # @param category [Symbol] the weighting category
    # @return [String] the selected name
    def weighted_select(names, category: :general)
      return names.sample[:name] if names.empty? || !weighting_tracker

      weighted = weighting_tracker.apply_weights(names, category: category)
      selected = weighting_tracker.weighted_select(weighted)

      # Record the selection
      weighting_tracker.record_use(category, selected) if selected

      selected
    end

    # Simple random select from array (no weighting)
    # @param items [Array] items to select from
    # @return [Object] selected item
    def random_select(items)
      items.sample
    end

    # Capitalize first letter of a name
    # @param name [String] the name
    # @return [String] capitalized name
    def capitalize_name(name)
      return name if name.nil? || name.empty?

      name.split(/(['-])/).map do |part|
        if part.match?(/['-]/)
          part
        else
          part.capitalize
        end
      end.join
    end

    # Apply phonetic rules to clean up a generated name
    # @param name [String] the raw name
    # @param culture [Symbol] the culture for culture-specific rules
    # @return [String] cleaned name
    def apply_phonetic_rules(name, culture = :western)
      result = name.dup

      # Remove double vowels (except valid diphthongs)
      result.gsub!(/([aeiou])\1+/i) { |match| match[0] }

      # Remove triple consonants
      result.gsub!(/([bcdfghjklmnpqrstvwxz])\1\1+/i) { |match| match[0..1] }

      # Ensure at least one vowel
      unless result.match?(/[aeiou]/i)
        result = result[0] + 'a' + result[1..]
      end

      # Culture-specific rules
      case culture
      when :nordic
        # Allow double consonants common in Nordic names
      when :eastern
        # Eastern names often have simpler syllable structure
        result.gsub!(/([bcdfghjklmnpqrstvwxz]{3,})/i) { |match| match[0..1] }
      when :alien
        # Alien names can have apostrophes
        # No additional cleaning
      end

      result
    end

    # Generate ordinal suffix (1st, 2nd, 3rd, etc.)
    # @param number [Integer] the number
    # @return [String] the ordinal string
    def ordinal(number)
      suffix = case number % 100
               when 11, 12, 13 then 'th'
               else
                 case number % 10
                 when 1 then 'st'
                 when 2 then 'nd'
                 when 3 then 'rd'
                 else 'th'
                 end
               end

      "#{number}#{suffix}"
    end
  end
end
