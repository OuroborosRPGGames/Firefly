# frozen_string_literal: true

# ProgressTrackerService manages GenerationJob lifecycle and progress updates
#
# Provides job creation, progress tracking, and completion/failure handling.
# Designed to support WebSocket progress broadcasting when available.
#
# @example Create and track a job
#   job = ProgressTrackerService.create_job(
#     type: :description,
#     config: { target_type: 'room', target_id: 123 },
#     created_by: character
#   )
#
#   ProgressTrackerService.update_progress(job: job, step: 1, total: 3, message: "Generating...")
#   ProgressTrackerService.complete(job: job, results: { description: "A cozy room..." })
#
class ProgressTrackerService
  class << self
    # Create a new generation job
    # @param type [Symbol, String] job type (:city, :place, :room, :npc, :item, :description, :image)
    # @param config [Hash] job configuration
    # @param parent_job [GenerationJob, nil] parent job for hierarchical tracking
    # @param created_by [Character, nil] character who initiated
    # @return [GenerationJob]
    def create_job(type:, config:, parent_job: nil, created_by: nil)
      GenerationJob.create(
        job_type: type.to_s,
        status: 'pending',
        config: config,
        progress: { current_step: 0, total_steps: 0, percent: 0, log: [] },
        results: {},
        parent_job_id: parent_job&.id,
        created_by_id: created_by&.id
      )
    end

    # Start a job (mark as running)
    # @param job [GenerationJob]
    # @param total_steps [Integer] expected total steps
    # @param message [String] initial status message
    def start(job:, total_steps: 1, message: nil)
      job.start!
      job.update_progress!(step: 0, total: total_steps, message: message || 'Starting...')
      broadcast_progress(job)
    end

    # Update job progress
    # @param job [GenerationJob]
    # @param step [Integer] current step number
    # @param total [Integer] total steps
    # @param message [String, nil] status message
    def update_progress(job:, step:, total:, message: nil)
      job.update_progress!(step: step, total: total, message: message)
      broadcast_progress(job)
    end

    # Add a log entry to job progress
    # @param job [GenerationJob]
    # @param message [String] log message
    def log(job:, message:)
      job.log_progress!(message)
      broadcast_progress(job)
    end

    # Complete a job successfully
    # @param job [GenerationJob]
    # @param results [Hash] generated content results
    def complete(job:, results: {})
      job.complete!(results)
      broadcast_progress(job)

      # Check if parent job should be updated
      check_parent_completion(job) if job.parent_job_id
    end

    # Fail a job with error
    # @param job [GenerationJob]
    # @param error [String, Exception] error information
    def fail(job:, error:)
      job.fail!(error)
      broadcast_progress(job)

      # Fail parent if this was critical
      propagate_failure_to_parent(job) if job.parent_job_id
    end

    # Cancel a job
    # @param job [GenerationJob]
    def cancel(job:)
      job.cancel!
      broadcast_progress(job)

      # Cancel all child jobs
      job.child_jobs.each do |child|
        cancel(job: child) unless child.finished?
      end
    end

    # Get progress for display
    # @param job [GenerationJob]
    # @return [Hash] formatted progress info
    def progress(job:)
      {
        id: job.id,
        type: job.type_display,
        status: job.status,
        status_display: job.status_display,
        percent: job.progress&.dig('percent') || 0,
        message: job.progress&.dig('message'),
        duration: job.duration_display,
        has_children: job.child_jobs.any?,
        children_complete: job.children_complete?,
        child_progress: job.child_jobs.map { |c| progress(job: c) },
        results: job.results,
        error: job.error_message,
        created_at: job.created_at&.iso8601,
        started_at: job.started_at&.iso8601,
        completed_at: job.completed_at&.iso8601
      }
    end

    # Get all active jobs for a character
    # @param character [Character]
    # @return [Array<Hash>] progress info for each job
    def active_jobs_for(character)
      GenerationJob.active_for_character(character.id).map do |job|
        progress(job: job)
      end
    end

    # Get recent jobs for a character
    # @param character [Character]
    # @param limit [Integer]
    # @return [Array<Hash>]
    def recent_jobs_for(character, limit: 20)
      GenerationJob.recent_for_character(character.id, limit: limit).map do |job|
        progress(job: job)
      end
    end

    # Run a generation task with automatic job tracking
    # @param type [Symbol] job type
    # @param config [Hash] job configuration
    # @param created_by [Character, nil]
    # @param total_steps [Integer] expected steps
    # @yield [job] block to execute with the job
    # @return [GenerationJob]
    def with_job(type:, config:, created_by: nil, total_steps: 1, &block)
      job = create_job(type: type, config: config, created_by: created_by)
      start(job: job, total_steps: total_steps)

      begin
        result = yield(job) if block_given?
        complete(job: job, results: result || {})
      rescue StandardError => e
        fail(job: job, error: e)
        raise
      end

      job
    end

    # Spawn a background thread for async job execution
    # @param job [GenerationJob]
    # @yield [job] block to execute
    def spawn_async(job:, &block)
      Thread.new do
        begin
          yield(job) if block_given?
        rescue StandardError => e
          fail(job: job, error: e)
          warn "[ProgressTrackerService] Async job #{job.id} failed: #{e.message}"
        end
      end
    end

    # Clean up old jobs (run periodically)
    # @return [Integer] number deleted
    def cleanup_old_jobs!
      GenerationJob.cleanup_old!
    end

    # Mark stale running jobs as failed
    # @return [Integer] number marked failed
    def mark_stale_jobs_failed!
      count = 0
      GenerationJob.stale_running.each do |job|
        job.fail!('Job timed out (stuck for over 30 minutes)')
        count += 1
      end
      count
    end

    private

    # Broadcast progress update (placeholder for WebSocket integration)
    # @param job [GenerationJob]
    def broadcast_progress(job)
      # Future: Use BroadcastService or AnyCable to push updates
      # For now, just log for debugging
      return unless ENV['DEBUG_GENERATION_PROGRESS']

      warn "[GenerationJob #{job.id}] #{job.status} - #{job.progress&.dig('message')}"
    end

    # Check if parent job should be marked complete
    def check_parent_completion(job)
      parent = job.parent_job
      return unless parent

      if parent.children_complete?
        # Aggregate child results
        child_results = parent.child_jobs.map(&:results).compact
        parent.complete!(children_results: child_results)
        broadcast_progress(parent)
      else
        # Update parent progress based on children
        completed = parent.child_jobs.count(&:completed?)
        total = parent.child_jobs.count
        parent.update_progress!(
          step: completed,
          total: total,
          message: "Completed #{completed}/#{total} sub-tasks"
        )
        broadcast_progress(parent)
      end
    end

    # Propagate failure to parent job
    def propagate_failure_to_parent(job)
      parent = job.parent_job
      return unless parent

      # Don't auto-fail parent - just log the child failure
      parent.log_progress!("Child job #{job.id} (#{job.job_type}) failed: #{job.error_message}")
      broadcast_progress(parent)
    end
  end
end
