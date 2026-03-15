# frozen_string_literal: true

# Channel represents IC or OOC public/private communication channels.
# Can be global, area-specific, or group-based.
class Channel < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :universe
  many_to_one :owner, class: :Character
  one_to_many :channel_members

  CHANNEL_TYPES = %w[ooc ic global area group private].freeze

  def validate
    super
    validates_presence [:name, :channel_type]
    validates_max_length 50, :name
    validates_unique [:universe_id, :name]
    validates_includes CHANNEL_TYPES, :channel_type
  end

  def before_save
    super
    self.channel_type ||= 'ooc'
    self.is_default ||= false
  end

  def ooc?
    channel_type == 'ooc'
  end

  def ic?
    channel_type == 'ic'
  end

  def global?
    channel_type == 'global'
  end

  def private?
    channel_type == 'private'
  end

  def members
    channel_members_dataset.eager(:character)
  end

  def add_member(character, role: 'member')
    ChannelMember.find_or_create(channel_id: id, character_id: character.id) do |m|
      m.role = role
    end
  end

  def remove_member(character)
    ChannelMember.where(channel_id: id, character_id: character.id).delete
  end

  def member?(character)
    ChannelMember.where(channel_id: id, character_id: character.id).any?
  end

  # ========================================
  # Default Channel Class Methods
  # ========================================

  class << self
    # Find the default channel for new/returning players
    # Priority: is_default=true > channel named "Newbie" > first OOC channel
    # @param universe_id [Integer, nil] Optional universe to scope to
    # @return [Channel, nil]
    def default_channel(universe_id: nil)
      # First, look for explicitly marked default channel
      channel = where(is_default: true)
      channel = channel.where(universe_id: universe_id) if universe_id
      result = channel.first
      return result if result

      # Fall back to channel named "Newbie" (case-insensitive)
      channel = where(Sequel.ilike(:name, 'newbie'))
      channel = channel.where(universe_id: universe_id) if universe_id
      result = channel.first
      return result if result

      # Last resort: first public OOC channel
      channel = where(channel_type: 'ooc', is_public: true)
      channel = channel.where(universe_id: universe_id) if universe_id
      channel.first
    end

    # Ensure a character is in the default channel
    # Called on login to guarantee at least one channel membership
    # @param character [Character] The character to check/add
    # @return [Channel, nil] The default channel (nil if none exists)
    def ensure_default_membership(character)
      return nil unless character

      default = default_channel
      return nil unless default

      # Check if they're already a member of ANY channel
      existing_membership = ChannelMember.where(character_id: character.id).any?

      # If they have no channels at all, add them to the default
      unless existing_membership
        default.add_member(character)
      end

      default
    end

    # Find or create the Newbie channel and mark it as default
    # Used by seed scripts to ensure the channel exists
    # @param universe_id [Integer, nil] Optional universe to scope to
    # @return [Channel] The Newbie channel
    def find_or_create_newbie_channel(universe_id: nil)
      attrs = {
        name: 'Newbie',
        universe_id: universe_id
      }

      find_or_create(attrs) do |ch|
        ch.channel_type = 'ooc'
        ch.description = 'A friendly channel for new players to ask questions and get help.'
        ch.is_public = true
        ch.is_default = true
      end
    end
  end
end
