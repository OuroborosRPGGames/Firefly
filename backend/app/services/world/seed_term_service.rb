# frozen_string_literal: true

# SeedTermService provides random seed terms for LLM-driven content generation.
#
# Samples from randomization tables stored in database, providing thematic
# inspiration for generated content. The LLM should use these as loose
# inspiration, not strict requirements.
#
# TABLE STRUCTURE:
# - ADJECTIVE TABLES: For inspiration (physical_adjectives, materials, etc.)
# - NOUN TABLES: For selecting WHAT to generate (object_types, location_types)
# - CHARACTER TABLES: For NPC generation (personality, motivations, identity)
#
# @example Get seed terms for item generation
#   SeedTermService.for_generation(:item, count: 5)
#   # => ["weathered", "brass", "ornate", "antique", "mysterious"]
#
# @example The LLM picks 1-2 seeds for inspiration
#   seeds = SeedTermService.for_generation(:npc, count: 5)
#   # Prompt: "Pick 1-2 of these for thematic inspiration: #{seeds.join(', ')}"
#
class SeedTermService
  # Available tables (must match seed script)
  # Organized by purpose: adjectives for inspiration, nouns for selection
  AVAILABLE_TABLES = %i[
    physical_adjectives materials size_adjectives age_adjectives
    quality_adjectives spatial_adjectives atmosphere_adjectives
    lighting_adjectives temperature_adjectives sound_adjectives
    scent_adjectives condition_adjectives
    character_descriptors character_personality character_motivations character_identity
    adventure_tone
    object_types location_types creature_types character_roles
    creature_adjectives creature_abilities animal_behaviors
    noble_house_symbols deity_domains legend_elements
    names
  ].freeze

  # Categories for different generation tasks
  # IMPORTANT: Use ADJECTIVE tables for inspiration, not NOUN tables
  # Noun tables are for selecting what to generate, not describing it
  GENERATION_CATEGORIES = {
    # Items need physical descriptors, materials, and quality indicators
    item: %i[physical_adjectives materials quality_adjectives age_adjectives],

    # NPCs need personality and identity descriptors
    npc: %i[character_descriptors character_personality character_motivations character_identity],

    # Rooms need spatial, atmospheric, and sensory descriptors
    room: %i[spatial_adjectives atmosphere_adjectives lighting_adjectives condition_adjectives],

    # Places need spatial, atmospheric, and environmental descriptors
    place: %i[spatial_adjectives atmosphere_adjectives temperature_adjectives age_adjectives],

    # Cities need atmosphere, quality, age, and tone
    city: %i[atmosphere_adjectives quality_adjectives age_adjectives adventure_tone],

    # Adventures need tone, atmosphere, legend elements, and motivations
    adventure: %i[adventure_tone atmosphere_adjectives legend_elements character_motivations],

    # Dungeons need atmosphere, lighting, condition, and sensory descriptors
    dungeon: %i[atmosphere_adjectives lighting_adjectives condition_adjectives scent_adjectives],

    # Creatures need creature-specific adjectives and abilities
    creature: %i[creature_adjectives creature_abilities animal_behaviors size_adjectives],

    # Shops need atmosphere, quality, and sensory descriptors
    shop: %i[atmosphere_adjectives quality_adjectives scent_adjectives adventure_tone],

    # Wilderness needs atmosphere, temperature, and sensory descriptors
    wilderness: %i[atmosphere_adjectives temperature_adjectives sound_adjectives scent_adjectives],

    # Lore/world-building needs symbols, domains, and legend elements
    lore: %i[noble_house_symbols deity_domains legend_elements adventure_tone]
  }.freeze

  class << self
    # Get seed terms for a generation task - main entry point
    # Returns 5 terms by default, LLM should pick 1-2 for inspiration
    # @param task_type [Symbol] :item, :npc, :room, :place, :city, etc.
    # @param count [Integer] number of terms to return (default: 5)
    # @return [Array<String>] seed terms
    def for_generation(task_type, count: 5)
      categories = GENERATION_CATEGORIES[task_type.to_sym] || [:character_descriptors]
      per_category = (count.to_f / categories.length).ceil

      terms = categories.flat_map do |category|
        sample(category, count: per_category)
      end

      terms.uniq.shuffle.take(count)
    end

    # Sample random entries from a specific table
    # @param table_name [Symbol] table name
    # @param count [Integer] number of entries to return
    # @return [Array<String>] random entries
    def sample(table_name, count: 1)
      entries = DB[:seed_term_entries]
        .where(table_name: table_name.to_s)
        .select_map(:entry)

      return [] if entries.empty?

      entries.sample([count, entries.length].min)
    end

    # Get categorized seed terms (for detailed prompts)
    # @param categories [Array<Symbol>] table names
    # @param count_per_category [Integer] samples per category
    # @return [Hash<Symbol, Array<String>>] categorized samples
    def categorized(categories:, count_per_category: 2)
      result = {}
      categories.each do |category|
        result[category] = sample(category, count: count_per_category)
      end
      result
    end

    # Get combined descriptors (adjective + noun style)
    # Used when you need "weathered sword" or "gleaming chalice" style phrases
    # @param count [Integer] number of pairs
    # @return [Array<String>] combined descriptors
    def combined_descriptors(count: 2)
      adjectives = sample(:physical_adjectives, count: count)
      nouns = sample(:object_types, count: count)

      adjectives.zip(nouns).map do |adj, noun|
        "#{adj} #{noun}".downcase
      end
    end

    # Roll on adventure tone for vibe/mood
    # @param count [Integer]
    # @return [Array<String>]
    def adventure_tones(count: 2)
      sample(:adventure_tone, count: count)
    end

    # Get all available table names
    # @return [Array<Symbol>]
    def available_tables
      AVAILABLE_TABLES
    end

    # Get all entries from a table (for UI browsing)
    # @param table_name [Symbol]
    # @return [Array<String>]
    def all_entries(table_name)
      DB[:seed_term_entries]
        .where(table_name: table_name.to_s)
        .order(:position)
        .select_map(:entry)
    end

    # Get table info for display
    # @return [Array<Hash>] table metadata
    def table_info
      AVAILABLE_TABLES.map do |name|
        entries = all_entries(name)
        {
          name: name,
          count: entries.length,
          sample: entries.first(5)
        }
      end
    end

    # Check if tables are seeded
    # @return [Boolean]
    def seeded?
      DB[:seed_term_entries].any?
    rescue Sequel::DatabaseError
      false
    end

    # === Backward compatibility aliases ===

    def flat_seed_terms(task_type, total: 4)
      for_generation(task_type, count: total)
    end

    def seed_terms_for(task_type, count_per_category: 2)
      categories = GENERATION_CATEGORIES[task_type.to_sym] || [:character_descriptors]
      categorized(categories: categories, count_per_category: count_per_category)
    end

    def seed_terms(categories:, count_per_category: 2)
      categorized(categories: categories, count_per_category: count_per_category)
    end
  end
end
