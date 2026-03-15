# frozen_string_literal: true

class ProfilePicture < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character

  def validate
    super
    validates_presence [:character_id, :url]
    validates_max_length 500, :url
    validates_max_length 200, :caption, allow_nil: true
  end
end
