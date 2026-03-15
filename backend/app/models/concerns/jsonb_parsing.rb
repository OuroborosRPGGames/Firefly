# frozen_string_literal: true

# Concern providing standardized JSONB parsing methods for Sequel models.
# Handles both Sequel::Postgres::JSONB types and plain strings.
#
# @example Including in a model
#   class Ability < Sequel::Model
#     include JsonbParsing
#
#     def parsed_costs
#       parse_jsonb_hash(costs)
#     end
#
#     def parsed_status_effects
#       parse_jsonb_array(applied_status_effects)
#     end
#   end
#
module JsonbParsing
  # Parse a JSONB field that should be a hash
  # @param value [Sequel::Postgres::JSONBHash, String, nil] The JSONB value
  # @param symbolize_keys [Boolean] Whether to symbolize hash keys (default false)
  # @return [Hash] The parsed hash, or empty hash if nil/invalid
  def parse_jsonb_hash(value, symbolize_keys: false)
    return {} unless value

    result = if value.respond_to?(:to_hash)
               value.to_hash
             elsif value.is_a?(String)
               JSON.parse(value)
             else
               {}
             end

    symbolize_keys ? result.transform_keys(&:to_sym) : result
  rescue JSON::ParserError
    {}
  end

  # Parse a JSONB field that should be an array
  # @param value [Sequel::Postgres::JSONBArray, String, nil] The JSONB value
  # @return [Array] The parsed array, or empty array if nil/invalid
  def parse_jsonb_array(value)
    return [] unless value

    if value.respond_to?(:to_a)
      value.to_a
    elsif value.is_a?(String)
      JSON.parse(value)
    else
      []
    end
  rescue JSON::ParserError
    []
  end
end
