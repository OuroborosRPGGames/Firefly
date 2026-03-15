# frozen_string_literal: true

class Relationship < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character
  many_to_one :target_character, class: :Character

  status_enum :status, %w[pending accepted blocked unfriended]
  BLOCK_TYPES = %w[dm ooc channels interaction perception].freeze

  def before_validation
    super
    self.status ||= 'pending'
  end

  def validate
    super
    validates_presence [:character_id, :target_character_id]
    validates_unique [:character_id, :target_character_id]
    validate_status_enum

    if character_id == target_character_id
      errors.add(:target_character_id, 'cannot be the same as character_id')
    end
  end

  # Granular blocking methods
  def any_block?
    block_dm || block_ooc || block_channels || block_interaction || block_perception
  end

  def blocked_for?(type)
    case type.to_s
    when 'dm' then block_dm
    when 'ooc' then block_ooc
    when 'channels' then block_channels
    when 'interaction' then block_interaction
    when 'perception' then block_perception
    else false
    end
  end

  def active_blocks
    blocks = []
    blocks << 'dm' if block_dm
    blocks << 'ooc' if block_ooc
    blocks << 'channels' if block_channels
    blocks << 'interaction' if block_interaction
    blocks << 'perception' if block_perception
    blocks
  end

  # Follow permission
  def allow_follow!
    update(can_follow: true)
  end

  def revoke_follow!
    update(can_follow: false)
  end

  # Dress permission
  def allow_dress!
    update(can_dress: true)
  end

  def revoke_dress!
    update(can_dress: false)
  end

  # Undress permission
  def allow_undress!
    update(can_undress: true)
  end

  def revoke_undress!
    update(can_undress: false)
  end

  # Generic interaction permission
  def allow_interact!
    update(can_interact: true)
  end

  def revoke_interact!
    update(can_interact: false)
  end

  def accept!
    update(status: 'accepted')
  end

  def block!
    update(status: 'blocked')
  end

  # Unfriend - preserves relationship record but marks as unfriended
  def unfriend!
    update(
      status: 'unfriended',
      can_follow: false,
      can_dress: false,
      can_undress: false,
      can_interact: false
    )
  end

  # Restore from unfriended status
  def refriend!
    update(status: 'accepted')
  end

  # Block specific types
  def block_type!(type)
    case type.to_s
    when 'dm' then update(block_dm: true)
    when 'ooc' then update(block_ooc: true)
    when 'channels' then update(block_channels: true)
    when 'interaction' then update(block_interaction: true)
    when 'perception' then update(block_perception: true)
    when 'all'
      update(
        block_dm: true,
        block_ooc: true,
        block_channels: true,
        block_interaction: true,
        block_perception: true
      )
    end
  end

  def unblock_type!(type)
    case type.to_s
    when 'dm' then update(block_dm: false)
    when 'ooc' then update(block_ooc: false)
    when 'channels' then update(block_channels: false)
    when 'interaction' then update(block_interaction: false)
    when 'perception' then update(block_perception: false)
    when 'all'
      update(
        block_dm: false,
        block_ooc: false,
        block_channels: false,
        block_interaction: false,
        block_perception: false
      )
    end
  end

  def clear_all_blocks!
    update(
      block_dm: false,
      block_ooc: false,
      block_channels: false,
      block_interaction: false,
      block_perception: false
    )
  end

  class << self
    def between(character, target)
      first(character_id: character.id, target_character_id: target.id)
    end

    def can_follow?(follower, leader)
      rel = between(follower, leader)
      !!(rel&.accepted? && rel&.can_follow)
    end

    def can_dress?(actor, target)
      rel = between(actor, target)
      !!(rel&.accepted? && rel&.can_dress)
    end

    def can_undress?(actor, target)
      rel = between(actor, target)
      !!(rel&.accepted? && rel&.can_undress)
    end

    def can_interact?(actor, target)
      rel = between(actor, target)
      !!(rel&.accepted? && rel&.can_interact)
    end

    def find_or_create_between(character, target)
      between(character, target) || create(
        character_id: character.id,
        target_character_id: target.id,
        status: 'pending'
      )
    end

    # Check if either direction has any block
    def blocked_between?(char1, char2)
      rel1 = between(char1, char2)
      rel2 = between(char2, char1)
      rel1&.any_block? || rel2&.any_block?
    end

    # Check if blocked for a specific type in either direction
    def blocked_for_between?(char1, char2, type)
      rel1 = between(char1, char2)
      rel2 = between(char2, char1)
      rel1&.blocked_for?(type) || rel2&.blocked_for?(type)
    end

    # Get all relationships where character has blocked someone
    def blocked_by(character)
      where(character_id: character.id).all.select(&:any_block?)
    end
  end
end
