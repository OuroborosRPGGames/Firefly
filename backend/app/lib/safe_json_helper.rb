# frozen_string_literal: true

require 'json'

# Shared JSON parsing with standardized error handling.
# Used across LLM response parsers and activity services.
module SafeJSONHelper
  # Parse a JSON string, returning +fallback+ on failure.
  #
  # @param text [String, nil] the JSON to parse
  # @param fallback [Object] value to return on parse failure
  # @param context [String] service name for the warning message
  # @param parse_options [Hash] options forwarded to JSON.parse (e.g. symbolize_names: true)
  # @return [Object] parsed value or fallback
  def safe_json_parse(text, fallback:, context:, **parse_options)
    return fallback if text.nil? || text.strip.empty?

    JSON.parse(text, **parse_options)
  rescue JSON::ParserError => e
    warn "[#{context}] JSON parse failed: #{e.message}"
    fallback
  end
end
