# frozen_string_literal: true

# ContentRestriction defines restricted content types for a universe.
# Game admins set these up; players choose which they consent to.
class ContentRestriction < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :universe
  one_to_many :content_consents

  def validate
    super
    validates_presence [:universe_id, :name, :code]
    validates_max_length 100, :name
    validates_max_length 20, :code
    validates_unique [:universe_id, :code]
  end

  def before_save
    super
    self.code = code.upcase if code
    self.requires_mutual_consent ||= true
  end

  def mutual?
    requires_mutual_consent
  end

  def consenting_characters
    content_consents_dataset.where(consented: true)
  end
end
