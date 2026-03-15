# frozen_string_literal: true

# HelpRequestCache - In-memory cache for recent help requests
#
# Stores player help requests for 10-minute follow-up context.
# Uses simple hash storage with TTL-based expiration.
#
# Usage:
#   HelpRequestCache.store(
#     character_instance_id: 123,
#     query: "how do I fight?",
#     response: "Use the fight command...",
#     matched_topics: ["fight", "attack"]
#   )
#
#   prior = HelpRequestCache.recent_for(123, window: 600)
#   prior[:query]  # => "how do I fight?"
#
class HelpRequestCache
  # TTL for cache entries (10 minutes)
  TTL_SECONDS = 600

  # Max entries to prevent memory bloat
  MAX_ENTRIES = 1000

  class << self
    # Store a help request
    def store(character_instance_id:, query:, response:, matched_topics:)
      cleanup_expired!

      @cache ||= {}
      @cache[character_instance_id] = {
        query: query,
        response: response,
        matched_topics: matched_topics,
        created_at: Time.now
      }

      # Trim if over max entries
      trim_cache! if @cache.size > MAX_ENTRIES
    end

    # Find recent request for a character within time window
    # @param character_instance_id [Integer]
    # @param window [Integer] seconds to look back
    # @return [Hash, nil] cached request data or nil
    def recent_for(character_instance_id, window: TTL_SECONDS)
      @cache ||= {}
      entry = @cache[character_instance_id]
      return nil unless entry

      age = Time.now - entry[:created_at]
      return nil if age > window

      {
        query: entry[:query],
        response: entry[:response],
        matched_topics: entry[:matched_topics],
        seconds_ago: age.to_i
      }
    end

    # Clear all entries (for testing)
    def clear!
      @cache = {}
    end

    # Get cache stats (for debugging)
    def stats
      @cache ||= {}
      {
        entries: @cache.size,
        oldest: @cache.values.map { |v| v[:created_at] }.min,
        newest: @cache.values.map { |v| v[:created_at] }.max
      }
    end

    private

    def cleanup_expired!
      return unless @cache

      cutoff = Time.now - TTL_SECONDS
      @cache.delete_if { |_, v| v[:created_at] < cutoff }
    end

    def trim_cache!
      # Remove oldest 20% of entries
      remove_count = (@cache.size * 0.2).ceil
      sorted = @cache.sort_by { |_, v| v[:created_at] }
      sorted.first(remove_count).each { |k, _| @cache.delete(k) }
    end
  end
end
