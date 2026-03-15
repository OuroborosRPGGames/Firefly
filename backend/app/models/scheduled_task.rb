# frozen_string_literal: true

# ScheduledTask model for persistent task scheduling
#
# Supports three types of scheduling:
# - 'cron': Runs at specific times (minutes, hours, days, weekdays)
# - 'interval': Runs every N seconds
# - 'tick': Runs every N game ticks (typically 5 seconds each)
#
class ScheduledTask < Sequel::Model
  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  # Validations
  def validate
    super
    validates_presence [:name, :task_type]
    validates_unique :name
    validates_includes %w[cron interval tick], :task_type
  end

  # Ensure array columns are handled as pg arrays
  def before_save
    self.cron_minutes = Sequel.pg_array(cron_minutes || [], :integer) if cron_minutes.is_a?(Array)
    self.cron_hours = Sequel.pg_array(cron_hours || [], :integer) if cron_hours.is_a?(Array)
    self.cron_days = Sequel.pg_array(cron_days || [], :integer) if cron_days.is_a?(Array)
    self.cron_weekdays = Sequel.pg_array(cron_weekdays || [], :integer) if cron_weekdays.is_a?(Array)
    super
  end

  # Check if this task should run now
  # @return [Boolean]
  def should_run?
    return false unless enabled

    case task_type
    when 'cron'
      should_run_cron?
    when 'interval'
      should_run_interval?
    when 'tick'
      should_run_tick?
    else
      false
    end
  end

  # Execute the task
  # @return [Boolean] success
  def execute!
    return false unless should_run?

    begin
      handler = resolve_handler
      return false unless handler

      handler.call(self)
      record_success!
      true
    rescue StandardError => e
      record_error!(e)
      false
    end
  end

  # Record successful execution
  def record_success!
    update(
      last_run_at: Time.now,
      next_run_at: calculate_next_run,
      run_count: (run_count || 0) + 1
    )
  end

  # Record execution error
  # @param error [Exception]
  def record_error!(error)
    update(
      last_run_at: Time.now,
      next_run_at: calculate_next_run,
      error_count: (error_count || 0) + 1,
      last_error: "#{error.class}: #{error.message}"
    )
  end

  # Calculate the next run time
  # @return [DateTime, nil]
  def calculate_next_run
    case task_type
    when 'cron'
      Firefly::Cron.next_occurrence(cron_spec)
    when 'interval'
      Time.now + interval_seconds
    when 'tick'
      # Ticks are handled by the scheduler, not by time
      nil
    end
  end

  # Get cron specification hash
  # @return [Hash]
  def cron_spec
    {
      minutes: cron_minutes&.to_a || [],
      hours: cron_hours&.to_a || [],
      days: cron_days&.to_a || [],
      weekdays: cron_weekdays&.to_a || []
    }
  end

  # Find all tasks due to run
  # @return [Array<ScheduledTask>]
  def self.due_tasks
    where(enabled: true)
      .where { next_run_at <= Time.now }
      .or(next_run_at: nil)
      .all
  end

  # Find all tick-based tasks
  # @param tick_count [Integer] current tick number
  # @return [Array<ScheduledTask>]
  def self.tick_tasks(tick_count)
    where(enabled: true, task_type: 'tick')
      .all
      .select { |task| (tick_count % (task.tick_interval || 1)).zero? }
  end

  # Register a new scheduled task
  # @param name [String] unique task name
  # @param type [String] 'cron', 'interval', or 'tick'
  # @param options [Hash] task options
  # @return [ScheduledTask]
  def self.register(name, type, options = {})
    existing = first(name: name)
    if existing
      existing.update(options.merge(task_type: type))
      existing
    else
      create(options.merge(name: name, task_type: type))
    end
  end

  private

  def should_run_cron?
    return false unless next_run_at
    Time.now >= next_run_at
  end

  def should_run_interval?
    return true unless last_run_at
    return false unless interval_seconds

    Time.now >= (last_run_at + interval_seconds)
  end

  def should_run_tick?
    # Tick tasks are evaluated by the scheduler with tick_count
    # This method is called when checking individual tasks
    true
  end

  def resolve_handler
    return nil unless handler_class

    begin
      Object.const_get(handler_class)
    rescue NameError
      warn "[ScheduledTask] Handler class not found: #{handler_class}"
      nil
    end
  end
end
