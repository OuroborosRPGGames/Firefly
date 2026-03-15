# frozen_string_literal: true

class RoomSightline < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :from_room, class: :Room
  many_to_one :to_room, class: :Room

  # === EXPLICIT COLUMN ACCESSORS ===
  # Sequel caches schema at class load time. Columns added later need explicit accessors.

  def bidirectional
    self[:bidirectional]
  end

  def bidirectional=(val)
    self[:bidirectional] = val
  end

  def validate
    super
    validates_presence [:from_room_id, :to_room_id, :has_sight, :sight_quality]
    validates_numeric :sight_quality, minimum: 0.0, maximum: 1.0, allow_nil: true

    # Can't have sightline to same room
    if from_room_id == to_room_id
      errors.add(:to_room_id, 'cannot be the same as from_room_id')
    end
  end

  # Check if characters can see through this sightline given their positions
  def allows_sight_between?(from_x, from_y, from_z, to_x, to_y, to_z)
    return false unless has_sight

    # Calculate distance
    distance = Math.sqrt((to_x - from_x)**2 + (to_y - from_y)**2 + (to_z - from_z)**2)

    # Apply sight quality - lower quality means harder to see at distance
    quality = sight_quality || 1.0
    effective_distance = quality.positive? ? distance / quality : distance

    # Base sight range (could be affected by lighting, character abilities, etc.)
    base_sight_range = 30.0

    effective_distance <= base_sight_range
  end

  # Calculate and cache sightline between two rooms
  # Returns existing sightline if present, or creates a simple one based on room features
  def self.calculate_sightline(from_room, to_room)
    # Check for existing sightline
    existing = where(from_room_id: from_room.id, to_room_id: to_room.id).first
    return existing if existing

    # Calculate new sightline based on connecting features
    has_sight = false
    sight_quality = 0.0

    # Direct connection through room features
    connecting_features = RoomFeature.where(
      room_id: from_room.id,
      connected_room_id: to_room.id
    ).or(
      room_id: to_room.id,
      connected_room_id: from_room.id
    ).all

    # Find the best sightline through available features
    connecting_features.each do |feature|
      if feature.allows_sight && feature.is_open
        feature_quality = feature.sight_range.to_f / 100.0
        feature_quality = 1.0 if feature_quality > 1.0
        feature_quality = 0.5 if feature_quality <= 0 # Default quality

        if feature_quality > sight_quality
          has_sight = true
          sight_quality = feature_quality
        end
      end
    end

    # Apply room-level modifiers
    if has_sight
      # Lighting affects sight quality
      from_lighting = from_room.respond_to?(:lighting_level) ? (from_room.lighting_level || 5) : 5
      to_lighting = to_room.respond_to?(:lighting_level) ? (to_room.lighting_level || 5) : 5
      avg_lighting = (from_lighting + to_lighting) / 2.0

      # Poor lighting reduces sight quality
      if avg_lighting < 3
        sight_quality *= (avg_lighting / 3.0)
      end
    end

    # Create sightline record with actual schema columns
    sightline_data = {
      from_room_id: from_room.id,
      to_room_id: to_room.id,
      has_sight: has_sight,
      sight_quality: sight_quality,
      bidirectional: true  # Default to bidirectional sightlines
    }

    create(sightline_data)
  end
end