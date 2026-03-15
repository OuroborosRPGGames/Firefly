# frozen_string_literal: true

# RoomTemplate defines templates for temporary/pooled rooms like vehicle interiors,
# taxi cabs, train compartments, etc.
#
# Templates specify dimensions, default places (seats), and other configuration
# that gets applied when instantiating a room from the pool.
class RoomTemplate < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  # Template types for different use cases
  TEMPLATE_TYPES = %w[
    vehicle_interior
    taxi
    train_compartment
    shuttle
    carriage
    boat_cabin
    delve_room
  ].freeze

  # Categories for different vehicle/transport types
  CATEGORIES = %w[
    sedan
    suv
    bus
    limousine
    taxi
    train
    subway
    shuttle
    carriage
    hansom
    wagon
    horse
    rowboat
    ferry
    airship
    delve
  ].freeze

  # Associations
  many_to_one :universe
  one_to_many :rooms, key: :room_template_id
  one_to_many :vehicles, key: :preferred_template_id

  # Validations
  def validate
    super
    validates_presence [:name, :template_type, :category]
    validates_includes TEMPLATE_TYPES, :template_type, message: 'is not a valid template type'
    validates_includes CATEGORIES, :category, message: 'is not a valid category'
    validates_min_length 1, :name
    validates_max_length 100, :name
    validates_numeric :width, allow_nil: true
    validates_numeric :length, allow_nil: true
    validates_numeric :height, allow_nil: true
    validates_numeric :passenger_capacity, allow_nil: true, only_integer: true
  end

  # Create a room from this template
  # @param location [Location] the location for the pool room
  # @param name_suffix [String, nil] optional suffix to append to room name
  # @return [Room] the newly created room
  def instantiate_room(location:, name_suffix: nil)
    room_name = name_suffix ? "#{name} - #{name_suffix}" : name

    Room.create(
      location_id: location.id,
      name: room_name,
      short_description: short_description || "Interior of a #{category.tr('_', ' ')}",
      long_description: long_description,
      room_type: room_type || 'standard',
      min_x: 0.0,
      max_x: effective_width,
      min_y: 0.0,
      max_y: effective_length,
      min_z: 0.0,
      max_z: effective_height,
      is_temporary: true,
      pool_status: 'available',
      room_template_id: id
    )
  end

  # Set up default places (seats, etc.) for a room based on template config
  # @param room [Room] the room to add places to
  def setup_default_places(room)
    default_places_config.each do |place_config|
      Place.create(
        room_id: room.id,
        name: place_config['name'] || 'Seat',
        description: place_config['description'],
        capacity: place_config['capacity'] || 1,
        x: place_config['x']&.to_f || 0.0,
        y: place_config['y']&.to_f || 0.0,
        is_furniture: true
      )
    end
  end

  # Get default places configuration as array
  # @return [Array<Hash>] array of place configuration hashes
  def default_places_config
    default_places || []
  end

  # Get custom properties
  # @return [Hash] the properties hash
  def custom_properties
    properties || {}
  end

  # Get effective width, using default if not set
  # @return [Float] width in feet
  def effective_width
    width || 10.0
  end

  # Get effective length, using default if not set
  # @return [Float] length in feet
  def effective_length
    length || 15.0
  end

  # Get effective height, using default if not set
  # @return [Float] height in feet
  def effective_height
    height || 8.0
  end

  # Get effective passenger capacity
  # @return [Integer] capacity
  def effective_capacity
    passenger_capacity || 4
  end

  # Human-readable display name for the category
  # @return [String] formatted category name
  def category_display_name
    category.tr('_', ' ').split.map(&:capitalize).join(' ')
  end

  # Human-readable display name for the template type
  # @return [String] formatted type name
  def type_display_name
    template_type.tr('_', ' ').split.map(&:capitalize).join(' ')
  end

  class << self
    # Find a template for a vehicle type
    # @param vehicle_type [String] the vehicle type (e.g., 'sedan', 'taxi', 'train')
    # @param template_type [String] the template type (defaults to 'vehicle_interior')
    # @return [RoomTemplate, nil] matching template or nil
    def for_vehicle_type(vehicle_type, template_type: 'vehicle_interior')
      category = normalize_category(vehicle_type)

      first(
        category: category,
        template_type: template_type,
        active: true
      ) || first(template_type: template_type, active: true)
    end

    # Find a template for a journey travel mode and vehicle type
    # @param travel_mode [String] the travel mode (land, water, air, rail)
    # @param vehicle_type [String] the vehicle type
    # @return [RoomTemplate, nil] matching template or nil
    def for_journey(travel_mode:, vehicle_type:)
      type = case travel_mode.to_s
             when 'rail' then 'train_compartment'
             when 'water' then 'boat_cabin'
             when 'air' then 'shuttle'
             else 'vehicle_interior'
             end

      category = normalize_category(vehicle_type)

      first(category: category, template_type: type, active: true) ||
        first(template_type: type, active: true)
    end

    # Normalize a vehicle type string to a valid category
    # @param vehicle_type [String] the input vehicle type
    # @return [String] normalized category
    def normalize_category(vehicle_type)
      mapping = {
        'car' => 'sedan',
        'automobile' => 'sedan',
        'taxi' => 'taxi',
        'cab' => 'taxi',
        'bus' => 'bus',
        'coach' => 'bus',
        'train' => 'train',
        'steam_train' => 'train',
        'maglev' => 'train',
        'subway' => 'subway',
        'metro' => 'subway',
        'carriage' => 'carriage',
        'hansom' => 'hansom',
        'hansom_cab' => 'hansom',
        'wagon' => 'wagon',
        'horse' => 'horse',
        'horseback' => 'horse',
        'boat' => 'rowboat',
        'rowboat' => 'rowboat',
        'ferry' => 'ferry',
        'ship' => 'ferry',
        'airplane' => 'shuttle',
        'plane' => 'shuttle',
        'shuttle' => 'shuttle',
        'spacecraft' => 'shuttle',
        'airship' => 'airship',
        'zeppelin' => 'airship'
      }

      mapping[vehicle_type.to_s.downcase] || 'sedan'
    end

    # Get all active templates grouped by type
    # @return [Hash<String, Array<RoomTemplate>>] templates grouped by template_type
    def by_type
      where(active: true).all.group_by(&:template_type)
    end

    # Get all active templates grouped by category
    # @return [Hash<String, Array<RoomTemplate>>] templates grouped by category
    def by_category
      where(active: true).all.group_by(&:category)
    end
  end
end
