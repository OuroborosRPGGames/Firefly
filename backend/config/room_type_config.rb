# frozen_string_literal: true

require 'yaml'
require 'set'

# ==============================================================================
# RoomTypeConfig - Centralized Room Type Registry
# ==============================================================================
# Loads room type definitions from config/room_types.yml and provides lookups.
# Every room type in the game must be defined in the YAML file.
#
# Usage:
#   RoomTypeConfig.valid?('shop')                # => true
#   RoomTypeConfig.all_types                     # => ['standard', 'safe', ...]
#   RoomTypeConfig.category_for('shop')          # => :services
#   RoomTypeConfig.environment('forest')         # => :outdoor
#   RoomTypeConfig.badge_color('combat')         # => 'danger'
#   RoomTypeConfig.icon('shop')                  # => '[Shop]'
#   RoomTypeConfig.battle_map('cave')            # => { surfaces: [...], ... }
#   RoomTypeConfig.tagged(:street)               # => ['street', 'avenue', 'intersection']
#   RoomTypeConfig.tagged?('shop', :interior)    # => true
#   RoomTypeConfig.outdoor?('forest')            # => true
#   RoomTypeConfig.categories                    # => { basic: { display_name: 'Basic', types: [...] }, ... }
#   RoomTypeConfig.types_in_category(:services)  # => ['shop', 'guild', 'temple', 'bank', 'hospital']
#
# Reload in development:
#   RoomTypeConfig.reload!
# ==============================================================================
module RoomTypeConfig
  class << self
    # ========================================
    # Core Lookups
    # ========================================

    # Check if a room type is valid (defined in config)
    # @param type [String] room type name
    # @return [Boolean]
    def valid?(type)
      type_index.key?(type.to_s)
    end

    # All valid room type names
    # @return [Array<String>]
    def all_types
      @all_types ||= type_index.keys.freeze
    end

    # Category information: { category_sym => { display_name:, types: [...] } }
    # @return [Hash]
    def categories
      @categories ||= build_categories.freeze
    end

    # Get the category symbol for a room type
    # @param type [String] room type name
    # @return [Symbol, nil]
    def category_for(type)
      entry = type_index[type.to_s]
      entry&.[](:category)
    end

    # Get all type names in a category
    # @param category [Symbol, String] category name
    # @return [Array<String>]
    def types_in_category(category)
      categories[category.to_sym]&.[](:types) || []
    end

    # Category-grouped hash matching Room::ROOM_TYPES format for backward compat
    # @return [Hash{Symbol => Array<String>}]
    def grouped_types
      @grouped_types ||= categories.transform_values { |c| c[:types] }.freeze
    end

    # ========================================
    # Property Lookups
    # ========================================

    # Get environment for a room type (:indoor, :outdoor, :underground)
    # @param type [String] room type name
    # @return [Symbol]
    def environment(type)
      entry = type_index[type.to_s]
      return :indoor unless entry

      (entry[:environment] || defaults[:environment] || 'indoor').to_sym
    end

    # Get admin badge color for a room type
    # @param type [String] room type name
    # @return [String]
    def badge_color(type)
      entry = type_index[type.to_s]
      return defaults[:badge_color] || 'secondary' unless entry

      entry[:badge_color] || defaults[:badge_color] || 'secondary'
    end

    # Get landmark icon for a room type
    # @param type [String] room type name
    # @return [String]
    def icon(type)
      entry = type_index[type.to_s]
      return defaults[:icon] || '[Place]' unless entry

      entry[:icon] || defaults[:icon] || '[Place]'
    end

    # Get battle map generation config for a room type
    # Returns merged config (type-specific overrides on top of defaults)
    # @param type [String] room type name
    # @return [Hash{Symbol => Object}]
    def battle_map(type)
      entry = type_index[type.to_s]
      default_bm = defaults_battle_map

      return default_bm unless entry && entry[:battle_map]

      default_bm.merge(entry[:battle_map])
    end

    # ========================================
    # Tag-Based Queries
    # ========================================

    # Get all types with a given tag
    # @param tag [Symbol, String] tag name
    # @return [Array<String>]
    def tagged(tag)
      tag_index[tag.to_s] || EMPTY_ARRAY
    end

    EMPTY_ARRAY = [].freeze
    private_constant :EMPTY_ARRAY

    # Check if a type has a specific tag
    # @param type [String] room type name
    # @param tag [Symbol, String] tag name
    # @return [Boolean]
    def tagged?(type, tag)
      entry = type_index[type.to_s]
      return false unless entry

      entry[:tags]&.include?(tag.to_s) || false
    end

    # ========================================
    # Convenience Predicates
    # ========================================

    # @param type [String]
    # @return [Boolean]
    def outdoor?(type)
      environment(type) == :outdoor
    end

    # @param type [String]
    # @return [Boolean]
    def indoor?(type)
      environment(type) == :indoor
    end

    # @param type [String]
    # @return [Boolean]
    def underground?(type)
      environment(type) == :underground
    end

    # @param type [String]
    # @return [Boolean]
    def street?(type)
      tagged?(type, :street)
    end

    # @param type [String]
    # @return [Boolean]
    def building_entrance?(type)
      tagged?(type, :building_entrance)
    end

    # @param type [String]
    # @return [Boolean]
    def interior?(type)
      tagged?(type, :interior)
    end

    # @param type [String]
    # @return [Boolean]
    def combat_zone?(type)
      tagged?(type, :combat_zone)
    end

    # ========================================
    # Development / Reload
    # ========================================

    # Reload config from disk (for development)
    def reload!
      @raw = nil
      @type_index = nil
      @tag_index = nil
      @all_types = nil
      @categories = nil
      @grouped_types = nil
      @defaults_battle_map = nil
      type_index
    end

    private

    # Load raw YAML
    def raw
      @raw ||= begin
        path = File.join(__dir__, 'room_types.yml')
        YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: true)
      end
    end

    # Default values from YAML
    def defaults
      @defaults ||= (raw['defaults'] || {}).freeze
    end

    # Default battle map config with symbolized keys
    def defaults_battle_map
      @defaults_battle_map ||= symbolize_battle_map(defaults['battle_map'] || {}).freeze
    end

    # Build the type index: { 'type_name' => { category:, environment:, badge_color:, icon:, tags:, battle_map: } }
    def type_index
      @type_index ||= build_type_index.freeze
    end

    # Build the tag index: { 'tag_name' => ['type1', 'type2', ...] }
    def tag_index
      @tag_index ||= build_tag_index.freeze
    end

    def build_type_index
      index = {}
      cats = raw['categories'] || {}

      cats.each do |cat_name, cat_data|
        types = cat_data['types'] || {}
        types.each do |type_name, type_data|
          type_data ||= {}
          index[type_name] = {
            category: cat_name.to_sym,
            environment: type_data['environment'],
            badge_color: type_data['badge_color'],
            icon: type_data['icon'],
            tags: type_data['tags'],
            battle_map: type_data['battle_map'] ? symbolize_battle_map(type_data['battle_map']) : nil
          }
        end
      end

      index
    end

    def build_tag_index
      index = {}

      type_index.each do |type_name, entry|
        next unless entry[:tags]

        entry[:tags].each do |tag|
          (index[tag] ||= []) << type_name
        end
      end

      # Freeze all arrays
      index.transform_values!(&:freeze)
      index
    end

    def build_categories
      cats = raw['categories'] || {}
      result = {}

      cats.each do |cat_name, cat_data|
        types = (cat_data['types'] || {}).keys
        result[cat_name.to_sym] = {
          display_name: cat_data['display_name'] || cat_name.capitalize,
          types: types.freeze
        }
      end

      result
    end

    # Convert battle map hash keys to symbols for consistency with existing code
    def symbolize_battle_map(hash)
      hash.each_with_object({}) do |(k, v), result|
        result[k.to_sym] = v
      end
    end
  end
end
