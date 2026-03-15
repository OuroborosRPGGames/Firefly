# frozen_string_literal: true

# LlmBatch groups multiple LLMRequests for batch processing.
#
# Usage:
#   batch = LlmBatch.create(total_count: 10)
#   batch.wait!(timeout: 120)
#   batch.results
#
class LlmBatch < Sequel::Model
  include StatusEnum

  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  one_to_many :llm_requests, class: 'LLMRequest'

  status_enum :status, %w[pending completed failed]

  REDIS_KEY_PREFIX = 'llm:batch'

  def validate
    super
    validate_status_enum
  end

  # Increment completed count atomically via Redis.
  # Called by workers after each request finishes.
  # @return [Boolean] true if this increment completed the batch
  def record_completion!
    new_count = REDIS_POOL.with do |redis|
      redis.incr("#{REDIS_KEY_PREFIX}:#{id}:completed")
    end

    if new_count >= total_count
      complete!
      true
    else
      false
    end
  end

  # Mark batch as completed, fire callback, publish done signal.
  def complete!
    final_count = REDIS_POOL.with { |redis| redis.get("#{REDIS_KEY_PREFIX}:#{id}:completed").to_i }
    update(
      status: 'completed',
      completed_count: final_count,
      completed_at: Time.now
    )

    # Publish done signal for wait!
    REDIS_POOL.with do |redis|
      redis.publish("#{REDIS_KEY_PREFIX}:#{id}:done", 'done')
    end

    invoke_callback
    cleanup_redis_keys
  end

  # Block until batch completes or timeout.
  # Uses Redis pub/sub to avoid polling.
  # @param timeout [Integer] max seconds to wait (default 300)
  # @return [Boolean] true if completed, false if timed out
  def wait!(timeout: 300)
    return true if completed?

    current = REDIS_POOL.with { |redis| redis.get("#{REDIS_KEY_PREFIX}:#{id}:completed").to_i }
    if current >= total_count
      refresh
      return true if completed?
    end

    done = false
    subscriber = Redis.new(url: ENV['REDIS_URL'])
    begin
      subscriber.subscribe_with_timeout(timeout, "#{REDIS_KEY_PREFIX}:#{id}:done") do |on|
        on.message do |_channel, _message|
          done = true
          subscriber.unsubscribe
        end
      end
    rescue Redis::TimeoutError
      # Timed out waiting
    ensure
      subscriber.close
    end

    refresh if done
    done
  end

  def results
    LLMRequest.where(llm_batch_id: id).all
  end

  def successful_results
    LLMRequest.where(llm_batch_id: id, status: 'completed').all
  end

  def failed_results
    LLMRequest.where(llm_batch_id: id, status: 'failed').all
  end

  private

  def invoke_callback
    return if callback_handler.nil? || callback_handler.empty?

    handler_class = Object.const_get(callback_handler)
    handler_class.call(self)
  rescue NameError => e
    warn "[LlmBatch] Callback handler not found: #{callback_handler} - #{e.message}"
  rescue StandardError => e
    warn "[LlmBatch] Callback error: #{e.message}"
  end

  def cleanup_redis_keys
    REDIS_POOL.with do |redis|
      redis.del(
        "#{REDIS_KEY_PREFIX}:#{id}:completed",
        "#{REDIS_KEY_PREFIX}:#{id}:total"
      )
    end
  end
end
