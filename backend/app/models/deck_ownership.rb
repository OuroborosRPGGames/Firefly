# frozen_string_literal: true

class DeckOwnership < Sequel::Model(:deck_ownership)
  plugin :validation_helpers

  # Associations
  many_to_one :deck_pattern
  many_to_one :character

  # Use composite primary key
  unrestrict_primary_key

  def validate
    super
    validates_presence [:deck_pattern_id, :character_id]
  end
end
