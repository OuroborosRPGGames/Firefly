# frozen_string_literal: true

# Key tracks what doors/containers can be opened by what characters.
# Can be physical (item-based) or permission-based.
class Key < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character
  # NOTE: room_exit association removed - RoomExit model dropped in migration 298.
  # Navigation now uses spatial adjacency. Locks are on RoomFeatures (doors/gates).
  # The room_exit_id column remains for legacy data but is not used.
  many_to_one :room_feature
  many_to_one :item  # For containers

  KEY_TYPES = %w[physical master permission temporary].freeze

  def validate
    super
    validates_presence [:character_id, :key_type]
    validates_includes KEY_TYPES, :key_type

    # Must have at least one target
    # NOTE: room_exit_id is legacy and not validated - use room_feature_id for doors
    unless room_feature_id || item_id
      errors.add(:base, 'must have a target (feature or item)')
    end
  end

  def before_save
    super
    self.key_type ||= 'physical'
  end

  def physical?
    key_type == 'physical'
  end

  def master?
    key_type == 'master'
  end

  def temporary?
    key_type == 'temporary'
  end

  def expired?
    return false unless expires_at
    Time.now >= expires_at
  end

  # Check if key is currently valid (not expired)
  # Note: Named key_valid? to avoid overriding Sequel's valid? validation method
  def key_valid?
    !expired?
  end

  # Legacy method - room_exit no longer used
  # Kept for backward compatibility but always returns false
  def for_exit?
    false
  end

  def for_feature?
    !room_feature_id.nil?
  end

  def for_container?
    !item_id.nil?
  end

  # Check if character has a key to unlock something
  # Note: RoomExit is no longer used - navigation uses spatial adjacency
  # Locks are now on RoomFeatures (doors/gates) instead
  def self.can_unlock?(character, lockable)
    case lockable
    when RoomFeature
      where(character_id: character.id, room_feature_id: lockable.id).any?
    when Item
      where(character_id: character.id, item_id: lockable.id).any?
    else
      false
    end
  end
end
