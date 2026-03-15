# frozen_string_literal: true

class ClueShare < Sequel::Model
  plugin :validation_helpers

  many_to_one :clue
  many_to_one :npc_character, class: :Character, key: :npc_character_id
  many_to_one :recipient_character, class: :Character, key: :recipient_character_id
  many_to_one :room

  def validate
    super
    validates_presence [:clue_id, :npc_character_id, :recipient_character_id]
  end

  # Human-readable summary
  def summary
    npc_name = npc_character&.full_name || 'Unknown NPC'
    recipient_name = recipient_character&.full_name || 'Unknown'
    clue_name = clue&.name || 'Unknown clue'
    time_str = shared_at&.strftime('%Y-%m-%d %H:%M') || 'Unknown time'

    "#{npc_name} shared '#{clue_name}' with #{recipient_name} at #{time_str}"
  end
end
