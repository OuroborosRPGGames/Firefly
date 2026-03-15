# frozen_string_literal: true

# NameGeneratorService provides a unified facade for generating names
# of various types: characters, cities, streets, and shops.
#
# This service supports two usage modes:
# 1. Single name generation - returns one name for direct use
# 2. Batch/LLM mode - returns multiple options for AI selection
#
# @example Single character name
#   NameGeneratorService.character(gender: :female, culture: :nordic)
#   # => #<NameResult forename="Sigrid" surname="Eriksson">
#
# @example Multiple options for LLM
#   NameGeneratorService.character_options(count: 5, gender: :male)
#   # => [NameResult, NameResult, NameResult, NameResult, NameResult]
#
class NameGeneratorService
  class << self
    # --- Character Names ---

    # Generate a single character name
    # @param gender [Symbol] :male, :female, :neutral, :any
    # @param culture [Symbol] :western, :eastern, :nordic, :arabic, :elf, :dwarf, :human_scifi, :alien
    # @param setting [Symbol] genre preset
    # @param forename_only [Boolean] skip surname generation
    # @return [NameGeneration::NameResult]
    def character(**options)
      character_generator.generate(**options)
    end

    # Generate multiple character name options
    # @param count [Integer] number of names to generate (default: 5)
    # @param options [Hash] same options as #character
    # @return [Array<NameGeneration::NameResult>]
    def character_options(count: 5, **options)
      character_generator.generate_batch(count, **options)
    end

    # --- City Names ---

    # Generate a single city/town name
    # @param setting [Symbol] the genre/setting
    # @param pattern [Symbol] specific pattern or :random
    # @param size [Symbol] :city, :town, :village
    # @return [NameGeneration::CityResult]
    def city(**options)
      city_generator.generate(**options)
    end

    # Generate multiple city name options
    # @param count [Integer] number of names to generate (default: 5)
    # @param options [Hash] same options as #city
    # @return [Array<NameGeneration::CityResult>]
    def city_options(count: 5, **options)
      city_generator.generate_batch(count, **options)
    end

    # Alias for backward compatibility
    alias town city
    alias town_options city_options

    # --- Street Names ---

    # Generate a single street name
    # @param setting [Symbol] the genre/setting
    # @param style [Symbol] :named, :numbered, :directional, :memorial, :descriptive, :random
    # @return [NameGeneration::StreetResult]
    def street(**options)
      street_generator.generate(**options)
    end

    # Generate multiple street name options
    # @param count [Integer] number of names to generate (default: 5)
    # @param options [Hash] same options as #street
    # @return [Array<NameGeneration::StreetResult>]
    def street_options(count: 5, **options)
      street_generator.generate_batch(count, **options)
    end

    # --- Shop Names ---

    # Generate a single shop name
    # @param shop_type [Symbol] :tavern, :restaurant, :blacksmith, :general_store, etc.
    # @param setting [Symbol] the genre/setting
    # @param template [Symbol] specific template or :random
    # @return [NameGeneration::ShopResult]
    def shop(**options)
      shop_generator.generate(**options)
    end

    # Generate multiple shop name options
    # @param count [Integer] number of names to generate (default: 5)
    # @param options [Hash] same options as #shop
    # @return [Array<NameGeneration::ShopResult>]
    def shop_options(count: 5, **options)
      shop_generator.generate_batch(count, **options)
    end

    # --- Utility Methods ---

    # Reset all generator caches and weighting trackers
    # Useful for testing or when starting fresh
    def reset!
      @character_generator = nil
      @city_generator = nil
      @street_generator = nil
      @shop_generator = nil
      @shared_tracker = nil
      NameGeneration::DataLoader.clear_cache!
    end

    # Get available cultures for character generation
    # @return [Array<Symbol>]
    def available_cultures
      NameGeneration::CharacterNameGenerator::CULTURES + NameGeneration::CharacterNameGenerator::PATTERN_CULTURES
    end

    # Get available settings/genres
    # @return [Array<Symbol>]
    def available_settings
      NameGeneration::CharacterNameGenerator::GENRE_DEFAULTS.keys
    end

    # Get available shop types
    # @return [Array<Symbol>]
    def available_shop_types
      NameGeneration::ShopNameGenerator::SHOP_TYPES
    end

    private

    # Shared weighting tracker to reduce repetition across all generators
    def shared_tracker
      @shared_tracker ||= NameGeneration::WeightingTracker.new
    end

    def character_generator
      @character_generator ||= NameGeneration::CharacterNameGenerator.new(shared_tracker)
    end

    def city_generator
      @city_generator ||= NameGeneration::CityNameGenerator.new(shared_tracker)
    end

    def street_generator
      @street_generator ||= NameGeneration::StreetNameGenerator.new(shared_tracker)
    end

    def shop_generator
      @shop_generator ||= NameGeneration::ShopNameGenerator.new(shared_tracker)
    end
  end
end
