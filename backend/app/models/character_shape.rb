# frozen_string_literal: true

class CharacterShape < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps
  plugin :dirty

  many_to_one :character
  one_to_many :character_instances, key: :current_shape_id
  one_to_many :appearances
  
  def validate
    super
    # Set defaults before validation
    self.shape_type ||= 'humanoid'
    self.size ||= 'medium'
    
    validates_presence [:shape_name, :character_id]
    validates_unique [:character_id, :shape_name]
    validates_max_length 50, :shape_name
    validates_includes ['humanoid', 'animal', 'elemental', 'construct', 'undead', 'plant'], :shape_type
    validates_includes ['tiny', 'small', 'medium', 'large', 'huge', 'gargantuan'], :size
  end
  
  def before_save
    super
    # Ensure only one default shape per character
    if is_default_shape && (new? || column_changed?(:is_default_shape))
      CharacterShape.where(character_id: character_id).exclude(id: id).update(is_default_shape: false)
    end
  end
  
  def after_create
    super
    # If this is the first shape for the character, make it default
    if CharacterShape.where(character_id: character_id).count == 1
      update(is_default_shape: true)
    end
  end
end