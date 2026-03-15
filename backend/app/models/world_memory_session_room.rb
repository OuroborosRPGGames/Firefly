# frozen_string_literal: true

# Tracks rooms visited during an active WorldMemorySession
class WorldMemorySessionRoom < Sequel::Model
  plugin :timestamps
  plugin :validation_helpers

  many_to_one :session, class: :WorldMemorySession
  many_to_one :room

  def validate
    super
    validates_presence [:session_id, :room_id]
  end
end
