# frozen_string_literal: true

# Block represents privacy-preserving blocks between users or characters.
# OOC blocks apply at account level, IC blocks at character level.
class Block < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :blocker_user, class: :User
  many_to_one :blocked_user, class: :User
  many_to_one :blocker_character, class: :Character
  many_to_one :blocked_character, class: :Character

  BLOCK_TYPES = %w[ooc ic].freeze

  def validate
    super
    validates_presence [:block_type]
    validates_includes BLOCK_TYPES, :block_type

    # OOC blocks require users
    if block_type == 'ooc'
      validates_presence [:blocker_user_id, :blocked_user_id]
    end

    # IC blocks require characters
    if block_type == 'ic'
      validates_presence [:blocker_character_id, :blocked_character_id]
    end
  end

  def before_save
    super
    self.created_at ||= Time.now
  end

  def ooc?
    block_type == 'ooc'
  end

  def ic?
    block_type == 'ic'
  end

  # Check if user A has blocked user B (OOC)
  def self.user_blocked?(blocker_user, blocked_user)
    where(
      block_type: 'ooc',
      blocker_user_id: blocker_user.id,
      blocked_user_id: blocked_user.id
    ).any?
  end

  # Check if character A has blocked character B (IC)
  def self.character_blocked?(blocker_character, blocked_character)
    where(
      block_type: 'ic',
      blocker_character_id: blocker_character.id,
      blocked_character_id: blocked_character.id
    ).any?
  end

  # Check if either party has blocked the other (any direction)
  def self.blocked_either_way?(user1, user2)
    user_blocked?(user1, user2) || user_blocked?(user2, user1)
  end
end
