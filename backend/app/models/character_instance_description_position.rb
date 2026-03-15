# frozen_string_literal: true

# Join table linking CharacterDescription (session) to multiple BodyPositions.
# This is the session copy of CharacterDescriptionPosition.
class CharacterInstanceDescriptionPosition < Sequel::Model
  plugin :timestamps
  plugin :validation_helpers

  many_to_one :character_description
  many_to_one :body_position

  def validate
    super
    validates_presence [:character_description_id, :body_position_id]
    validates_unique [:character_description_id, :body_position_id]
  end
end
