# frozen_string_literal: true

# Group represents social groups, factions, guilds, clans, etc.
# Can have private channels, location access, and other permissions.
# Secret groups use member handles (aliases) instead of real names.
class Group < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :universe
  many_to_one :leader, class: :Character, key: :leader_character_id
  many_to_one :channel
  one_to_many :group_members
  one_to_many :group_room_unlocks

  GROUP_TYPES = %w[faction guild party clan family business government].freeze
  status_enum :status, %w[active inactive disbanded]

  def validate
    super
    validates_presence [:name, :group_type]
    validates_max_length 100, :name
    validates_max_length 20, :symbol if symbol
    validates_unique [:universe_id, :name]
    validates_includes GROUP_TYPES, :group_type
    validate_status_enum
  end

  def before_save
    super
    self.group_type ||= 'faction'
    self.is_public = true if is_public.nil?
    self.is_secret = false if is_secret.nil?
    self.founded_at ||= Time.now
    self.status ||= 'active'
  end

  # ========================================
  # Visibility Methods
  # ========================================

  def secret?
    is_secret == true
  end

  def public_listing?
    !secret? && is_public
  end

  # ========================================
  # Member Management
  # ========================================

  def members
    group_members_dataset.eager(:character)
  end

  def active_members
    members.where(status: 'active')
  end

  def add_member(character, rank: 'member', handle: nil)
    gm = GroupMember.find_or_create(group_id: id, character_id: character.id) do |m|
      m.rank = rank
      m.status = 'active'
      m.handle = handle
    end

    # Ensure they're in the channel too
    channel&.add_member(character, role: officer_rank?(rank) ? 'moderator' : 'member')

    gm
  end

  def remove_member(character)
    GroupMember.where(group_id: id, character_id: character.id).update(status: 'removed')
    # Also remove from channel if exists
    channel&.remove_member(character)
  end

  def member?(character)
    return false unless character

    GroupMember.where(group_id: id, character_id: character.id, status: 'active').any?
  end

  def member_count
    active_members.count
  end

  def membership_for(character)
    return nil unless character

    GroupMember.first(group_id: id, character_id: character.id, status: 'active')
  end

  def officer?(character)
    membership = membership_for(character)
    membership&.officer? || false
  end

  def leader?(character)
    return false unless character

    leader_character_id == character.id
  end

  # ========================================
  # Channel Integration
  # ========================================

  def create_channel!
    return channel if channel

    new_channel = Channel.create(
      name: name,
      channel_type: 'group',
      universe_id: universe_id,
      is_public: false
    )
    update(channel_id: new_channel.id)

    # Add all active members to the channel
    active_members.each do |gm|
      new_channel.add_member(gm.character, role: gm.officer? ? 'moderator' : 'member')
    end

    new_channel
  end

  def destroy_channel!
    return unless channel

    channel.destroy
    update(channel_id: nil)
  end

  # ========================================
  # Room Access
  # ========================================

  def grant_room_access!(room, permanent: false)
    room_id = room.is_a?(Room) ? room.id : room
    existing = GroupRoomUnlock.first(group_id: id, room_id: room_id)

    if existing
      expires_at = permanent ? nil : Time.now + (24 * 60 * 60)
      existing.update(expires_at: expires_at)
      existing
    else
      GroupRoomUnlock.create(
        group_id: id,
        room_id: room_id,
        expires_at: permanent ? nil : Time.now + (24 * 60 * 60)
      )
    end
  end

  def revoke_room_access!(room)
    room_id = room.is_a?(Room) ? room.id : room
    GroupRoomUnlock.where(group_id: id, room_id: room_id).delete
  end

  def has_room_access?(room)
    room_id = room.is_a?(Room) ? room.id : room
    GroupRoomUnlock.where(group_id: id, room_id: room_id)
                   .where { (expires_at =~ nil) | (expires_at > Sequel::CURRENT_TIMESTAMP) }
                   .any?
  end

  # ========================================
  # Display Methods
  # ========================================

  def display_name
    if symbol && !symbol.to_s.strip.empty?
      "#{symbol} #{name}"
    else
      name
    end
  end

  def roster_for(viewer_character)
    active_members.map do |gm|
      {
        display_name: gm.display_name_for(viewer_character),
        rank: gm.rank,
        is_leader: gm.character_id == leader_character_id,
        joined_at: gm.joined_at
      }
    end
  end

  private

  def officer_rank?(rank)
    %w[officer leader].include?(rank)
  end
end
