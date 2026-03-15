# frozen_string_literal: true

class ProfileVideo < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  YOUTUBE_ID_REGEX = /\A[a-zA-Z0-9_-]{11}\z/

  many_to_one :character

  def validate
    super
    validates_presence [:character_id, :youtube_id]
    validates_format YOUTUBE_ID_REGEX, :youtube_id, message: 'must be a valid YouTube video ID'
    validates_max_length 200, :title, allow_nil: true
  end
end
