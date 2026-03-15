# frozen_string_literal: true

# EmoteTurnService - Tracks emote/pose turn order per room
#
# Uses Redis to track when each character last emoted in a room.
# After each IC message, determines whose turn is next (round-robin)
# and broadcasts a turn_update WebSocket message.
#
# AFK and offline characters are skipped. NPCs are excluded.
# Rooms with fewer than 2 active players skip turn tracking.
module EmoteTurnService
  TURN_KEY_PREFIX = 'emote_turns:room:'
  TURN_TTL = 3600 # Expire after 1 hour of inactivity

  class << self
    # Record that a character emoted in a room
    def record_emote(room_id, character_instance_id)
      key = "#{TURN_KEY_PREFIX}#{room_id}"
      REDIS_POOL.with do |redis|
        redis.hset(key, character_instance_id.to_s, Time.now.to_f.to_s)
        redis.expire(key, TURN_TTL)
      end
    rescue StandardError => e
      warn "[EmoteTurnService] Failed to record emote: #{e.message}"
    end

    # Determine which character should go next (longest since last emote)
    def next_turn(room_id)
      # Get active, non-AFK, non-NPC player characters in room
      active_ids = CharacterInstance
        .where(current_room_id: room_id, online: true)
        .exclude(afk: true)
        .all
        .reject { |ci| ci.character&.is_npc }
        .map(&:id)

      return nil if active_ids.size < 2

      # Get last emote timestamps from Redis
      key = "#{TURN_KEY_PREFIX}#{room_id}"
      timestamps = {}
      REDIS_POOL.with { |redis| timestamps = redis.hgetall(key) }

      # Next turn = active character who emoted longest ago (or never)
      active_ids.min_by { |id| (timestamps[id.to_s] || '0').to_f }
    rescue StandardError => e
      warn "[EmoteTurnService] Failed to determine next turn: #{e.message}"
      nil
    end

    # Broadcast turn update to all characters in room via Redis pub/sub
    def broadcast_turn(room_id)
      next_id = next_turn(room_id)
      return unless next_id

      payload = { type: :turn_update, message: { turn_instance_id: next_id }, timestamp: Time.now.iso8601 }
      REDIS_POOL.with do |redis|
        redis.publish("room:#{room_id}", payload.to_json)
      end
    rescue StandardError => e
      warn "[EmoteTurnService] Failed to broadcast turn: #{e.message}"
    end

    # Clear turn tracking for a room (e.g., when scene ends)
    def clear_room(room_id)
      REDIS_POOL.with { |redis| redis.del("#{TURN_KEY_PREFIX}#{room_id}") }
    rescue StandardError => e
      warn "[EmoteTurnService] Failed to clear room: #{e.message}"
    end
  end
end
