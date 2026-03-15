# frozen_string_literal: true

# NpcMemory stores AI NPC memories for RAG retrieval.
# Memories have importance and timeliness weights for relevance ranking.
# Supports memory abstraction hierarchy: Level 1 = raw, Level 4 = most abstract.
class NpcMemory < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character  # The NPC
  many_to_one :about_character, class: :Character  # Who/what the memory is about
  many_to_one :location

  # Abstraction hierarchy
  many_to_one :abstracted_into, class: :NpcMemory, key: :abstracted_into_id
  one_to_many :abstracted_from, class: :NpcMemory, key: :abstracted_into_id

  MEMORY_TYPES = %w[interaction observation event secret goal emotion abstraction reflection].freeze
  ABSTRACTION_THRESHOLD = GameConfig::NpcMemory::ABSTRACTION_THRESHOLD
  MAX_ABSTRACTION_LEVEL = GameConfig::NpcMemory::MAX_ABSTRACTION_LEVEL

  def validate
    super
    validates_presence [:character_id, :content, :memory_type]
    validates_includes MEMORY_TYPES, :memory_type
  end

  def before_save
    super
    self.importance ||= 5  # 1-10 scale
    self.abstraction_level ||= 1
    self.created_at ||= Time.now
    self.memory_at ||= Time.now
  end

  # Calculate relevance score for RAG retrieval
  def relevance_score(query_time: Time.now)
    # Importance contributes directly
    importance_factor = importance / 10.0

    # Timeliness decays over time (older = less relevant)
    age_days = (query_time - memory_at).to_f / 86400
    timeliness_factor = [1.0 - (age_days / 365.0), 0.1].max

    # Combine factors
    (importance_factor * 0.6) + (timeliness_factor * 0.4)
  end

  def about?(character)
    about_character_id == character.id
  end

  def recent?(days: 7)
    memory_at > Time.now - (days * 86400)
  end

  def important?
    importance >= 7
  end

  def secret?
    memory_type == 'secret'
  end

  # Retrieve relevant memories for an NPC about a topic/character
  def self.relevant_for(npc, about: nil, location: nil, limit: 10)
    query = where(character_id: npc.id)
    query = query.where(about_character_id: about.id) if about
    query = query.where(location_id: location.id) if location
    query.order(Sequel.desc(:importance), Sequel.desc(:memory_at)).limit(limit)
  end

  # Summarize interactions into a memory
  def self.create_from_interaction(npc, other_character, summary, importance: 5)
    create(
      character_id: npc.id,
      about_character_id: other_character.id,
      content: summary,
      memory_type: 'interaction',
      importance: importance
    )
  end

  # ============================================
  # Abstraction Hierarchy Methods
  # ============================================

  def abstracted?
    !abstracted_into_id.nil?
  end

  def abstraction?
    memory_type == 'abstraction'
  end

  def raw_memory?
    abstraction_level == 1
  end

  def can_abstract?
    abstraction_level < MAX_ABSTRACTION_LEVEL && !abstracted?
  end

  # Get unabstracted memories at a specific level for an NPC
  def self.unabstracted_at_level(npc_id, level)
    where(
      character_id: npc_id,
      abstraction_level: level,
      abstracted_into_id: nil
    ).order(:created_at)
  end

  # Count unabstracted memories at a level
  def self.unabstracted_count_at_level(npc_id, level)
    unabstracted_at_level(npc_id, level).count
  end

  # Check if abstraction is needed at a level
  def self.needs_abstraction?(npc_id, level)
    unabstracted_count_at_level(npc_id, level) >= ABSTRACTION_THRESHOLD
  end
end
