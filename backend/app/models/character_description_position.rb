# frozen_string_literal: true

# Join table linking CharacterDefaultDescription to multiple BodyPositions.
# Allows descriptions (especially tattoos) to span multiple body positions.
class CharacterDescriptionPosition < Sequel::Model
  plugin :timestamps
  plugin :validation_helpers

  many_to_one :character_default_description
  many_to_one :body_position

  def validate
    super
    validates_presence [:character_default_description_id, :body_position_id]
    validates_unique [:character_default_description_id, :body_position_id]
  end
end
