# frozen_string_literal: true

# HasNumber tracks phone number exchanges between characters.
# When character A gives their number to character B, B can then
# contact A via phone/messaging.
class HasNumber < Sequel::Model(:has_number)
  plugin :timestamps, create: :created_at, update: false

  many_to_one :character, class: :Character
  many_to_one :target, class: :Character

  # Check if two characters have exchanged numbers (either direction)
  def self.shared?(char1, char2)
    where(character_id: char1.id, target_id: char2.id).any? ||
      where(character_id: char2.id, target_id: char1.id).any?
  end

  # Check if target has the sender's number
  def self.has_number?(target, sender)
    where(character_id: target.id, target_id: sender.id).any?
  end

  # Give number from sender to target (target now has sender's number)
  def self.give_number!(from_character, to_character)
    return false if has_number?(to_character, from_character)

    create(
      character_id: to_character.id,
      target_id: from_character.id
    )
    true
  end

  # Get all characters whose number this character has
  def self.contacts_for(character)
    where(character_id: character.id).map(&:target)
  end

  # Get all characters who have this character's number
  def self.who_has_number(character)
    where(target_id: character.id).map(&:character)
  end
end
