# frozen_string_literal: true

# WorldMemory stores searchable world memories from RP sessions.
# Memories have importance and timeliness weights for relevance ranking.
# Supports memory abstraction hierarchy like NpcMemory.
class WorldMemory < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  # Junction associations
  one_to_many :world_memory_characters
  one_to_many :world_memory_locations
  one_to_many :world_memory_npcs
  one_to_many :world_memory_lores

  # DAG abstraction links
  one_to_many :source_abstractions, class: :WorldMemoryAbstraction, key: :source_memory_id
  one_to_many :target_abstractions, class: :WorldMemoryAbstraction, key: :target_memory_id

  # Abstraction hierarchy (like NpcMemory)
  many_to_one :abstracted_into, class: :WorldMemory, key: :abstracted_into_id
  one_to_many :abstracted_from, class: :WorldMemory, key: :abstracted_into_id

  # Parent context chain
  many_to_one :parent_memory, class: :WorldMemory, key: :parent_memory_id
  one_to_many :child_memories, class: :WorldMemory, key: :parent_memory_id

  PUBLICITY_LEVELS = %w[private secluded semi_public public private_event public_event].freeze
  PRIVATE_PUBLICITY_LEVELS = %w[private private_event].freeze
  PUBLICITY_RESTRICTIVENESS = {
    'private' => 0,
    'private_event' => 0,
    'secluded' => 1,
    'semi_public' => 2,
    'public' => 3,
    'public_event' => 3
  }.freeze
  SOURCE_TYPES = %w[session event activity location_recap].freeze

  def validate
    super
    validates_presence [:summary, :started_at, :ended_at]
    validates_includes PUBLICITY_LEVELS, :publicity_level if publicity_level
    validates_includes SOURCE_TYPES, :source_type if source_type
  end

  def before_save
    super
    self.memory_at ||= ended_at || Time.now
    self.raw_log_expires_at ||= Time.now + (GameConfig::NpcMemory::RAW_LOG_RETENTION_MONTHS * 30 * 24 * 3600)
  end

  # ========================================
  # Relevance Scoring (matches NpcMemory pattern)
  # ========================================

  # Calculate relevance score combining importance and recency
  # @param query_time [Time] Reference time for age calculation
  # @return [Float] Score from 0.1 to 1.0
  def relevance_score(query_time: Time.now)
    importance_factor = (importance || 5) / 10.0
    age_days = (query_time - (memory_at || Time.now)).to_f / 86400
    timeliness_factor = [1.0 - (age_days / 365.0), 0.1].max
    (importance_factor * 0.6) + (timeliness_factor * 0.4)
  end

  def recent?(days: 7)
    memory_at && memory_at > Time.now - (days * 86400)
  end

  def important?
    (importance || 5) >= 7
  end

  # ========================================
  # Publicity Checks
  # ========================================

  def private?
    PRIVATE_PUBLICITY_LEVELS.include?(publicity_level)
  end

  def public?
    %w[public public_event].include?(publicity_level)
  end

  def searchable?
    !excluded_from_public && !private?
  end

  # ========================================
  # Abstraction Methods
  # ========================================

  def abstracted?
    !abstracted_into_id.nil?
  end

  def can_abstract?
    abstraction_level < GameConfig::NpcMemory::MAX_ABSTRACTION_LEVEL && !abstracted?
  end

  def raw_log_expired?
    raw_log_expires_at && Time.now > raw_log_expires_at
  end

  def purge_raw_log!
    update(raw_log: nil) if raw_log && raw_log_expired?
  end

  # ========================================
  # Character/Location Helpers
  # ========================================

  # Add a character link to this memory
  # @param character [Character]
  # @param role [String] participant, observer, or mentioned
  # @param message_count [Integer]
  def add_character!(character, role: 'participant', message_count: 0)
    existing = WorldMemoryCharacter.first(world_memory_id: id, character_id: character.id)
    if existing
      existing.update(
        message_count: [existing.message_count, message_count].max,
        last_seen_at: ended_at
      )
      existing
    else
      WorldMemoryCharacter.create(
        world_memory_id: id,
        character_id: character.id,
        role: role,
        message_count: message_count,
        first_seen_at: started_at,
        last_seen_at: ended_at
      )
    end
  end

  # Add a location link to this memory
  # @param room [Room]
  # @param is_primary [Boolean]
  # @param message_count [Integer]
  def add_location!(room, is_primary: false, message_count: 0)
    existing = WorldMemoryLocation.first(world_memory_id: id, room_id: room.id)
    if existing
      existing.update(
        message_count: [existing.message_count, message_count].max,
        last_seen_at: ended_at
      )
      existing
    else
      WorldMemoryLocation.create(
        world_memory_id: id,
        room_id: room.id,
        is_primary: is_primary,
        message_count: message_count,
        first_seen_at: started_at,
        last_seen_at: ended_at
      )
    end
  end

  # Get the primary room for this memory
  # @return [Room, nil]
  def primary_room
    loc = world_memory_locations_dataset.where(is_primary: true).first
    loc&.room
  end

  # Get all characters involved
  # @return [Array<Character>]
  def characters
    world_memory_characters.map(&:character).compact
  end

  # Get all rooms involved
  # @return [Array<Room>]
  def rooms
    world_memory_locations.map(&:room).compact
  end

  # Add an NPC link to this memory
  # @param character [Character]
  # @param role [String] involved, spawned, or mentioned
  def add_npc!(character, role: 'involved')
    return nil unless defined?(WorldMemoryNpc) && character

    existing = WorldMemoryNpc.first(world_memory_id: id, character_id: character.id)
    if existing
      existing.update(role: role) if role && role != existing.role
      existing
    else
      WorldMemoryNpc.create(
        world_memory_id: id,
        character_id: character.id,
        role: role
      )
    end
  end

  # Add a lore/helpfile link to this memory
  # @param helpfile [Helpfile]
  # @param reference_type [String] mentioned, central, or background
  def add_lore!(helpfile, reference_type: 'mentioned')
    return nil unless defined?(WorldMemoryLore) && helpfile

    existing = WorldMemoryLore.first(world_memory_id: id, helpfile_id: helpfile.id)
    if existing
      existing.update(reference_type: reference_type) if reference_type && reference_type != existing.reference_type
      existing
    else
      WorldMemoryLore.create(
        world_memory_id: id,
        helpfile_id: helpfile.id,
        reference_type: reference_type
      )
    end
  end

  # ========================================
  # Class Methods
  # ========================================

  class << self
    # Get unabstracted memories at a specific level
    def unabstracted_at_level(level)
      where(abstraction_level: level, abstracted_into_id: nil).order(:created_at)
    end

    # Check if abstraction is needed at a level
    def needs_abstraction?(level)
      unabstracted_at_level(level).count >= GameConfig::NpcMemory::ABSTRACTION_THRESHOLD
    end

    # Get memories with expired raw logs
    def expired_raw_logs
      where { raw_log_expires_at < Time.now }.exclude(raw_log: nil)
    end

    # Get memories involving a character
    # @param character [Character]
    # @param limit [Integer]
    def for_character(character, limit: 20)
      memory_ids = WorldMemoryCharacter.where(character_id: character.id).select(:world_memory_id)
      where(id: memory_ids)
        .where(excluded_from_public: false)
        .exclude(publicity_level: PRIVATE_PUBLICITY_LEVELS)
        .order(Sequel.desc(:memory_at))
        .limit(limit)
    end

    # Get memories at a specific room
    # @param room [Room]
    # @param limit [Integer]
    def for_room(room, limit: 20)
      memory_ids = WorldMemoryLocation.where(room_id: room.id).select(:world_memory_id)
      where(id: memory_ids)
        .where(excluded_from_public: false)
        .exclude(publicity_level: PRIVATE_PUBLICITY_LEVELS)
        .order(Sequel.desc(:memory_at))
        .limit(limit)
    end

    # Get publicly searchable memories
    def searchable
      where(excluded_from_public: false)
        .exclude(publicity_level: PRIVATE_PUBLICITY_LEVELS)
    end

    # Restrictiveness score for publicity level (lower is more restrictive)
    # @param level [String, nil]
    # @return [Integer]
    def restrictiveness_for(level)
      PUBLICITY_RESTRICTIVENESS[level.to_s] || PUBLICITY_RESTRICTIVENESS['public']
    end

    # Pick the most restrictive publicity level between two values
    # @param level_a [String, nil]
    # @param level_b [String, nil]
    # @return [String]
    def more_restrictive_publicity(level_a, level_b)
      return level_b if level_a.nil?
      return level_a if level_b.nil?

      restrictiveness_for(level_a) <= restrictiveness_for(level_b) ? level_a : level_b
    end

    # Get recent memories
    # @param days [Integer]
    def recent(days: 30)
      where { memory_at > Time.now - (days * 86400) }
    end

    # Get memories for a location (all rooms in the location)
    # Useful for Auto-GM context gathering
    # @param location [Location]
    # @param limit [Integer]
    # @param days [Integer] how far back to look
    # @return [Dataset]
    def for_location(location, limit: 20, days: 30)
      room_ids = location.rooms.map(&:id)
      memory_ids = WorldMemoryLocation.where(room_id: room_ids).select(:world_memory_id)
      where(id: memory_ids)
        .where(excluded_from_public: false)
        .exclude(publicity_level: PRIVATE_PUBLICITY_LEVELS)
        .where { memory_at > Time.now - (days * 86400) }
        .order(Sequel.desc(:importance), Sequel.desc(:memory_at))
        .limit(limit)
    end

    # Get memories from multiple rooms (for Auto-GM nearby location search)
    # @param room_ids [Array<Integer>]
    # @param limit [Integer]
    # @param days [Integer]
    # @return [Dataset]
    def for_rooms(room_ids, limit: 20, days: 30)
      return where(id: nil) if room_ids.empty?

      memory_ids = WorldMemoryLocation.where(room_id: room_ids).select(:world_memory_id)
      where(id: memory_ids)
        .where(excluded_from_public: false)
        .exclude(publicity_level: PRIVATE_PUBLICITY_LEVELS)
        .where { memory_at > Time.now - (days * 86400) }
        .order(Sequel.desc(:importance), Sequel.desc(:memory_at))
        .limit(limit)
    end

    # Get memories involving any of the given characters
    # @param characters [Array<Character>]
    # @param limit [Integer]
    # @return [Dataset]
    def for_characters(characters, limit: 20)
      character_ids = characters.map(&:id)
      return where(id: nil) if character_ids.empty?

      memory_ids = WorldMemoryCharacter.where(character_id: character_ids).select(:world_memory_id)
      where(id: memory_ids)
        .where(excluded_from_public: false)
        .exclude(publicity_level: PRIVATE_PUBLICITY_LEVELS)
        .order(Sequel.desc(:importance), Sequel.desc(:memory_at))
        .limit(limit)
    end
  end
end
