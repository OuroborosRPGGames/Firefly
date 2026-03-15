# frozen_string_literal: true

# WorldGenerationJob tracks background world generation tasks
# Used for both random procedural generation and Earth data import

class WorldGenerationJob < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :world

  JOB_TYPES = %w[random_procedural procedural procedural_flat earth_import earth_import_flat].freeze
  status_enum :status, %w[pending running completed failed cancelled]

  def validate
    super
    validates_presence [:world_id, :job_type]
    validates_includes JOB_TYPES, :job_type
    validate_status_enum
  end

  def finished?
    completed? || failed? || cancelled?
  end

  # Start the job
  def start!
    update(
      status: 'running',
      started_at: Time.now
    )
  end

  # Update progress
  def update_progress!(completed, total = nil)
    updates = { completed_regions: completed }
    updates[:total_regions] = total if total
    updates[:progress_percentage] = total&.positive? ? (completed.to_f / total * 100).round(1) : 0.0
    update(updates)
  end

  # Mark as completed
  def complete!
    update(
      status: 'completed',
      progress_percentage: 100.0,
      completed_at: Time.now
    )
  end

  # Mark as failed
  def fail!(message, details = nil)
    update(
      status: 'failed',
      error_message: message,
      error_details: details,
      completed_at: Time.now
    )
  end

  # Mark as cancelled
  def cancel!
    update(
      status: 'cancelled',
      completed_at: Time.now
    )
  end

  # Duration in seconds
  def duration
    return nil unless started_at

    end_time = completed_at || Time.now
    end_time - started_at
  end

  # Formatted duration
  def duration_formatted
    secs = duration
    return nil unless secs

    if secs < 60
      "#{secs.round}s"
    elsif secs < 3600
      "#{(secs / 60).round}m #{(secs % 60).round}s"
    else
      hours = (secs / 3600).floor
      mins = ((secs % 3600) / 60).round
      "#{hours}h #{mins}m"
    end
  end

  # API representation
  def to_api_hash
    {
      id: id,
      world_id: world_id,
      job_type: job_type,
      status: status,
      total_regions: total_regions,
      completed_regions: completed_regions,
      progress_percentage: progress_percentage,
      config: config,
      error_message: error_message,
      started_at: started_at&.iso8601,
      completed_at: completed_at&.iso8601,
      duration: duration_formatted
    }
  end

  class << self
    # Get the latest job for a world
    def latest_for(world)
      where(world_id: world.id).order(Sequel.desc(:created_at)).first
    end

    # Get running job for a world (should only be one)
    def running_for(world)
      where(world_id: world.id, status: 'running').first
    end

    # Create a new random generation job
    def create_random(world, options = {})
      create(
        world_id: world.id,
        job_type: 'random_procedural',
        status: 'pending',
        config: {
          seed: options[:seed] || Random.new_seed,
          ocean_coverage: options[:ocean_coverage] || 70,
          mountain_density: options[:mountain_density] || 10,
          forest_coverage: options[:forest_coverage] || 20
        }
      )
    end

    # Create a new earth import job
    def create_earth_import(world, options = {})
      create(
        world_id: world.id,
        job_type: 'earth_import',
        status: 'pending',
        config: {
          source: options[:source] || 'etopo1',
          region: options[:region], # nil = entire Earth
          scale: options[:scale] || 1.0
        }
      )
    end
  end
end
