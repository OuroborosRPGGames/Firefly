# frozen_string_literal: true

# GenerationJob tracks async world building generation tasks
#
# Supports hierarchical jobs (city -> places -> rooms) via parent_job_id
# Progress tracked in JSONB with WebSocket updates
#
# @example Create a room description job
#   job = GenerationJob.create(
#     job_type: 'description',
#     config: { target_type: 'room', target_id: 123 },
#     created_by_id: character.id
#   )
#
class GenerationJob < Sequel::Model
  include StatusEnum

  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  # Job types
  JOB_TYPES = %w[
    city place room npc item
    description image schedule
    mission
  ].freeze

  # Mission generation phases
  MISSION_PHASES = %w[brainstorm synthesis round_detail building].freeze

  # Status values
  status_enum :status, %w[pending running completed failed cancelled]

  # Associations
  many_to_one :parent_job, class: :GenerationJob, key: :parent_job_id
  one_to_many :child_jobs, class: :GenerationJob, key: :parent_job_id
  many_to_one :created_by, class: :Character, key: :created_by_id

  # Ensure JSONB columns are handled correctly
  def before_save
    self.config = Sequel.pg_jsonb(config || {}) if config.is_a?(Hash)
    self.progress = Sequel.pg_jsonb(progress || {}) if progress.is_a?(Hash)
    self.results = Sequel.pg_jsonb(results || {}) if results.is_a?(Hash)
    self.brainstorm_outputs = Sequel.pg_jsonb(brainstorm_outputs || {}) if brainstorm_outputs.is_a?(Hash)
    self.synthesized_plan = Sequel.pg_jsonb(synthesized_plan || {}) if synthesized_plan.is_a?(Hash)
    super
  end

  # Validations
  def validate
    super
    validates_presence [:job_type]
    validates_includes JOB_TYPES, :job_type
    validate_status_enum
  end

  def finished?
    completed? || failed? || cancelled?
  end

  # Start the job
  def start!
    update(status: 'running', started_at: Time.now)
  end

  # Complete the job with results
  # @param result_data [Hash] generated content info
  def complete!(result_data = {})
    update(
      status: 'completed',
      completed_at: Time.now,
      results: (results || {}).merge(result_data)
    )
  end

  # Fail the job with error
  # @param error [String, Exception] error message
  def fail!(error)
    message = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
    update(
      status: 'failed',
      completed_at: Time.now,
      error_message: message
    )
  end

  # Cancel the job
  def cancel!
    update(status: 'cancelled', completed_at: Time.now)
  end

  # Update progress
  # @param step [Integer] current step number
  # @param total [Integer] total steps
  # @param message [String] optional status message
  def update_progress!(step:, total:, message: nil)
    prog = {
      'current_step' => step,
      'total_steps' => total,
      'percent' => total.positive? ? ((step.to_f / total) * 100).round(1) : 0
    }
    prog['message'] = message if message
    # Use to_h to get a fresh hash that Sequel will detect as changed
    new_progress = progress.to_h.merge(prog)
    update(progress: new_progress)
  end

  # Add to progress log
  # @param entry [String] log entry
  def log_progress!(entry)
    # Create a NEW array to avoid in-place mutation that Sequel won't detect
    current_log = (progress&.dig('log') || []).dup
    current_log << { 'time' => Time.now.iso8601, 'message' => entry }
    # Use to_h to get a fresh hash that Sequel will detect as changed
    new_progress = progress.to_h.merge('log' => current_log)
    update(progress: new_progress)
  end

  # Get config value
  # @param key [String, Symbol]
  # @return [Object]
  def config_value(key)
    return nil unless config

    config[key.to_s] || config[key.to_sym]
  end

  # Get result value
  # @param key [String, Symbol]
  # @return [Object]
  def result_value(key)
    return nil unless results

    results[key.to_s] || results[key.to_sym]
  end

  # Calculate overall progress including child jobs
  # @return [Float] percentage 0-100
  def total_progress
    return progress&.dig('percent') || 0 if child_jobs.empty?

    child_progress = child_jobs.map(&:total_progress)
    return 0 if child_progress.empty?

    child_progress.sum / child_progress.length
  end

  # Check if all child jobs are complete
  # @return [Boolean]
  def children_complete?
    child_jobs.all?(&:finished?)
  end

  # Get human-readable status
  # @return [String]
  def status_display
    case status
    when 'pending' then 'Waiting to start'
    when 'running'
      if progress&.dig('message')
        progress['message']
      else
        "Running (#{progress&.dig('percent') || 0}%)"
      end
    when 'completed' then 'Completed'
    when 'failed' then "Failed: #{error_message}"
    when 'cancelled' then 'Cancelled'
    else status
    end
  end

  # Get human-readable job type
  # @return [String]
  def type_display
    case job_type
    when 'city' then 'City Generation'
    when 'place' then 'Place/Building'
    when 'room' then 'Room'
    when 'npc' then 'NPC'
    when 'item' then 'Item'
    when 'description' then 'Description'
    when 'image' then 'Image'
    when 'schedule' then 'NPC Schedule'
    when 'mission' then 'Mission Generation'
    else NamingHelper.titleize(job_type.to_s)
    end
  end

  # Update mission generation phase
  # @param new_phase [String] brainstorm, synthesis, or building
  def update_phase!(new_phase)
    update(phase: new_phase)
    log_progress!("Entering #{new_phase} phase")
  end

  # Store brainstorm outputs
  # @param outputs [Hash] model outputs from brainstorm phase
  def store_brainstorm!(outputs)
    update(brainstorm_outputs: outputs)
  end

  # Store synthesized mission plan
  # @param plan [Hash] mission plan from synthesis phase
  def store_synthesis!(plan)
    update(synthesized_plan: plan)
  end

  # Duration in seconds
  # @return [Float, nil]
  def duration
    return nil unless started_at

    end_time = completed_at || Time.now
    end_time - started_at
  end

  # Format duration for display
  # @return [String]
  def duration_display
    secs = duration
    return 'Not started' unless secs

    if secs < 60
      "#{secs.round(1)}s"
    elsif secs < 3600
      "#{(secs / 60).round(1)}m"
    else
      "#{(secs / 3600).round(1)}h"
    end
  end

  # Class methods
  class << self
    # Find active jobs for a character
    # @param character_id [Integer]
    # @return [Array<GenerationJob>]
    def active_for_character(character_id)
      where(created_by_id: character_id)
        .where(status: %w[pending running])
        .order(Sequel.desc(:created_at))
        .all
    end

    # Find recent jobs for a character
    # @param character_id [Integer]
    # @param limit [Integer]
    # @return [Array<GenerationJob>]
    def recent_for_character(character_id, limit: 20)
      where(created_by_id: character_id)
        .order(Sequel.desc(:created_at))
        .limit(limit)
        .all
    end

    # Find stale running jobs (stuck for over 30 minutes)
    # @return [Array<GenerationJob>]
    def stale_running
      where(status: 'running')
        .where { started_at < Time.now - GameConfig::Timeouts::GENERATION_JOB_TIMEOUT_SECONDS }
        .all
    end

    # Clean up old completed jobs (older than 7 days)
    # @return [Integer] number deleted
    def cleanup_old!
      where(status: %w[completed failed cancelled])
        .where { completed_at < Time.now - (7 * 86_400) }
        .delete
    end
  end
end
