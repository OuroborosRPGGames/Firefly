# frozen_string_literal: true

class CoverObjectType < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  CATEGORIES = %w[furniture vehicle nature structure].freeze
  SIZES = %w[small medium large huge].freeze

  def validate
    super
    validates_presence [:name]
    validates_unique :name
    validates_max_length 50, :name
    validates_includes CATEGORIES, :category, allow_nil: true
    validates_includes SIZES, :size, allow_nil: true
    validates_integer :default_height, only_if: ->(obj) { obj.default_height }
    validates_integer :default_hp, only_if: ->(obj) { obj.default_hp }
    validates_integer :hex_width, only_if: ->(obj) { obj.hex_width }
    validates_integer :hex_height, only_if: ->(obj) { obj.hex_height }
  end

  # Check if this cover object is appropriate for a given room type
  # @param room_type [String] the room type to check
  # @return [Boolean]
  def appropriate_for_room_type?(room_type)
    return true if appropriate_room_types.nil? || appropriate_room_types.empty?

    room_type_list = appropriate_room_types.split(',').map(&:strip)
    room_type_list.include?(room_type.to_s)
  end

  # Get properties as parsed hash
  # @return [Hash]
  def parsed_properties
    return {} unless properties

    if properties.is_a?(Hash)
      properties
    else
      JSON.parse(properties.to_s)
    end
  rescue JSON::ParserError
    {}
  end

  # Check if this object is multi-hex (large)
  # @return [Boolean]
  def multi_hex?
    (hex_width || 1) > 1 || (hex_height || 1) > 1
  end

  # Get the total hex count for this object
  # @return [Integer]
  def hex_count
    (hex_width || 1) * (hex_height || 1)
  end

  # Get cover description
  # @return [String]
  def cover_description
    default_cover_value.to_i > 0 ? 'provides cover' : 'no cover'
  end

  # Class method to find objects appropriate for a room type
  # @param room_type [String]
  # @return [Array<CoverObjectType>]
  def self.for_room_type(room_type)
    all.select { |obj| obj.appropriate_for_room_type?(room_type) }
  end

  # Class method to get objects by category
  # @param category [String]
  # @return [Array<CoverObjectType>]
  def self.by_category(category)
    where(category: category).order(:name).all
  end

  # Class method to get destroyable objects
  # @return [Array<CoverObjectType>]
  def self.destroyable
    where(is_destroyable: true).order(:name).all
  end

  # Class method to get explosive objects
  # @return [Array<CoverObjectType>]
  def self.explosive
    where(is_explosive: true).order(:name).all
  end

  # Class method to get flammable objects
  # @return [Array<CoverObjectType>]
  def self.flammable
    where(is_flammable: true).order(:name).all
  end
end
