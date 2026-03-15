# frozen_string_literal: true

class Message < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true
  
  many_to_one :character  # Keep for backward compatibility
  many_to_one :character_instance
  many_to_one :reality
  many_to_one :room
  many_to_one :target_character_instance, class: :CharacterInstance
  
  def validate
    super
    validates_presence [:content, :reality_id]
    validates_min_length 1, :content
    validates_max_length 1000, :content
    validates_includes ['say', 'say_to', 'tell', 'emote', 'subtle', 'system', 'ooc', 'broadcast', 'whisper', 'private_emote', 'roll'], :message_type
    
    # Either character_id or character_instance_id should be present (unless system message)
    if !character_id && !character_instance_id && message_type != 'system'
      errors.add(:base, "Must have either character_id or character_instance_id for non-system messages")
    end
  end
  
  def before_save
    super
    self.content = self.content.strip if self.content
    self.message_type ||= 'say'
    
    # Maintain backward compatibility - if we have character_instance but no character_id
    if character_instance_id && !character_id
      self.character_id = character_instance.character_id
    end
  end
  
  def sender_name
    if character_instance
      character_instance.full_name
    elsif character
      character.full_name
    else
      "System"
    end
  end
  
  def is_targeted?
    %w[tell whisper say_to private_emote].include?(message_type) && target_character_instance_id
  end
  
  def is_system?
    message_type == 'system'
  end
  
  def self.for_room(room_id, reality_id, limit = 50)
    where(room_id: room_id, reality_id: reality_id)
      .order(Sequel.desc(:created_at))
      .limit(limit)
      .reverse
  end
  
  def self.recent_for_character(character_instance_id, limit = 50)
    where(
      Sequel.|({character_instance_id: character_instance_id}, 
               {target_character_instance_id: character_instance_id})
    )
    .order(Sequel.desc(:created_at))
    .limit(limit)
    .reverse
  end
end