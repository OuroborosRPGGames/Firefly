# frozen_string_literal: true

class Reality < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps
  
  one_to_many :character_instances
  one_to_many :messages
  
  def validate
    super
    validates_presence [:name]
    validates_unique :name
    validates_max_length 100, :name
    validates_includes ['primary', 'flashback', 'alternate', 'dream', 'vision', 'memory'], :reality_type
    validates_integer :time_offset
  end
  
  def active_characters
    character_instances.where(online: true)
  end
  
  def self.primary
    first(reality_type: 'primary')
  end
  
  def is_primary?
    reality_type == 'primary'
  end
end