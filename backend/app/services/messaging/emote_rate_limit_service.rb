# frozen_string_literal: true

# EmoteRateLimitService handles rate limiting for emotes in crowded rooms.
#
# Threshold: Rate limiting activates when room has >8 online characters
# Limit: 3 emotes per 60 seconds per character
# Storage: Redis TTL keys
#
# Exemptions (never rate limited):
# - Subtle emotes (handled separately, not through this service)
# - Characters with spotlight (event_camera == true)
# - Event organizers
# - Event hosts/staff
class EmoteRateLimitService
  REDIS_KEY_PREFIX = 'emote_rate_limit'

  class << self
    # Check if a character can emote in their current location
    #
    # @param character_instance [CharacterInstance] the character trying to emote
    # @param room [Room] the room they're in (optional, defaults to current_room)
    # @return [Hash] { allowed: Boolean, message: String (if blocked), remaining: Integer }
    def check(character_instance, room = nil)
      room ||= character_instance.current_room
      return allowed_result(GameConfig::Moderation::EMOTE_RATE_LIMIT[:emote_limit]) unless room

      # Check if rate limiting applies to this room
      unless rate_limiting_active?(room, character_instance.reality_id, character_instance.in_event_id)
        return allowed_result(GameConfig::Moderation::EMOTE_RATE_LIMIT[:emote_limit])
      end

      # Check exemptions
      if character_instance.exempt_from_emote_rate_limit?
        return allowed_result(GameConfig::Moderation::EMOTE_RATE_LIMIT[:emote_limit], exempt: true)
      end

      # Check rate limit
      current_count = get_emote_count(character_instance.id)
      remaining = GameConfig::Moderation::EMOTE_RATE_LIMIT[:emote_limit] - current_count

      if remaining <= 0
        ttl = get_ttl(character_instance.id)
        {
          allowed: false,
          message: "This room is crowded. Please wait #{ttl} seconds before emoting again.",
          remaining: 0,
          seconds_until_reset: ttl
        }
      else
        allowed_result(remaining)
      end
    end

    # Record an emote for rate limiting purposes
    #
    # @param character_instance_id [Integer] the character instance ID
    # @return [Integer] new emote count for this window
    def record_emote(character_instance_id)
      key = redis_key(character_instance_id)

      REDIS_POOL.with do |redis|
        count = redis.incr(key)
        # Set expiry only on first emote in window
        redis.expire(key, GameConfig::Moderation::EMOTE_RATE_LIMIT[:window_seconds]) if count == 1
        count
      end
    end

    # Check if rate limiting is active for a room
    #
    # @param room [Room] the room to check
    # @param reality_id [Integer] the reality to count characters in
    # @return [Boolean]
    def rate_limiting_active?(room, reality_id = nil, in_event_id = nil)
      count = online_character_count(room, reality_id, in_event_id)
      count > GameConfig::Moderation::EMOTE_RATE_LIMIT[:room_threshold]
    end

    # Get the number of online characters in a room
    #
    # @param room [Room] the room
    # @param reality_id [Integer, nil] optional reality filter
    # @return [Integer]
    def online_character_count(room, reality_id = nil, in_event_id = nil)
      query = CharacterInstance.where(current_room_id: room.id, online: true)
      query = query.where(reality_id: reality_id) if reality_id
      query = query.where(in_event_id: in_event_id)
      query.count
    end

    # Get current emote count for a character
    #
    # @param character_instance_id [Integer]
    # @return [Integer]
    def get_emote_count(character_instance_id)
      key = redis_key(character_instance_id)

      REDIS_POOL.with do |redis|
        redis.get(key).to_i
      end
    end

    # Get TTL for a character's rate limit key
    #
    # @param character_instance_id [Integer]
    # @return [Integer] seconds until reset, or GameConfig::Moderation::EMOTE_RATE_LIMIT[:window_seconds] if no key
    def get_ttl(character_instance_id)
      key = redis_key(character_instance_id)

      REDIS_POOL.with do |redis|
        ttl = redis.ttl(key)
        ttl > 0 ? ttl : GameConfig::Moderation::EMOTE_RATE_LIMIT[:window_seconds]
      end
    end

    # Clear rate limit for a character (for testing or admin use)
    #
    # @param character_instance_id [Integer]
    def clear(character_instance_id)
      key = redis_key(character_instance_id)

      REDIS_POOL.with do |redis|
        redis.del(key)
      end
    end

    private

    def redis_key(character_instance_id)
      "#{REDIS_KEY_PREFIX}:#{character_instance_id}"
    end

    def allowed_result(remaining, exempt: false)
      {
        allowed: true,
        remaining: remaining,
        exempt: exempt
      }
    end
  end
end
