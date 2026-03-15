# frozen_string_literal: true

# TimedAction model for actions that take time to complete
#
# Supports three types of timed actions:
# - 'delayed': Actions that complete after a delay (crafting, lockpicking)
# - 'cast': Interruptible actions with cast times (spells, channeled abilities)
# - 'channel': Continuous actions that tick over time
#
class TimedAction < Sequel::Model
  include StatusEnum

  plugin :timestamps, update_on_create: true
  plugin :validation_helpers

  many_to_one :character_instance

  status_enum :status, %w[active completed cancelled interrupted]
  ACTION_TYPES = %w[delayed cast channel].freeze

  # Validations
  def validate
    super
    validates_presence [:character_instance_id, :action_type, :action_name, :started_at, :status]
    validates_includes ACTION_TYPES, :action_type
    validate_status_enum
  end

  # Start a delayed action
  # @param char_instance [CharacterInstance] character performing action
  # @param name [String] action name
  # @param duration_ms [Integer] duration in milliseconds
  # @param handler [String] class name for completion handler
  # @param data [Hash] additional action data
  # @return [TimedAction]
  def self.start_delayed(char_instance, name, duration_ms, handler = nil, data = {})
    create(
      character_instance_id: char_instance.id,
      action_type: 'delayed',
      action_name: name,
      duration_ms: duration_ms,
      started_at: Time.now,
      completes_at: Time.now + (duration_ms / 1000.0),
      status: 'active',
      completion_handler: handler,
      action_data: data.to_json
    )
  end

  # Start a cast-time action (interruptible)
  # @param char_instance [CharacterInstance] character performing action
  # @param name [String] action name
  # @param duration_ms [Integer] cast time in milliseconds
  # @param handler [String] class name for completion handler
  # @param data [Hash] additional action data
  # @return [TimedAction]
  def self.start_cast(char_instance, name, duration_ms, handler = nil, data = {})
    create(
      character_instance_id: char_instance.id,
      action_type: 'cast',
      action_name: name,
      duration_ms: duration_ms,
      started_at: Time.now,
      completes_at: Time.now + (duration_ms / 1000.0),
      status: 'active',
      interruptible: true,
      completion_handler: handler,
      action_data: data.to_json
    )
  end

  # Check if action is complete (by status or by time)
  # @return [Boolean]
  def complete?
    return true if completed?
    return false unless completes_at

    Time.now >= completes_at
  end

  # Calculate current progress percentage
  # @return [Integer] 0-100
  def calculate_progress
    return 100 if complete?
    return 0 unless started_at && duration_ms && duration_ms.positive?

    elapsed_ms = ((Time.now - started_at) * 1000).to_i
    [(elapsed_ms * 100 / duration_ms).to_i, 100].min
  end

  # Complete the action and run handler
  # @return [Boolean] success
  def finish!
    return false unless active?
    return false unless complete?

    begin
      run_completion_handler
      update(
        status: 'completed',
        progress_percent: 100,
        completed_at: Time.now
      )
      true
    rescue StandardError => e
      update(
        status: 'completed',
        completed_at: Time.now,
        result_data: { error: e.message }.to_json
      )
      false
    end
  end

  # Interrupt the action (for cast-time actions)
  # @param reason [String] reason for interruption
  # @return [Boolean] success
  def interrupt!(reason = 'interrupted')
    return false unless active?
    return false unless interruptible

    update(
      status: 'interrupted',
      completed_at: Time.now,
      result_data: { reason: reason }.to_json
    )
    true
  end

  # Cancel the action (by player choice)
  # @return [Boolean] success
  def cancel!
    return false unless active?

    update(
      status: 'cancelled',
      completed_at: Time.now
    )
    true
  end

  # Get parsed action data
  # @return [Hash]
  def parsed_action_data
    return {} if action_data.nil?

    # Handle both JSONB (from database) and string (from test setup)
    if action_data.is_a?(String)
      return {} if action_data.empty?
      JSON.parse(action_data, symbolize_names: true)
    elsif action_data.respond_to?(:to_hash)
      # Sequel::Postgres::JSONBHash or Hash-like objects
      action_data.to_hash.transform_keys(&:to_sym)
    else
      {}
    end
  rescue JSON::ParserError
    {}
  end

  # Get parsed result data
  # @return [Hash]
  def parsed_result_data
    return {} if result_data.nil?

    # Handle both JSONB (from database) and string (from test setup)
    if result_data.is_a?(String)
      return {} if result_data.empty?
      JSON.parse(result_data, symbolize_names: true)
    elsif result_data.respond_to?(:to_hash)
      # Sequel::Postgres::JSONBHash or Hash-like objects
      result_data.to_hash.transform_keys(&:to_sym)
    else
      {}
    end
  rescue JSON::ParserError
    {}
  end

  # Format for API consumption
  # @return [Hash]
  def to_api_format
    {
      id: id,
      action_type: action_type,
      action_name: action_name,
      status: status,
      progress_percent: calculate_progress,
      progress_message: progress_message,
      started_at: started_at&.iso8601,
      completes_at: completes_at&.iso8601,
      interruptible: interruptible,
      time_remaining_ms: time_remaining_ms
    }
  end

  # Get time remaining in milliseconds
  # @return [Integer, nil]
  def time_remaining_ms
    return nil unless completes_at
    return 0 if complete?

    ((completes_at - Time.now) * 1000).to_i.clamp(0, Float::INFINITY).to_i
  end

  # Find active actions for a character
  # @param char_instance_id [Integer]
  # @return [Array<TimedAction>]
  def self.active_for_character(char_instance_id)
    where(character_instance_id: char_instance_id, status: 'active').all
  end

  # Find all actions ready to complete
  # @return [Array<TimedAction>]
  def self.ready_to_complete
    where(status: 'active')
      .where { completes_at <= Time.now }
      .all
  end

  # Process all ready actions
  # @return [Integer] number processed
  def self.process_ready!
    count = 0
    ready_to_complete.each do |action|
      count += 1 if action.finish!
    end
    count
  end

  private

  def run_completion_handler
    return unless completion_handler

    begin
      handler_class = Object.const_get(completion_handler)
      handler_class.call(self)
    rescue NameError
      warn "[TimedAction] Handler not found: #{completion_handler}"
    end
  end
end
