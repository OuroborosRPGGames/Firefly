# frozen_string_literal: true

require 'sidekiq'

# Sidekiq job that processes a single LLM API request.
#
# Handles concurrency throttling, rate limit detection, and batch completion.
# The actual API call is delegated to RequestProcessor.process.
#
# Usage:
#   LlmRequestJob.perform_async(request.id)
#
class LlmRequestJob
  include Sidekiq::Job

  sidekiq_options queue: 'llm', retry: 3

  # Sidekiq retry uses exponential backoff by default (matches our needs).
  # Custom retry delay: 1s, 2s, 4s (matching existing RETRY_DELAYS).
  sidekiq_retry_in do |count, _exception|
    [1, 2, 4][count] || 4
  end

  sidekiq_retries_exhausted do |job, exception|
    request_id = job['args']&.first
    request = LLMRequest[request_id]
    next unless request
    next if request.completed? || request.cancelled?

    error = "Job retries exhausted: #{exception.message}"
    request.fail!(error)
    LLM::RequestProcessor.send(:invoke_callback, request, { success: false, error: error })

    if request.llm_batch_id
      batch = LlmBatch[request.llm_batch_id]
      batch&.record_completion!
    end
  end

  def perform(request_id)
    request = LLMRequest[request_id]
    unless request
      warn "[LlmRequestJob] Request #{request_id} not found, skipping"
      return
    end

    return if request.completed? || request.cancelled?

    provider = request.provider

    # Try to acquire a concurrency slot (non-blocking).
    # If unavailable, re-schedule instead of blocking the Sidekiq thread.
    unless LLM::ProviderThrottle.try_acquire_slot(provider)
      handle_slot_backpressure(request)
      return
    end

    begin
      unless request.claim_for_processing!
        warn "[LlmRequestJob] Request #{request_id} already claimed, skipping duplicate job"
        return
      end

      LLM::RequestProcessor.process(request, claimed: true)

      # Check for rate limiting
      if request.refresh.failed? && request.error_message&.include?('429')
        LLM::ProviderThrottle.record_rate_limit(provider)
      else
        LLM::ProviderThrottle.record_success(provider)
      end
    rescue StandardError => e
      warn "[LlmRequestJob] Processing request #{request_id} failed: #{e.message}"
      begin
        request.this.update(status: 'pending', started_at: nil) unless request.completed? || request.cancelled?
      rescue StandardError => reset_err
        warn "[LlmRequestJob] Failed to reset request #{request_id} to pending: #{reset_err.message}"
      end
      raise
    ensure
      LLM::ProviderThrottle.release_slot(provider)
    end

    # Update batch completion only when request reaches terminal state
    request.refresh
    record_batch_completion_if_terminal(request)
  end

  private

  def handle_slot_backpressure(request)
    if request.should_retry?
      retry_index = [request.retry_count - 1, 0].max
      delay = LLM::RequestProcessor::RETRY_DELAYS[retry_index] || LLM::RequestProcessor::RETRY_DELAYS.last
      self.class.perform_in(delay, request.id)
    else
      error = "Provider busy: could not acquire slot for #{request.provider} after #{request.max_retries} attempts"
      request.fail!(error)
      LLM::RequestProcessor.send(:invoke_callback, request, { success: false, error: error })
      record_batch_completion_if_terminal(request)
    end
  end

  def record_batch_completion_if_terminal(request)
    return unless request.llm_batch_id && (request.completed? || request.failed?)

    batch = LlmBatch[request.llm_batch_id]
    batch&.record_completion!
  end
end
