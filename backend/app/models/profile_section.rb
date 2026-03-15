# frozen_string_literal: true

class ProfileSection < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :character

  def validate
    super
    validates_presence [:character_id, :content]
    validates_max_length 200, :title, allow_nil: true
    validates_max_length 10_000, :content
  end
end
