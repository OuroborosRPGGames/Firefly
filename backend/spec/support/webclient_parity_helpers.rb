# frozen_string_literal: true

# Helper module for testing parity between webclient rendering and MCP agent output.
# Both systems consume API responses but render differently - this ensures they
# receive equivalent information.
module WebclientParityHelpers
  # Execute command via agent API and return parsed response
  # @param command [String] the command to execute
  # @param args [String, nil] optional arguments
  # @return [Hash] parsed JSON response
  def post_command(command, args = nil)
    payload = { command: command }
    payload[:args] = args if args

    post '/api/agent/command',
         JSON.generate(payload),
         agent_headers

    @last_command_response = JSON.parse(last_response.body)
  end

  # Get the last command response
  # @return [Hash] parsed JSON response from last post_command call
  def data
    @last_command_response
  end

  # Extract description text from response (agent sees this)
  # @param response [Hash] API response
  # @return [String, nil] description text
  def extract_description(response)
    response['description'] || response.dig('message', 'content')
  end

  # Extract structured data from response (both webclient and agent use this)
  # @param response [Hash] API response
  # @return [Hash, nil] structured data
  def extract_structured(response)
    response['structured'] || response['data']
  end

  # Check if description contains all key information from structured data
  # @param response [Hash] API response
  # @return [Boolean] true if description matches structured content
  def description_matches_structured?(response)
    structured = extract_structured(response)
    description = extract_description(response)

    return false unless structured && description

    expected_content = []

    # Room name
    expected_content << structured.dig('room', 'name') if structured['room']

    # Exit destinations
    (structured['exits'] || []).each do |exit|
      expected_content << exit['to_room_name']
    end

    # Character names
    (structured['characters_ungrouped'] || []).each do |char|
      expected_content << char['name']
    end

    # Places and characters in places
    (structured['places'] || []).each do |place|
      (place['characters'] || []).each do |char|
        expected_content << char['name']
      end
    end

    expected_content.compact.all? { |content| description.include?(content.to_s) }
  end

  # Get expected content items from structured data for debugging
  # @param response [Hash] API response
  # @return [Array<String>] list of expected content items
  def expected_content_from_structured(response)
    structured = extract_structured(response)
    return [] unless structured

    content = []

    content << structured.dig('room', 'name') if structured['room']

    (structured['exits'] || []).each do |exit|
      content << exit['to_room_name']
    end

    (structured['characters_ungrouped'] || []).each do |char|
      content << char['name']
    end

    (structured['places'] || []).each do |place|
      (place['characters'] || []).each do |char|
        content << char['name']
      end
    end

    content.compact
  end

  # Find content items missing from description
  # @param response [Hash] API response
  # @return [Array<String>] content items not found in description
  def missing_from_description(response)
    description = extract_description(response)
    return [] unless description

    expected_content_from_structured(response).reject do |content|
      description.include?(content.to_s)
    end
  end
end
