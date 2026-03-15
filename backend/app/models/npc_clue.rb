# frozen_string_literal: true

class NpcClue < Sequel::Model
  plugin :validation_helpers

  many_to_one :character
  many_to_one :clue

  def validate
    super
    validates_presence [:character_id, :clue_id]
    validates_unique [:character_id, :clue_id]
  end

  # Get effective share likelihood (override or clue default)
  def effective_share_likelihood
    share_likelihood_override || clue&.share_likelihood || 0.5
  end

  # Get effective minimum trust (override or clue default)
  def effective_min_trust
    min_trust_override || clue&.min_trust_required || 0.0
  end
end
