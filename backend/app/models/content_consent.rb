# frozen_string_literal: true

# ContentConsent tracks which restricted content types a character consents to.
class ContentConsent < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character
  many_to_one :content_restriction

  def validate
    super
    validates_presence [:character_id, :content_restriction_id]
    validates_unique [:character_id, :content_restriction_id]
  end

  def before_save
    super
    self.consented ||= false
  end

  def consent!
    update(consented: true, consented_at: Time.now)
  end

  def revoke!
    update(consented: false, consented_at: nil)
  end

  def consenting?
    consented == true
  end

  # Check if two characters both consent to a content type
  def self.mutual_consent?(char1, char2, restriction)
    where(content_restriction_id: restriction.id, consented: true)
      .where(character_id: [char1.id, char2.id])
      .count == 2
  end

  # Get all content types both characters consent to
  def self.shared_consents(char1, char2)
    char1_consents = where(character_id: char1.id, consented: true).select_map(:content_restriction_id)
    char2_consents = where(character_id: char2.id, consented: true).select_map(:content_restriction_id)
    ContentRestriction.where(id: char1_consents & char2_consents)
  end

  # Get all restriction codes a character consents to
  def self.consented_codes_for(character)
    where(character_id: character.id, consented: true)
      .eager(:content_restriction)
      .all
      .map { |cc| cc.content_restriction.code }
  end

  # Calculate intersection of consents for multiple characters
  # Returns array of content codes that ALL characters consent to
  def self.room_allowed_codes(character_ids)
    return [] if character_ids.empty?

    # Get each character's consented restriction IDs
    codes_per_char = character_ids.map do |char_id|
      where(character_id: char_id, consented: true)
        .select_map(:content_restriction_id)
    end

    # Intersection of all
    common_restriction_ids = codes_per_char.reduce(:&) || []

    ContentRestriction.where(id: common_restriction_ids, is_active: true)
                      .select_map(:code)
  end
end
