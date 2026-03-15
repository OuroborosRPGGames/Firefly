# frozen_string_literal: true

require_relative '../helpers/canvas_helper'

class RoomFeature < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  # Feature type constants
  WALL_TYPES = %w[wall].freeze
  OPENING_TYPES = %w[door opening archway gate hatch portal staircase elevator].freeze
  # Physical feature directions (excludes exit/enter which are logical, not spatial)
  VALID_DIRECTIONS = (CanvasHelper::VALID_DIRECTIONS - %w[exit enter]).freeze

  many_to_one :room
  many_to_one :connected_room, class: :Room
  one_to_many :room_sightlines, key: :through_feature_id

  # === LEGACY ALIASES ===
  # sight_range was replaced with sight_reduction in the schema
  # sight_range: 0-100 (higher = better sight)
  # sight_reduction: 0.0-1.0 (0 = full sight, 1 = no sight)

  def sight_range
    # Convert sight_reduction to sight_range for backward compatibility
    reduction = self[:sight_reduction] || 0.0
    ((1.0 - reduction) * 100).round
  end

  def sight_range=(val)
    # Convert sight_range (0-100) to sight_reduction (0.0-1.0)
    range_value = val.to_f.clamp(0, 100)
    self[:sight_reduction] = 1.0 - (range_value / 100.0)
  end

  def validate
    super
    validates_presence [:room_id, :feature_type]
    validates_includes ['wall', 'door', 'window', 'opening', 'archway', 'portal', 'gate', 'hatch', 'staircase', 'elevator'], :feature_type, allow_nil: true
    validates_includes VALID_DIRECTIONS, :direction, allow_nil: true

    # Note: sight_range column was removed from the database but may exist in old migrations
    # Using sight_reduction instead (inverse: 0.0 = full sight, 1.0 = no sight)
    if respond_to?(:sight_reduction) && sight_reduction
      validates_numeric :sight_reduction
      if sight_reduction < 0.0 || sight_reduction > 1.0
        errors.add(:sight_reduction, 'must be between 0 and 1')
      end
    end
  end

  # Check if this feature is a wall (blocks passage)
  def is_wall?
    WALL_TYPES.include?(feature_type)
  end
  alias_method :wall?, :is_wall?

  # Check if this feature is an opening (allows passage)
  def opening?
    OPENING_TYPES.include?(feature_type)
  end

  # Check if the feature is currently open
  def open?
    open_state == 'open'
  end

  # Alias for backward compatibility
  alias_method :is_open, :open?

  # Setter for is_open to convert boolean to open_state
  def is_open=(value)
    self.open_state = value ? 'open' : 'closed'
  end

  # Check if the feature currently allows sight
  def allows_sight_through?
    return false unless allows_sight
    return true if open?

    # Closed features might still allow sight based on feature type
    case feature_type
    when 'window'
      true # Can see through closed windows
    when 'door', 'gate'
      false # Can't see through closed doors
    when 'opening', 'archway', 'staircase', 'elevator'
      true # Always transparent
    when 'portal'
      true # Magical portals allow sight
    else
      false
    end
  end

  # Check if the feature allows movement
  def allows_movement_through?
    # Staircases and elevators are always passable
    return true if %w[staircase elevator].include?(feature_type)

    # Movement requires the feature to be open
    open?
  end

  # Calculate sight quality through this feature (0.0 = no sight, 1.0 = perfect sight)
  def sight_quality
    return 0.0 unless allows_sight_through?

    base_quality = 1.0

    # Reduce quality if not fully open
    base_quality *= 0.7 unless is_open

    # Reduce quality for certain feature types
    case feature_type
    when 'portal'
      base_quality *= 0.8 # Slight distortion
    end

    [base_quality, 0.0].max
  end

  # Get the position as coordinates
  def position
    [x, y, z]
  end

  # Check if a character at given coordinates can see through this feature
  def can_see_from_position?(char_x, char_y, char_z)
    return false unless allows_sight_through?

    # Distance check
    distance = Math.sqrt((char_x - x)**2 + (char_y - y)**2 + (char_z - z)**2)

    distance <= sight_range
  end

  # Check if this feature provides sight from a specific room
  def allows_sight_from_room?(from_room_id)
    allows_sight
  end

  # Returns all features relevant to a room: both owned features and
  # inbound features from adjacent rooms (with direction/orientation flipped).
  # Inbound features are wrapped so they appear as if they belong to this room.
  def self.visible_from(room)
    own = room.room_features
    own_ids = own.map(&:id).to_set

    # 1. Features explicitly connected via connected_room_id
    inbound = RoomFeature.where(connected_room_id: room.id)
                         .exclude(feature_type: 'wall')
                         .all
    seen_ids = own_ids + inbound.map(&:id).to_set

    # 2. Features from adjacent sibling rooms on shared wall boundaries
    boundary_features = find_boundary_features(room, seen_ids)

    own + inbound.map { |f| InboundFeatureWrapper.new(f) } +
      boundary_features.map { |f, dir| InboundFeatureWrapper.new(f, inferred_direction: dir) }
  end

  private_class_method def self.find_boundary_features(room, seen_ids)
    return [] unless room.inside_room_id

    tolerance = 2.0 # feet, matches RoomAdjacencyService::ADJACENCY_TOLERANCE
    results = [] # Array of [feature, inferred_direction]

    # Find sibling rooms (same parent, same z-range for same floor)
    siblings = Room.where(inside_room_id: room.inside_room_id)
                   .where(location_id: room.location_id)
                   .exclude(id: room.id)
                   .all

    siblings.each do |sibling|
      # Skip if different floor (z-ranges don't overlap)
      next if room.max_z.to_f <= sibling.min_z.to_f || room.min_z.to_f >= sibling.max_z.to_f

      # Determine shared boundaries and direction
      shared = shared_boundary(room, sibling, tolerance)
      next if shared.empty?

      # Get non-wall features from sibling that sit on the shared boundary
      sibling.room_features.each do |feature|
        next if feature.feature_type == 'wall'
        next if seen_ids.include?(feature.id)

        shared.each do |boundary_axis, boundary_value, direction|
          feature_coord = boundary_axis == :y ? feature.y.to_f : feature.x.to_f
          if (feature_coord - boundary_value).abs <= tolerance
            results << [feature, direction]
            seen_ids.add(feature.id)
            break # Don't add same feature twice
          end
        end
      end
    end

    results
  end

  private_class_method def self.shared_boundary(room, sibling, tolerance)
    boundaries = []

    # Check if rooms share x-range (needed for north/south boundaries)
    x_overlap = room.max_x.to_f > sibling.min_x.to_f + tolerance &&
                room.min_x.to_f < sibling.max_x.to_f - tolerance

    # Check if rooms share y-range (needed for east/west boundaries)
    y_overlap = room.max_y.to_f > sibling.min_y.to_f + tolerance &&
                room.min_y.to_f < sibling.max_y.to_f - tolerance

    # North boundary: room.max_y ~ sibling.min_y (sibling is north — higher Y = north)
    if x_overlap && (room.max_y.to_f - sibling.min_y.to_f).abs <= tolerance
      boundaries << [:y, room.max_y.to_f, 'north']
    end

    # South boundary: room.min_y ~ sibling.max_y (sibling is south — lower Y = south)
    if x_overlap && (room.min_y.to_f - sibling.max_y.to_f).abs <= tolerance
      boundaries << [:y, room.min_y.to_f, 'south']
    end

    # East boundary: room.max_x ~ sibling.min_x (sibling is east of room)
    if y_overlap && (room.max_x.to_f - sibling.min_x.to_f).abs <= tolerance
      boundaries << [:x, room.max_x.to_f, 'east']
    end

    # West boundary: room.min_x ~ sibling.max_x (sibling is west of room)
    if y_overlap && (room.min_x.to_f - sibling.max_x.to_f).abs <= tolerance
      boundaries << [:x, room.min_x.to_f, 'west']
    end

    boundaries
  end

  private

  def invalidate_sightline_cache
    # Remove cached sightlines that pass through this feature
    RoomSightline.where(through_feature_id: id).delete

    # Also remove sightlines between connected rooms
    if connected_room_id
      RoomSightline.where(
        from_room_id: [room_id, connected_room_id],
        to_room_id: [room_id, connected_room_id]
      ).delete
    end
  end
end
