# frozen_string_literal: true

class ArrangedScene < Sequel::Model
  include StatusEnum
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  # Core relationships
  many_to_one :npc_character, class: :Character, key: :npc_character_id
  many_to_one :pc_character, class: :Character, key: :pc_character_id
  many_to_one :meeting_room, class: :Room, key: :meeting_room_id
  many_to_one :rp_room, class: :Room, key: :rp_room_id
  many_to_one :created_by, class: :Character, key: :created_by_id

  # Session/memory tracking
  many_to_one :world_memory_session, class: :WorldMemorySession
  many_to_one :world_memory, class: :WorldMemory

  # Scene-specific triggers and clues
  one_to_many :triggers, key: :arranged_scene_id
  one_to_many :clues, key: :arranged_scene_id

  status_enum :status, %w[pending active completed cancelled expired]

  def validate
    super
    validates_presence [:npc_character_id, :pc_character_id, :meeting_room_id, :rp_room_id, :created_by_id]
    validate_status_enum
  end

  # Check if scene is available to be triggered
  def available?
    pending? &&
      (available_from.nil? || Time.now >= available_from) &&
      (expires_at.nil? || Time.now < expires_at)
  end

  # Get display name (or generate one)
  def display_name
    scene_name || "Meeting with #{npc_character&.full_name || 'NPC'}"
  end

  # Get invitation message (or generate default)
  def invitation_text
    invitation_message || default_invitation_message
  end

  # Get active NPC instance for this scene
  def npc_instance
    return nil unless npc_character_id

    CharacterInstance.first(character_id: npc_character_id, online: true)
  end

  # Get active PC instance for this scene
  def pc_instance
    return nil unless pc_character_id

    CharacterInstance.first(character_id: pc_character_id, online: true)
  end

  # Access metadata as a hash
  def metadata
    val = super
    case val
    when Hash
      val
    when String
      JSON.parse(val)
    else
      {}
    end
  rescue JSON::ParserError
    {}
  end

  # Find scenes available for a specific character instance in a room
  def self.available_for(character_instance)
    where(
      pc_character_id: character_instance.character_id,
      meeting_room_id: character_instance.current_room_id,
      status: 'pending'
    ).all.select(&:available?)
  end

  # Find active scene for a character
  def self.active_for(character_instance)
    first(
      pc_character_id: character_instance.character_id,
      status: 'active'
    )
  end

  private

  def default_invitation_message
    npc_name = npc_character&.full_name || 'someone'
    room_name = meeting_room&.name || 'a location'
    "You have been invited to meet with #{npc_name} at #{room_name}."
  end
end
