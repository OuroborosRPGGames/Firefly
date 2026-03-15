# frozen_string_literal: true

module NameGeneration
  # MarkovGenerator creates novel names using Markov chain principles.
  # Learns patterns from seed names and generates new names that sound similar.
  #
  # Two modes of operation:
  # 1. Syllable-based: Uses pre-defined syllable components
  # 2. Character-based: Learns character transitions from a list of names
  #
  class MarkovGenerator
    MIN_NAME_LENGTH = 3
    MAX_NAME_LENGTH = 15
    ORDER = 2 # Markov chain order (character pairs)

    # Build a generator by analyzing a list of names
    # @param names [Array<String>] list of names to learn from
    # @param order [Integer] Markov chain order (default 2)
    # @return [MarkovGenerator]
    def self.build_from_names(names, order: ORDER)
      chain = Hash.new { |h, k| h[k] = [] }
      starters = []

      names.each do |name|
        next if name.nil? || name.length < order + 1

        # Normalize the name
        normalized = name.downcase.strip

        # Record the starting characters
        starters << normalized[0, order]

        # Build transition chains
        (0..normalized.length - order).each do |i|
          key = normalized[i, order]
          next_char = normalized[i + order]
          chain[key] << next_char if next_char
        end
      end

      new(chain: chain, starters: starters)
    end

    def initialize(syllables = nil, chain: nil, starters: nil)
      if chain && starters
        # Character-based mode
        @mode = :character
        @chain = chain
        @starters = starters
      else
        # Syllable-based mode
        @mode = :syllable
        @prefixes = syllables&.dig(:prefixes) || []
        @middles = syllables&.dig(:middles) || []
        @suffixes = syllables&.dig(:suffixes) || []
      end
    end

    # Generate a novel name
    # @param options [Hash] generation options
    # @return [String] generated name
    def generate(options = {})
      max_attempts = options[:max_attempts] || 10

      max_attempts.times do
        name = @mode == :character ? compose_from_chain : compose_from_syllables
        return capitalize_name(name) if valid_name?(name, options)
      end

      # Fallback
      capitalize_name(@mode == :character ? compose_from_chain : simple_composition)
    end

    private

    # Character-based composition using Markov chain
    def compose_from_chain
      return '' if @starters.empty? || @chain.empty?

      # Start with a random beginning
      current = @starters.sample
      name = current

      # Target length between 4 and 12 characters
      target_length = rand(4..12)

      while name.length < target_length
        next_chars = @chain[current]
        break if next_chars.nil? || next_chars.empty?

        next_char = next_chars.sample
        name += next_char
        current = name[-ORDER, ORDER]
      end

      name
    end

    # Syllable-based composition
    def compose_from_syllables
      # 70% chance of prefix + suffix
      # 30% chance of prefix + middle + suffix
      if rand < 0.7 || @middles.empty?
        "#{random_prefix}#{random_suffix}"
      else
        "#{random_prefix}#{random_middle}#{random_suffix}"
      end
    end

    def simple_composition
      "#{random_prefix}#{random_suffix}"
    end

    def random_prefix
      @prefixes.sample || ''
    end

    def random_middle
      @middles.sample || ''
    end

    def random_suffix
      @suffixes.sample || ''
    end

    def valid_name?(name, options = {})
      return false if name.nil? || name.empty?

      min_length = options[:min_length] || MIN_NAME_LENGTH
      max_length = options[:max_length] || MAX_NAME_LENGTH

      return false if name.length < min_length
      return false if name.length > max_length

      # Must have at least one vowel
      return false unless name.match?(/[aeiou]/i)

      # No more than 3 consecutive consonants
      return false if name.match?(/[bcdfghjklmnpqrstvwxz]{4,}/i)

      # No more than 3 consecutive vowels
      return false if name.match?(/[aeiou]{4,}/i)

      true
    end

    def capitalize_name(name)
      return name if name.nil? || name.empty?

      # Handle apostrophes (Kel'thax -> Kel'thax)
      name.split(/(['-])/).map do |part|
        part.match?(/['-]/) ? part : part.capitalize
      end.join
    end
  end
end
