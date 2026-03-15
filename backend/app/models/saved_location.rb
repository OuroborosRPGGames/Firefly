# frozen_string_literal: true

class SavedLocation < Sequel::Model
  plugin :validation_helpers

  many_to_one :character
  many_to_one :room

  # Database column is 'name', alias for backward compatibility
  def location_name
    name
  end

  def location_name=(val)
    self.name = val
  end

  def validate
    super
    validates_presence [:character_id, :room_id, :name]
    validates_max_length 100, :name
    validates_unique [:character_id, :name], message: 'already exists'
  end

  # Find by name (case-insensitive)
  def self.find_by_name(character, find_name)
    first(character_id: character.id) { Sequel.ilike(:name, find_name) }
  end

  # Get all saved locations for a character
  def self.for_character(character)
    where(character_id: character.id).order(:name)
  end

  # Get the room path for display
  def location_path
    room&.full_path
  end
end
