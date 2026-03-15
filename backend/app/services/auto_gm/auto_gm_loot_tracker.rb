# frozen_string_literal: true

module AutoGm
  # Tracks loot given to characters with hourly caps.
  # Uses Redis for fast tracking with automatic expiration.
  #
  # @example
  #   AutoGm::LootTracker.remaining_allowance(character) # => 450
  #   AutoGm::LootTracker.record_loot(character, 100)    # => true
  #   AutoGm::LootTracker.remaining_allowance(character) # => 350
  #
  class LootTracker
    REDIS_KEY_PREFIX = 'autogm:loot:hourly:'
    WINDOW_SECONDS = 3600 # 1 hour

    class << self
      # Get remaining loot allowance for this hour
      # @param character [Character]
      # @return [Integer] remaining allowance
      def remaining_allowance(character)
        max = GameConfig::AutoGm::LOOT[:max_per_hour]
        used = loot_given_this_hour(character)
        [max - used, 0].max
      end

      # Record loot given to a character
      # @param character [Character]
      # @param amount [Integer]
      # @return [Boolean] success
      def record_loot(character, amount)
        key = redis_key(character)
        current = loot_given_this_hour(character)
        new_total = current + amount

        with_redis { |r| r.setex(key, WINDOW_SECONDS, new_total.to_s) }
        true
      rescue StandardError => e
        warn "[LootTracker] Failed to record loot: #{e.message}"
        false
      end

      # Get total loot given this hour
      # @param character [Character]
      # @return [Integer]
      def loot_given_this_hour(character)
        with_redis { |r| r.get(redis_key(character)) }.to_i
      rescue StandardError => e
        warn "[AutoGMLootTracker] Error getting loot for character #{character&.id}: #{e.message}"
        0
      end

      # Check if character can receive loot
      # @param character [Character]
      # @param amount [Integer]
      # @return [Boolean]
      def can_receive?(character, amount)
        remaining_allowance(character) >= amount
      end

      private

      def redis_key(character)
        "#{REDIS_KEY_PREFIX}#{character.id}"
      end

      def with_redis(&block)
        if defined?(REDIS_POOL)
          REDIS_POOL.with(&block)
        else
          warn "[LootTracker] REDIS_POOL not defined, falling back to direct connection"
          Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379')).then(&block)
        end
      end
    end
  end
end
