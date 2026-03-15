# frozen_string_literal: true

# API Contract Matchers
#
# These matchers verify that API responses contain the fields required
# by the webclient for client-side rendering. This prevents the MCP agent
# and webclient from seeing different output.
#
# The webclient checks: (data.display_type || data.type) && (data.data || data.structured)
# If this fails, it falls back to server-rendered HTML which may differ.

RSpec::Matchers.define :have_structured_data_for_client do
  match do |response_data|
    data = response_data.is_a?(String) ? JSON.parse(response_data) : response_data
    data = data.transform_keys(&:to_s) if data.is_a?(Hash)

    has_type = data['type'] || data['display_type']
    has_data = data['data'] || data['structured']
    has_type && has_data
  end

  failure_message do |response_data|
    data = response_data.is_a?(String) ? JSON.parse(response_data) : response_data
    data = data.transform_keys(&:to_s) if data.is_a?(Hash)

    missing = []
    missing << 'type or display_type' unless data['type'] || data['display_type']
    missing << 'data or structured' unless data['data'] || data['structured']

    "expected response to have structured data for client-side rendering, but missing: #{missing.join(', ')}"
  end
end

RSpec::Matchers.define :have_room_exit_contract do
  match do |exit_data|
    data = exit_data.transform_keys(&:to_s)
    %w[direction to_room_name direction_arrow distance].all? do |field|
      data.key?(field)
    end
  end

  failure_message do |exit_data|
    data = exit_data.transform_keys(&:to_s)
    required = %w[direction to_room_name direction_arrow distance]
    missing = required.reject { |f| data.key?(f) }
    "expected exit to have all required fields, but missing: #{missing.join(', ')}"
  end
end

RSpec::Matchers.define :have_room_display_contract do
  match do |room_data|
    data = room_data.transform_keys(&:to_s)

    # Required top-level fields
    has_room = data.key?('room')
    has_exits = data.key?('exits')

    # Room must have basic fields
    room = data['room']&.transform_keys(&:to_s) || {}
    has_room_fields = room.key?('name') && room.key?('description')

    has_room && has_exits && has_room_fields
  end

  failure_message do |room_data|
    data = room_data.transform_keys(&:to_s)
    missing = []
    missing << 'room' unless data.key?('room')
    missing << 'exits' unless data.key?('exits')

    if data['room']
      room = data['room'].transform_keys(&:to_s)
      missing << 'room.name' unless room.key?('name')
      missing << 'room.description' unless room.key?('description')
    end

    "expected room display data to have required fields, but missing: #{missing.join(', ')}"
  end
end

RSpec::Matchers.define :have_character_display_contract do
  match do |char_data|
    data = char_data.transform_keys(&:to_s)

    # Required fields for character display
    data.key?('name') && data.key?('short_desc')
  end

  failure_message do |char_data|
    data = char_data.transform_keys(&:to_s)
    required = %w[name short_desc]
    missing = required.reject { |f| data.key?(f) }
    "expected character display to have required fields, but missing: #{missing.join(', ')}"
  end
end

RSpec::Matchers.define :have_quickmenu_contract do
  match do |quickmenu_data|
    data = quickmenu_data.transform_keys(&:to_s)

    # Required fields for quickmenu
    has_prompt = data.key?('prompt')
    has_options = data.key?('options') && data['options'].is_a?(Array)
    has_interaction_id = data.key?('interaction_id')

    # Each option must have key and label
    options_valid = has_options && data['options'].all? do |opt|
      opt = opt.transform_keys(&:to_s) if opt.is_a?(Hash)
      opt.key?('key') && opt.key?('label')
    end

    has_prompt && has_options && has_interaction_id && options_valid
  end

  failure_message do |quickmenu_data|
    data = quickmenu_data.transform_keys(&:to_s)
    missing = []
    missing << 'prompt' unless data.key?('prompt')
    missing << 'options' unless data.key?('options')
    missing << 'interaction_id' unless data.key?('interaction_id')

    if data['options'].is_a?(Array)
      data['options'].each_with_index do |opt, i|
        opt = opt.transform_keys(&:to_s) if opt.is_a?(Hash)
        missing << "options[#{i}].key" unless opt.key?('key')
        missing << "options[#{i}].label" unless opt.key?('label')
      end
    end

    "expected quickmenu to have required fields, but missing: #{missing.join(', ')}"
  end
end

RSpec::Matchers.define :have_form_contract do
  match do |form_data|
    data = form_data.transform_keys(&:to_s)

    # Required fields for form
    has_title = data.key?('title')
    has_fields = data.key?('fields') && data['fields'].is_a?(Array)
    has_interaction_id = data.key?('interaction_id')

    # Each field must have name and label
    fields_valid = has_fields && data['fields'].all? do |field|
      field = field.transform_keys(&:to_s) if field.is_a?(Hash)
      field.key?('name') && field.key?('label')
    end

    has_title && has_fields && has_interaction_id && fields_valid
  end

  failure_message do |form_data|
    data = form_data.transform_keys(&:to_s)
    missing = []
    missing << 'title' unless data.key?('title')
    missing << 'fields' unless data.key?('fields')
    missing << 'interaction_id' unless data.key?('interaction_id')

    if data['fields'].is_a?(Array)
      data['fields'].each_with_index do |field, i|
        field = field.transform_keys(&:to_s) if field.is_a?(Hash)
        missing << "fields[#{i}].name" unless field.key?('name')
        missing << "fields[#{i}].label" unless field.key?('label')
      end
    end

    "expected form to have required fields, but missing: #{missing.join(', ')}"
  end
end

# Verify description text matches structured data content (for webclient/agent parity)
RSpec::Matchers.define :have_equivalent_description do
  match do |response|
    structured = response['structured'] || response['data']
    description = response['description'] || response.dig('message', 'content')

    return false unless structured && description

    # Room name should appear in description
    if structured['room']
      return false unless description.include?(structured['room']['name'])
    end

    # Exit destinations should appear
    (structured['exits'] || []).each do |exit|
      room_name = exit['to_room_name']
      direction = exit['direction']
      return false unless description.include?(room_name) ||
                          description.downcase.include?(direction.to_s.downcase)
    end

    true
  end

  failure_message do |response|
    structured = response['structured'] || response['data']
    description = response['description'] || response.dig('message', 'content')

    missing = []
    if structured['room'] && !description.include?(structured['room']['name'])
      missing << "room name '#{structured['room']['name']}'"
    end

    (structured['exits'] || []).each do |exit|
      room_name = exit['to_room_name']
      direction = exit['direction']
      unless description.include?(room_name) || description.downcase.include?(direction.to_s.downcase)
        missing << "exit '#{room_name}' or direction '#{direction}'"
      end
    end

    "Expected description to include all structured data content.\n" \
    "Missing: #{missing.join(', ')}\n" \
    "Description: #{description&.truncate(200)}"
  end
end

# Verify message response has sender/speaker and content
RSpec::Matchers.define :have_message_contract do
  match do |data|
    data = data.transform_keys(&:to_s) if data.is_a?(Hash)
    return false unless data.is_a?(Hash)

    # Must have content
    return false unless data.key?('content')

    # Must have sender, speaker, or character info
    data.key?('sender') || data.key?('speaker') || data.key?('character_name')
  end

  failure_message do |data|
    data = data.transform_keys(&:to_s) if data.is_a?(Hash)
    missing = []
    missing << 'content' unless data.key?('content')
    missing << 'sender/speaker/character_name' unless data.key?('sender') || data.key?('speaker') || data.key?('character_name')
    "Expected message to have required fields, but missing: #{missing.join(', ')}"
  end
end

# Verify disambiguation response contract
RSpec::Matchers.define :have_disambiguation_contract do
  match do |data|
    data = data.transform_keys(&:to_s) if data.is_a?(Hash)
    return false unless data.is_a?(Hash)

    data.key?('query') &&
      data.key?('matches') &&
      data['matches'].is_a?(Array) &&
      data['matches'].all? do |m|
        m = m.transform_keys(&:to_s) if m.is_a?(Hash)
        m.key?('key') && m.key?('label')
      end
  end

  failure_message do |data|
    data = data.transform_keys(&:to_s) if data.is_a?(Hash)
    missing = []
    missing << 'query' unless data.key?('query')
    missing << 'matches array' unless data.key?('matches') && data['matches'].is_a?(Array)

    if data['matches'].is_a?(Array)
      data['matches'].each_with_index do |m, i|
        m = m.transform_keys(&:to_s) if m.is_a?(Hash)
        missing << "matches[#{i}].key" unless m.key?('key')
        missing << "matches[#{i}].label" unless m.key?('label')
      end
    end

    "Expected disambiguation response to have required fields, but missing: #{missing.join(', ')}"
  end
end

# Verify error response has proper structure
RSpec::Matchers.define :have_error_contract do
  match do |data|
    data = data.transform_keys(&:to_s) if data.is_a?(Hash)
    return false unless data.is_a?(Hash)

    # Must have success: false and either error message or description
    data['success'] == false &&
      (data.key?('error') || data.key?('message') || data.key?('description'))
  end

  failure_message do |data|
    data = data.transform_keys(&:to_s) if data.is_a?(Hash)
    issues = []
    issues << 'success should be false' unless data['success'] == false
    issues << 'missing error/message/description' unless data.key?('error') || data.key?('message') || data.key?('description')
    "Expected error response to have proper structure: #{issues.join(', ')}"
  end
end

# Contract definitions for reference
module ApiContracts
  ROOM_DISPLAY = {
    required_top_level: %i[type data],
    required_room_fields: %i[id name description],
    required_exit_fields: %i[direction to_room_name distance direction_arrow],
    required_character_fields: %i[id name short_desc]
  }.freeze

  CHARACTER_DISPLAY = {
    required_fields: %i[name short_desc],
    optional_fields: %i[profile_pic_url descriptions clothing held_items thumbnails]
  }.freeze

  DISAMBIGUATION = {
    required_fields: %i[query matches callback_command],
    required_match_fields: %i[key type label]
  }.freeze

  QUICKMENU = {
    required_fields: %i[prompt options interaction_id],
    required_option_fields: %i[key label],
    optional_option_fields: %i[description]
  }.freeze

  FORM = {
    required_fields: %i[title fields interaction_id],
    required_field_fields: %i[name label],
    optional_field_fields: %i[type required default options placeholder min max pattern]
  }.freeze
end
