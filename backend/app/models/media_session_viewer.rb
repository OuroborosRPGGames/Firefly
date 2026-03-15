# frozen_string_literal: true

# MediaSessionViewer tracks viewers connected to a media session.
# Used for late-joiner sync and viewer count display.
class MediaSessionViewer < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :media_session
  many_to_one :character_instance

  status_enum :connection_status, %w[pending connected disconnected]

  def validate
    super
    validates_presence :media_session_id
    validates_presence :character_instance_id
    validate_connection_status_enum
  end

  # === State Updates ===

  def mark_connected!
    update(connection_status: 'connected', last_seen: Time.now)
  end

  def mark_disconnected!
    update(connection_status: 'disconnected')
  end

  def touch!
    update(last_seen: Time.now)
  end

  # === API Response ===

  def to_hash
    {
      id: id,
      session_id: media_session_id,
      character_id: character_instance_id,
      character_name: character_instance&.character&.full_name,
      peer_id: peer_id,
      status: connection_status,
      joined_at: joined_at&.iso8601
    }
  end
end
