# frozen_string_literal: true

class Bulletin < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character

  def validate
    super
    validates_presence [:character_id, :body]
    validates_max_length 2000, :body
    validates_max_length 255, :from_text
  end

  def before_create
    super
    self.posted_at ||= Time.now
    self.from_text ||= character&.full_name
  end

  # Get recent bulletins (last 10 days, max 15)
  def self.recent
    where { posted_at > Time.now - (GameConfig::Content::BULLETIN_EXPIRATION_DAYS * 24 * 60 * 60) }
      .order(Sequel.desc(:posted_at))
      .limit(GameConfig::Content::BULLETIN_MAX_DISPLAY)
      .reverse  # Oldest first in display
  end

  # Delete all bulletins for a character
  def self.delete_for_character(character)
    where(character_id: character.id).delete
  end

  # Get bulletins by a specific character
  def self.by_character(character)
    where(character_id: character.id).order(Sequel.desc(:posted_at))
  end

  # Check if character already has a bulletin
  def self.exists_for_character?(character)
    where(character_id: character.id).any?
  end

  # Format bulletin for display
  def formatted_display
    "<fieldset><legend>#{from_text}</legend>#{body}</fieldset>"
  end

  # Check if bulletin is expired
  def expired?
    posted_at < Time.now - (GameConfig::Content::BULLETIN_EXPIRATION_DAYS * 24 * 60 * 60)
  end

  # Age in hours
  def age_hours
    ((Time.now - posted_at) / 3600).round
  end
end
