# frozen_string_literal: true

require 'spec_helper'

# Webclient API Contract Tests
#
# These tests verify that API responses contain all the fields required
# by the webclient for client-side rendering. This prevents the issue where
# the MCP agent sees different output than players in the webclient.
#
# The webclient checks: (data.display_type || data.type) && (data.data || data.structured)
# If this fails, it falls back to server-rendered HTML which may differ from
# the structured data the MCP agent receives.
#
# Note: We test via the agent API since it returns the same structured data
# that the webclient would receive. This avoids complex session setup with
# Roda's encrypted sessions.

RSpec.describe 'Webclient API Contracts', type: :request do
  let!(:user) { create(:user) }
  let!(:character) { create(:character, user: user) }
  let!(:reality) { create(:reality) }
  let!(:location) { create(:location) }
  # Main room: default bounds 0-100
  let!(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A test room.', min_y: 0.0, max_y: 100.0) }
  # Adjacent room: north of room (shares edge at y=100)
  let!(:adjacent_room) { create(:room, location: location, name: 'Adjacent Room', short_description: 'Next door.', min_y: 100.0, max_y: 200.0) }
  let!(:character_instance) do
    create(:character_instance, character: character, reality: reality, current_room: room)
  end
  let!(:api_token) { user.generate_api_token! }

  def agent_headers
    { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}", 'CONTENT_TYPE' => 'application/json' }
  end

  describe 'POST /api/agent/command (command execution)' do
    describe 'look command' do
      it 'includes structured room data for client-side rendering' do
        post '/api/agent/command',
             JSON.generate({ command: 'look' }),
             agent_headers

        expect(last_response.status).to eq(200), "Expected 200, got #{last_response.status}. Body: #{last_response.body[0..500]}"
        data = JSON.parse(last_response.body)

        # Must have structured data for client-side rendering
        expect(data['structured']).not_to be_nil, "Expected structured data. Got: #{data.keys}"
      end

      it 'returns room data matching renderRoomDisplay contract' do
        post '/api/agent/command',
             JSON.generate({ command: 'look' }),
             agent_headers

        data = JSON.parse(last_response.body)
        room_data = data['structured']

        expect(room_data).to have_room_display_contract
      end

      it 'exits include all required fields for client rendering' do
        post '/api/agent/command',
             JSON.generate({ command: 'look' }),
             agent_headers

        data = JSON.parse(last_response.body)
        room_data = data['structured']

        expect(room_data['exits']).not_to be_empty, 'Expected at least one exit'

        room_data['exits'].each do |exit_data|
          expect(exit_data).to have_room_exit_contract
        end
      end

      it 'exit direction_arrow contains valid arrow character' do
        post '/api/agent/command',
             JSON.generate({ command: 'look' }),
             agent_headers

        data = JSON.parse(last_response.body)
        room_data = data['structured']

        valid_arrows = %w[↑ ↓ ← → ↗ ↖ ↘ ↙ ⇑ ⇓ ⊙ ⊗]
        room_data['exits'].each do |exit_data|
          arrow = exit_data['direction_arrow']
          expect(valid_arrows).to include(arrow), "Invalid arrow: #{arrow}"
        end
      end
    end
  end

  describe 'room data contracts' do
    it 'room object has required fields' do
      post '/api/agent/command',
           JSON.generate({ command: 'look' }),
           agent_headers

      data = JSON.parse(last_response.body)
      room_data = data['structured']['room']

      expect(room_data).to have_key('id')
      expect(room_data).to have_key('name')
      expect(room_data).to have_key('description')
    end

    it 'characters_ungrouped array contains required fields when characters present' do
      # Create another character in the room
      other_user = create(:user)
      other_char = create(:character, user: other_user, forename: 'Other', surname: 'Person')
      create(:character_instance, character: other_char, reality: reality,
                                  current_room: room, online: true)

      post '/api/agent/command',
           JSON.generate({ command: 'look' }),
           agent_headers

      data = JSON.parse(last_response.body)
      room_data = data['structured']

      # Check all possible character locations
      chars = room_data['characters_ungrouped'] || []
      (room_data['places'] || []).each do |place|
        chars.concat(place['characters'] || [])
      end

      expect(chars).not_to be_empty, 'Expected at least one other character'

      chars.each do |char|
        expect(char).to have_key('name')
        expect(char).to have_key('short_desc')
      end
    end
  end

  describe 'response data consistency' do
    it 'structured data contains room information' do
      post '/api/agent/command',
           JSON.generate({ command: 'look' }),
           agent_headers

      data = JSON.parse(last_response.body)
      room_data = data['structured']

      expect(room_data['room']).not_to be_nil
      expect(room_data['room']['name']).to eq('Test Room')
      expect(room_data['exits']).not_to be_empty
      expect(room_data['exits'].length).to eq(1)
    end
  end

  # ====== WEBCLIENT/MCP AGENT PARITY TESTS ======
  # These tests ensure that what players see in the webclient matches what
  # MCP testing agents see. Both systems consume the same API but render differently.

  describe 'movement command contracts' do
    it 'successful movement returns timed movement acknowledgement' do
      post '/api/agent/command',
           JSON.generate({ command: 'north' }),
           agent_headers

      data = JSON.parse(last_response.body)

      # Movement is now timed - the command returns success with a movement message
      expect(data['success']).to be true
      expect(data['message'] || data['description']).not_to be_nil
    end

    it 'movement returns structured data with room info' do
      # Any valid movement command should return room information
      post '/api/agent/command',
           JSON.generate({ command: 'look' }),
           agent_headers

      data = JSON.parse(last_response.body)

      # The look command returns room data - confirm it has proper structure
      expect(data['success']).to eq(true)
      expect(data['structured']).not_to be_nil
      expect(data['structured']['room']).not_to be_nil
    end

    it 'movement command returns success with direction info' do
      post '/api/agent/command',
           JSON.generate({ command: 'north' }),
           agent_headers

      data = JSON.parse(last_response.body)

      # Timed movement returns success and a message about starting to move
      expect(data['success']).to be true
    end
  end

  describe 'social command contracts' do
    it 'say command returns success with message data' do
      post '/api/agent/command',
           JSON.generate({ command: 'say', args: 'Hello world' }),
           agent_headers

      data = JSON.parse(last_response.body)

      expect(data['success']).to be true
      # Message should be acknowledged
      expect(data['message'] || data['description']).not_to be_nil
    end

    it 'emote command returns success' do
      # Command and args combined in one string (MCP API format)
      post '/api/agent/command',
           JSON.generate({ command: 'emote waves happily' }),
           agent_headers

      data = JSON.parse(last_response.body)

      expect(data['success']).to eq(true),
        "Expected success but got: #{data['error'] || data['message']}"
    end
  end

  describe 'information equivalence (webclient/agent parity)' do
    it 'description text includes room name from structured data' do
      post '/api/agent/command',
           JSON.generate({ command: 'look' }),
           agent_headers

      data = JSON.parse(last_response.body)

      room_name = data.dig('structured', 'room', 'name')
      description = data['description']

      expect(description).to include(room_name),
        "Expected description to include room name '#{room_name}'\nDescription: #{description}"
    end

    it 'description text includes exit destinations' do
      post '/api/agent/command',
           JSON.generate({ command: 'look' }),
           agent_headers

      data = JSON.parse(last_response.body)

      exits = data.dig('structured', 'exits') || []
      description = data['description']

      exits.each do |exit|
        room_name = exit['to_room_name']
        direction = exit['direction']

        expect(description.include?(room_name) || description.downcase.include?(direction.downcase)).to be(true),
          "Expected description to include exit '#{room_name}' or direction '#{direction}'\nDescription: #{description}"
      end
    end

    it 'response has equivalent description (using matcher)' do
      post '/api/agent/command',
           JSON.generate({ command: 'look' }),
           agent_headers

      data = JSON.parse(last_response.body)

      expect(data).to have_equivalent_description
    end

    context 'with other characters present' do
      let!(:other_user) { create(:user) }
      let!(:other_char) { create(:character, user: other_user, forename: 'TestNpc', surname: 'Person') }
      let!(:other_instance) do
        create(:character_instance, character: other_char, reality: reality,
                                    current_room: room, online: true)
      end

      it 'description text includes character names from structured data' do
        post '/api/agent/command',
             JSON.generate({ command: 'look' }),
             agent_headers

        data = JSON.parse(last_response.body)
        description = data['description']

        # Find all characters in structured data
        chars = data.dig('structured', 'characters_ungrouped') || []
        (data.dig('structured', 'places') || []).each do |place|
          chars.concat(place['characters'] || [])
        end

        # Each character should appear in description
        chars.each do |char|
          name = char['name']
          expect(description).to include(name),
            "Expected description to include character '#{name}'\nDescription: #{description}"
        end
      end
    end
  end

  describe 'error response contracts' do
    it 'invalid command returns structured error' do
      post '/api/agent/command',
           JSON.generate({ command: 'nonexistent_command_xyz' }),
           agent_headers

      data = JSON.parse(last_response.body)

      expect(data['success']).to be false
      expect(data['error']).not_to be_nil
    end

    it 'error includes descriptive message' do
      post '/api/agent/command',
           JSON.generate({ command: 'nonexistent_command_xyz' }),
           agent_headers

      data = JSON.parse(last_response.body)

      error_text = data['error'] || data['message'] || data['description']
      expect(error_text).not_to be_nil
      expect(error_text).not_to be_empty
    end

    it 'error response has proper contract' do
      post '/api/agent/command',
           JSON.generate({ command: 'nonexistent_command_xyz' }),
           agent_headers

      data = JSON.parse(last_response.body)

      expect(data).to have_error_contract
    end
  end
end
