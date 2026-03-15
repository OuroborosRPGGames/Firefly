# frozen_string_literal: true

class DescriptionType < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps
  
  one_to_many :character_descriptions
  one_to_many :description_type_body_positions
  
  def validate
    super
    validates_presence [:name]
    validates_unique :name
    validates_max_length 50, :name
    validates_includes ['text', 'image_url', 'audio_url'], :content_type
    validates_integer :display_order, minimum: 0
  end
end