# frozen_string_literal: true

module WorldGeneration
  # Configuration presets for world generation
  # Each preset defines parameters that tune how the world generator
  # creates tectonic plates, ocean coverage, climate, and terrain
  class PresetConfig
    PRESETS = {
      earth_like: {
        name: 'Earth-like',
        description: 'Multiple continents, varied climates, ~70% ocean',
        ocean_coverage: 0.70,
        plate_count: 10..14,
        continental_ratio: 0.4,
        mountain_intensity: 1.0,
        river_sources: 50..80,
        temperature_variance: 1.0,
        ice_cap_size: 0.10,
        moisture_modifier: 1.0
      }.freeze,

      pangaea: {
        name: 'Pangaea',
        description: 'Single supercontinent with vast interior deserts',
        ocean_coverage: 0.55,
        plate_count: 3..5,
        continental_ratio: 0.7,
        mountain_intensity: 1.2,
        river_sources: 30..50,
        temperature_variance: 1.2,
        ice_cap_size: 0.08,
        moisture_modifier: 0.7
      }.freeze,

      archipelago: {
        name: 'Archipelago',
        description: 'Thousands of islands scattered across vast oceans',
        ocean_coverage: 0.85,
        plate_count: 18..25,
        continental_ratio: 0.2,
        mountain_intensity: 1.4,
        river_sources: 80..120,
        temperature_variance: 0.8,
        ice_cap_size: 0.05,
        moisture_modifier: 1.3
      }.freeze,

      ice_age: {
        name: 'Ice Age',
        description: 'Glacial period with extensive ice sheets and harsh climate',
        ocean_coverage: 0.55,
        plate_count: 8..12,
        continental_ratio: 0.5,
        mountain_intensity: 0.9,
        river_sources: 20..40,
        temperature_variance: 1.4,
        ice_cap_size: 0.35,
        moisture_modifier: 0.6
      }.freeze,

      waterworld: {
        name: 'Waterworld',
        description: 'Minimal landmass with only volcanic islands and atolls',
        ocean_coverage: 0.92,
        plate_count: 6..10,
        continental_ratio: 0.15,
        mountain_intensity: 1.6,
        river_sources: 10..25,
        temperature_variance: 0.7,
        ice_cap_size: 0.03,
        moisture_modifier: 1.5
      }.freeze,

      arid: {
        name: 'Arid',
        description: 'Desert planet with minimal rainfall and sparse vegetation',
        ocean_coverage: 0.45,
        plate_count: 6..9,
        continental_ratio: 0.6,
        mountain_intensity: 0.8,
        river_sources: 15..30,
        temperature_variance: 1.3,
        ice_cap_size: 0.02,
        moisture_modifier: 0.4
      }.freeze
    }.freeze

    # Returns the preset configuration for a given key
    # Falls back to earth_like for unknown presets
    #
    # @param preset_key [Symbol, String] The preset identifier
    # @return [Hash] The preset configuration
    def self.for(preset_key)
      key = preset_key.to_s.to_sym rescue :earth_like
      PRESETS.fetch(key) { PRESETS[:earth_like] }
    end

    # Returns all available presets
    #
    # @return [Hash] The complete PRESETS hash
    def self.all_presets
      PRESETS
    end

    # Returns preset options formatted for UI dropdowns
    # Earth-like is placed first as the default option
    #
    # @return [Array<Hash>] Array of {id:, name:, description:} hashes
    def self.preset_options_for_ui
      # Ensure earth_like comes first
      sorted_keys = [:earth_like] + (PRESETS.keys - [:earth_like])

      sorted_keys.map do |key|
        preset = PRESETS[key]
        {
          id: key,
          name: preset[:name],
          description: preset[:description]
        }
      end
    end

    # Checks if a preset key is valid
    #
    # @param key [Symbol, String, nil] The preset key to validate
    # @return [Boolean] True if the preset exists
    def self.valid_preset?(key)
      return false if key.nil?

      PRESETS.key?(key.to_s.to_sym)
    end
  end
end
