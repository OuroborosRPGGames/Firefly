# frozen_string_literal: true

class Universe < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps
  
  one_to_many :worlds
  one_to_many :stat_blocks
  one_to_many :currencies
  one_to_many :channels
  one_to_many :abilities
  one_to_many :vehicle_types
  one_to_many :content_restrictions
  
  def validate
    super
    validates_presence [:name]
    validates_unique :name
    validates_max_length 100, :name
    validates_includes ['fantasy', 'sci-fi', 'modern', 'post-apocalyptic', 'steampunk', 'cyberpunk'], :theme
  end
  
  def active_worlds
    worlds_dataset.where(active: true)
  end

  def default_stat_block
    StatBlock.first(universe_id: id, is_default: true) || StatBlock.first(universe_id: id)
  end
end