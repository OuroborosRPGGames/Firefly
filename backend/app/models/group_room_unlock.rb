# frozen_string_literal: true

# GroupRoomUnlock grants room access to all members of a group.
# Mirrors the RoomUnlock pattern but for group-based permissions.
class GroupRoomUnlock < Sequel::Model
  plugin :timestamps
  plugin :validation_helpers

  many_to_one :group
  many_to_one :room

  def validate
    super
    validates_presence [:group_id, :room_id]
  end

  def expired?
    expires_at && expires_at < Time.now
  end

  def permanent?
    expires_at.nil?
  end

  # Scope: only non-expired unlocks
  def self.active
    where { (expires_at =~ nil) | (expires_at > Sequel::CURRENT_TIMESTAMP) }
  end

  # Scope: for a specific room
  def self.for_room(room)
    where(room_id: room.is_a?(Room) ? room.id : room)
  end

  # Scope: for a specific group
  def self.for_group(group)
    where(group_id: group.is_a?(Group) ? group.id : group)
  end
end
