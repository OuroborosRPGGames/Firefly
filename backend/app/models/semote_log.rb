# frozen_string_literal: true

# SemoteLog tracks smartemote LLM interpretations for auditing and debugging.
#
# Fields:
#   - emote_text: The original emote text from the player
#   - interpreted_actions: JSONB array of actions the LLM extracted
#   - executed_actions: JSONB array of actions that were actually run and their results
#
class SemoteLog < Sequel::Model
  plugin :timestamps, create: :created_at, update: false
  plugin :validation_helpers

  many_to_one :character_instance

  def validate
    super
    validates_presence [:character_instance_id, :emote_text]
  end

  # Create a log entry when LLM interprets an emote
  # @param character_instance [CharacterInstance]
  # @param emote_text [String]
  # @param interpreted_actions [Array<Hash>]
  # @return [SemoteLog]
  def self.log_interpretation(character_instance:, emote_text:, interpreted_actions:)
    create(
      character_instance_id: character_instance.id,
      emote_text: emote_text,
      interpreted_actions: interpreted_actions.to_json
    )
  end

  # Record the result of an executed action
  # @param command [String]
  # @param target [String, nil]
  # @param success [Boolean]
  # @param error [String, nil]
  def record_execution(command:, target: nil, success:, error: nil)
    current = parsed_executed_actions
    current << {
      command: command,
      target: target,
      success: success,
      error: error,
      executed_at: Time.now.iso8601
    }
    update(executed_actions: current.to_json)
  end

  # Parse interpreted_actions JSONB
  # @return [Array<Hash>]
  def parsed_interpreted_actions
    parse_jsonb(interpreted_actions)
  end

  # Parse executed_actions JSONB
  # @return [Array<Hash>]
  def parsed_executed_actions
    parse_jsonb(executed_actions)
  end

  private

  def parse_jsonb(field)
    return [] if field.nil?

    if field.is_a?(String)
      return [] if field.empty?
      JSON.parse(field, symbolize_names: true)
    elsif field.respond_to?(:to_a)
      field.to_a.map { |h| h.transform_keys(&:to_sym) }
    else
      []
    end
  rescue JSON::ParserError
    []
  end
end
