# frozen_string_literal: true

class Trigger < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :activity
  many_to_one :npc_character, class: :Character, key: :npc_character_id
  many_to_one :created_by, class: :User, key: :created_by_user_id
  many_to_one :arranged_scene
  one_to_many :trigger_activations

  TRIGGER_TYPES = %w[mission npc world_memory clue_share].freeze
  CONDITION_TYPES = %w[exact contains llm_match regex].freeze
  MISSION_EVENTS = %w[succeed fail branch round_complete].freeze
  ACTION_TYPES = %w[code_block staff_alert both].freeze

  def validate
    super
    validates_presence [:name, :trigger_type, :condition_type, :action_type]
    validates_includes TRIGGER_TYPES, :trigger_type
    validates_includes CONDITION_TYPES, :condition_type
    validates_includes ACTION_TYPES, :action_type
    validates_includes MISSION_EVENTS, :mission_event_type, allow_nil: true
  end

  def mission_trigger?
    trigger_type == 'mission'
  end

  def npc_trigger?
    trigger_type == 'npc'
  end

  def world_memory_trigger?
    trigger_type == 'world_memory'
  end

  def clue_share_trigger?
    trigger_type == 'clue_share'
  end

  def requires_llm_match?
    condition_type == 'llm_match'
  end

  def should_execute_code?
    %w[code_block both].include?(action_type)
  end

  def should_alert_staff?
    %w[staff_alert both].include?(action_type)
  end

  # Get activation count
  def activation_count
    trigger_activations_dataset.count
  end

  # Get recent activations
  def recent_activations(limit: 10)
    trigger_activations_dataset.order(Sequel.desc(:activated_at)).limit(limit).all
  end

  # Check if this trigger applies to a specific NPC
  def applies_to_npc?(character)
    return false unless npc_trigger?

    # Specific NPC match
    return true if npc_character_id == character.id

    # Archetype match (if no specific NPC)
    return false if npc_character_id

    archetype_ids = self.npc_archetype_ids || []
    return true if archetype_ids.empty?  # No filter = all NPCs

    archetype_ids.include?(character.npc_archetype_id)
  end
end
