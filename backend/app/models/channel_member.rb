# frozen_string_literal: true

# ChannelMember links a Character to a Channel with their role and settings.
class ChannelMember < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :channel
  many_to_one :character

  ROLES = %w[member moderator admin owner].freeze

  def validate
    super
    validates_presence [:channel_id, :character_id]
    validates_unique [:channel_id, :character_id]
    validates_includes ROLES, :role if role
  end

  def before_save
    super
    self.role ||= 'member'
    self.is_muted ||= false
    self.joined_at ||= Time.now
  end

  def moderator?
    %w[moderator admin owner].include?(role)
  end

  def admin?
    %w[admin owner].include?(role)
  end

  def owner?
    role == 'owner'
  end

  def mute!
    update(is_muted: true)
  end

  def unmute!
    update(is_muted: false)
  end

  def can_speak?
    !is_muted
  end
end
