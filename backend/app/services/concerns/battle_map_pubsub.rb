# frozen_string_literal: true

# Shared Redis pub/sub helpers for battle map generation progress.
# Include in any service that needs to publish generation progress or completion.
module BattleMapPubsub
  # Publish a progress update for battle map generation.
  # @param fight_id [Integer] the fight ID
  # @param progress [Integer] percentage complete (0-100)
  # @param step [String] description of current step
  def publish_progress(fight_id, progress, step)
    REDIS_POOL.with do |redis|
      redis.publish(
        "fight:#{fight_id}:generation",
        {
          type: "progress",
          progress: progress,
          step: step,
          timestamp: Time.now.to_i
        }.to_json
      )
    end
  rescue StandardError => e
    warn "[#{self.class.name}] Failed to publish progress: #{e.message}"
  end

  # Publish a completion message for battle map generation.
  # @param fight_id [Integer] the fight ID
  # @param success [Boolean] whether generation succeeded
  # @param fallback [Boolean] whether procedural fallback was used
  def publish_completion(fight_id, success:, fallback: false)
    REDIS_POOL.with do |redis|
      redis.publish(
        "fight:#{fight_id}:generation",
        {
          type: "complete",
          success: success,
          fallback: fallback,
          battle_map_ready: success,
          timestamp: Time.now.to_i
        }.to_json
      )
    end
  rescue StandardError => e
    warn "[#{self.class.name}] Failed to publish completion: #{e.message}"
  end
end
