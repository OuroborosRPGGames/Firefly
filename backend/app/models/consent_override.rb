# frozen_string_literal: true

# ConsentOverride tracks per-player consent exceptions.
# Allows "I'm okay with X content specifically when RPing with Character Y"
class ConsentOverride < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character
  many_to_one :target_character, class: :Character
  many_to_one :content_restriction

  def validate
    super
    validates_presence [:character_id, :target_character_id, :content_restriction_id]
    validates_unique [:character_id, :target_character_id, :content_restriction_id]

    if character_id == target_character_id
      errors.add(:target_character_id, 'cannot be the same as character_id')
    end
  end

  def before_save
    super
    self.granted_at ||= Time.now if allowed
  end

  def allowed?
    allowed == true && revoked_at.nil?
  end

  def revoke!
    update(allowed: false, revoked_at: Time.now)
  end

  def grant!
    update(allowed: true, granted_at: Time.now, revoked_at: nil)
  end

  class << self
    # Check if char1 has an override allowing content with char2
    def has_override?(char1, char2, restriction)
      override = first(
        character_id: char1.id,
        target_character_id: char2.id,
        content_restriction_id: restriction.id
      )
      override&.allowed?
    end

    # Check mutual override (both parties allow)
    def mutual_override?(char1, char2, restriction)
      has_override?(char1, char2, restriction) &&
        has_override?(char2, char1, restriction)
    end

    # Get all restrictions char1 has overrides for with char2
    def overrides_between(char1, char2)
      where(character_id: char1.id, target_character_id: char2.id, allowed: true)
        .where(revoked_at: nil)
        .eager(:content_restriction)
        .all
    end

    # Find or create an override record
    def find_or_create_between(char1, char2, restriction)
      first(
        character_id: char1.id,
        target_character_id: char2.id,
        content_restriction_id: restriction.id
      ) || create(
        character_id: char1.id,
        target_character_id: char2.id,
        content_restriction_id: restriction.id,
        allowed: false
      )
    end
  end
end
