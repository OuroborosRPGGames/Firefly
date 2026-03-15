# frozen_string_literal: true

# Stores rich formatted logs for activity/mission runs.
#
# Log types:
#   - narrative: Story/flavor text describing what happens
#   - round_start: Beginning of a new round
#   - round_end: Conclusion of a round with outcomes
#   - action: A character's chosen action
#   - outcome: Result of an action (success/failure)
#   - combat: Combat-related events
#   - system: System messages (timeouts, etc.)
#   - summary: Final summary of the activity
#
# Skip loading if table doesn't exist
return unless DB.table_exists?(:activity_logs)

class ActivityLog < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :activity_instance
  many_to_one :activity_round
  many_to_one :character

  LOG_TYPES = %w[
    narrative
    round_start
    round_end
    action
    outcome
    combat
    system
    summary
  ].freeze

  OUTCOMES = %w[success partial failure].freeze

  VISIBILITY_LEVELS = %w[participants public private].freeze

  def validate
    super
    validates_presence [:activity_instance_id, :text, :log_type]
    validates_includes LOG_TYPES, :log_type
    validates_includes OUTCOMES, :outcome, allow_nil: true
  end

  # Format as HTML if html_content not set
  def formatted_content
    html_content || text_to_html(text)
  end

  # API representation
  def to_api_hash
    {
      id: id,
      type: log_type,
      title: title,
      text: text,
      html: formatted_content,
      round_number: round_number,
      action_name: action_name,
      outcome: outcome,
      roll_result: roll_result,
      difficulty: difficulty,
      character: character ? { id: character.id, name: character.full_name } : nil,
      created_at: created_at&.iso8601
    }
  end

  class << self
    # Get logs for an activity instance
    def for_instance(instance_id)
      where(activity_instance_id: instance_id)
        .order(:sequence, :created_at)
    end

    # Get logs for a specific round
    def for_round(instance_id, round_number)
      where(activity_instance_id: instance_id, round_number: round_number)
        .order(:sequence, :created_at)
    end

    # Next sequence number for an instance
    def next_sequence(instance_id)
      max = where(activity_instance_id: instance_id).max(:sequence) || 0
      max + 1
    end
  end

  private

  # Convert plain text to basic HTML
  def text_to_html(text)
    return '' if text.nil?

    # Escape HTML entities
    escaped = text.gsub('&', '&amp;')
                  .gsub('<', '&lt;')
                  .gsub('>', '&gt;')

    # Convert newlines to <br>
    escaped.gsub("\n", "<br>\n")
  end
end
