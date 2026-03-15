# frozen_string_literal: true

# Tracks characters participating in an active WorldMemorySession
class WorldMemorySessionCharacter < Sequel::Model
  plugin :timestamps
  plugin :validation_helpers

  many_to_one :session, class: :WorldMemorySession
  many_to_one :character

  def validate
    super
    validates_presence [:session_id, :character_id]
  end
end
