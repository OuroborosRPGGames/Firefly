# frozen_string_literal: true

module LLM
  # ProviderThrottle manages per-provider concurrency limits with auto-backoff.
  #
  # All state is in Redis for thread safety and potential multi-process sharing.
  #
  # Usage:
  #   LLM::ProviderThrottle.acquire_slot('google_gemini')  # blocks until slot available
  #   # ... make API call ...
  #   LLM::ProviderThrottle.release_slot('google_gemini')
  #
  #   LLM::ProviderThrottle.record_rate_limit('google_gemini')  # on 429
  #   LLM::ProviderThrottle.record_success('google_gemini')     # on success
  #
  class ProviderThrottle
    REDIS_PREFIX = 'llm:slots'

    class << self
      # Acquire a concurrency slot. Blocks until available or timeout.
      # @param provider [String] provider name
      # @param timeout [Integer] max seconds to wait (default 120)
      # @return [Boolean] true if acquired, false if timed out
      def acquire_slot(provider, timeout: 120)
        deadline = Time.now + timeout

        loop do
          return false if Time.now > deadline

          # Check backoff
          backoff_until = backoff_until(provider)
          if backoff_until && Time.now.to_f < backoff_until
            sleep [backoff_until - Time.now.to_f, 0.1].max.clamp(0.1, 5.0)
            next
          end

          # Try to acquire
          current = current_slots(provider)
          limit = current_limit(provider)

          if current < limit
            new_count = REDIS_POOL.with { |redis| redis.incr("#{REDIS_PREFIX}:#{provider}") }
            if new_count > limit
              REDIS_POOL.with { |redis| redis.decr("#{REDIS_PREFIX}:#{provider}") }
              sleep 0.1
              next
            end
            return true
          end

          sleep 0.2
        end
      end

      # Try to acquire a slot without blocking. Returns immediately.
      # Preferred for Sidekiq jobs — re-schedule instead of tying up a thread.
      # @param provider [String]
      # @return [Boolean] true if acquired, false if at limit or in backoff
      def try_acquire_slot(provider)
        # Check backoff
        backoff_until = backoff_until(provider)
        return false if backoff_until && Time.now.to_f < backoff_until

        limit = current_limit(provider)
        new_count = REDIS_POOL.with { |redis| redis.incr("#{REDIS_PREFIX}:#{provider}") }
        if new_count > limit
          REDIS_POOL.with { |redis| redis.decr("#{REDIS_PREFIX}:#{provider}") }
          return false
        end
        true
      end

      # Release a concurrency slot.
      # @param provider [String]
      def release_slot(provider)
        REDIS_POOL.with do |redis|
          count = redis.decr("#{REDIS_PREFIX}:#{provider}")
          redis.set("#{REDIS_PREFIX}:#{provider}", 0) if count < 0
        end
      end

      # Record a 429 rate limit. Reduces limit and sets backoff.
      # @param provider [String]
      def record_rate_limit(provider)
        REDIS_POOL.with do |redis|
          config = GameConfig::LLM::BACKOFF

          stored = redis.get("#{REDIS_PREFIX}:#{provider}:limit")
          current = stored ? stored.to_i : (GameConfig::LLM::CONCURRENCY_LIMITS[provider.to_sym] || 50)
          new_limit = [(current * config[:reduce_factor]).to_i, 1].max
          redis.set("#{REDIS_PREFIX}:#{provider}:limit", new_limit)

          consecutive = redis.incr("#{REDIS_PREFIX}:#{provider}:consecutive_429s")
          delay = [
            config[:initial_backoff_seconds] * (config[:backoff_multiplier]**(consecutive - 1)),
            config[:max_backoff_seconds]
          ].min
          redis.set("#{REDIS_PREFIX}:#{provider}:backoff_until", (Time.now.to_f + delay).to_s)

          redis.set("#{REDIS_PREFIX}:#{provider}:success_streak", 0)

          warn "[LLM::ProviderThrottle] #{provider} rate limited — limit #{current}->#{new_limit}, backoff #{delay}s"
        end
      end

      # Record a successful API call. Clears backoff, gradually recovers limit.
      # @param provider [String]
      def record_success(provider)
        REDIS_POOL.with do |redis|
          config = GameConfig::LLM::BACKOFF

          redis.set("#{REDIS_PREFIX}:#{provider}:consecutive_429s", 0)
          redis.del("#{REDIS_PREFIX}:#{provider}:backoff_until")

          streak = redis.incr("#{REDIS_PREFIX}:#{provider}:success_streak")

          if streak >= config[:recovery_streak]
            max_limit = GameConfig::LLM::CONCURRENCY_LIMITS[provider.to_sym] || 50
            stored = redis.get("#{REDIS_PREFIX}:#{provider}:limit")
            current = stored ? stored.to_i : max_limit
            if current < max_limit
              new_limit = [(current * config[:recovery_factor]).to_i, max_limit].min
              redis.set("#{REDIS_PREFIX}:#{provider}:limit", new_limit)
              redis.set("#{REDIS_PREFIX}:#{provider}:success_streak", 0)
            end
          end
        end
      end

      # Current in-flight count.
      # @param provider [String]
      # @return [Integer]
      def current_slots(provider)
        REDIS_POOL.with { |redis| redis.get("#{REDIS_PREFIX}:#{provider}").to_i }
      end

      # Current concurrency limit (may be reduced from max).
      # @param provider [String]
      # @return [Integer]
      def current_limit(provider)
        REDIS_POOL.with do |redis|
          stored = redis.get("#{REDIS_PREFIX}:#{provider}:limit")
          stored ? stored.to_i : (GameConfig::LLM::CONCURRENCY_LIMITS[provider.to_sym] || 50)
        end
      end

      # Reset all throttle state for a provider.
      # @param provider [String]
      def reset!(provider)
        REDIS_POOL.with do |redis|
          redis.del(
            "#{REDIS_PREFIX}:#{provider}",
            "#{REDIS_PREFIX}:#{provider}:limit",
            "#{REDIS_PREFIX}:#{provider}:backoff_until",
            "#{REDIS_PREFIX}:#{provider}:consecutive_429s",
            "#{REDIS_PREFIX}:#{provider}:success_streak"
          )
        end
      end

      private

      def backoff_until(provider)
        val = REDIS_POOL.with { |redis| redis.get("#{REDIS_PREFIX}:#{provider}:backoff_until") }
        val ? val.to_f : nil
      end
    end
  end
end
