# frozen_string_literal: true

class CharacterKnowledge < Sequel::Model(:character_knowledge)
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true
  
  many_to_one :knower_character, class: :Character, key: :knower_character_id
  many_to_one :known_character, class: :Character, key: :known_character_id
  
  def validate
    super
    validates_presence [:knower_character_id, :known_character_id]
    
    # Can't know yourself
    if knower_character_id == known_character_id
      errors.add(:base, "Character cannot have knowledge about themselves")
    end
  end
  
  def before_save
    super
    self.is_known ||= false
    self.first_met_at ||= Time.now
    self.last_seen_at ||= Time.now
  end
  
  # Update the last seen time
  def mark_seen!
    update(last_seen_at: Time.now)
  end
  
  # Mark character as known
  def mark_known!(name = nil)
    update(
      is_known: true, 
      known_name: name || known_character.full_name,
      last_seen_at: Time.now
    )
  end
  
  # Mark character as unknown (forgot them)
  def mark_unknown!
    update(is_known: false, known_name: nil)
  end
end