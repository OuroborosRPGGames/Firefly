# frozen_string_literal: true

class ProfileSetting < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character

  def validate
    super
    validates_presence :character_id
    validates_unique :character_id
    validates_max_length 500, :background_url, allow_nil: true
  end
end
