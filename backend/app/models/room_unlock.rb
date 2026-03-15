# frozen_string_literal: true

# Tracks temporary and permanent access grants for owned rooms.
# - character_id NULL = public unlock (anyone can enter)
# - expires_at NULL = permanent access
# - expires_at set = temporary access until that time

class RoomUnlock < Sequel::Model
  plugin :timestamps
  plugin :validation_helpers

  many_to_one :room
  many_to_one :character

  def validate
    super
    validates_presence :room_id
  end

  def expired?
    expires_at && expires_at < Time.now
  end

  def permanent?
    expires_at.nil?
  end

  def public_unlock?
    character_id.nil?
  end

  # Scope: only non-expired unlocks
  def self.active
    where { (expires_at =~ nil) | (expires_at > Sequel::CURRENT_TIMESTAMP) }
  end

  # Scope: public unlocks only
  def self.public_unlocks
    where(character_id: nil)
  end

  # Scope: for a specific character
  def self.for_character(character)
    where(character_id: character.id)
  end
end
