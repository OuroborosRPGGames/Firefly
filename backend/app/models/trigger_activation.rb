# frozen_string_literal: true

class TriggerActivation < Sequel::Model
  plugin :validation_helpers

  many_to_one :trigger
  many_to_one :source_character, class: :Character, key: :source_character_id
  many_to_one :source_instance, class: :CharacterInstance, key: :source_instance_id
  many_to_one :clue
  many_to_one :clue_recipient, class: :Character, key: :clue_recipient_id

  SOURCE_TYPES = %w[character npc system].freeze

  def validate
    super
    validates_presence [:trigger_id, :source_type]
    validates_includes SOURCE_TYPES, :source_type
  end

  # Human-readable summary for admin view
  def summary
    parts = ["Trigger '#{trigger&.name || 'Unknown'}' activated"]
    parts << "by #{source_type}: #{source_character&.full_name || 'system'}"
    parts << "at #{activated_at&.strftime('%Y-%m-%d %H:%M:%S') || 'unknown time'}"
    parts.join(' ')
  end

  # Get context value by key
  def context_value(key)
    (context_data || {})[key.to_s]
  end

  # Check if this was a successful execution
  def successful?
    action_executed && action_success
  end

  # Check if this was an LLM-matched trigger
  def llm_matched?
    !llm_confidence.nil?
  end

  # Format confidence as percentage
  def confidence_percentage
    return nil unless llm_confidence
    "#{(llm_confidence * 100).round(1)}%"
  end
end
