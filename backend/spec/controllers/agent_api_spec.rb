# frozen_string_literal: true

require 'spec_helper'

RSpec.describe "Agent API Routes" do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:reality) { create(:reality) }
  let(:room) { create(:room) }
  let(:character_instance) do
    create(:character_instance, character: character, reality: reality, current_room: room)
  end

  describe "Bearer token authentication" do
    let!(:api_token) { user.generate_api_token! }

    before do
      character_instance # ensure instance exists
    end

    it "authenticates with valid token" do
      get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}" }
      expect(last_response.status).to eq(200)

      data = JSON.parse(last_response.body)
      expect(data['success']).to be true
    end

    it "rejects invalid token" do
      get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer invalid_token" }
      expect(last_response.status).to eq(401)

      data = JSON.parse(last_response.body)
      expect(data['success']).to be false
      expect(data['error']).to eq('Unauthorized')
    end

    it "rejects expired token" do
      user.update(api_token_expires_at: Time.now - 1)

      get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}" }
      expect(last_response.status).to eq(401)
    end

    it "sanitizes error messages" do
      get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer bad" }
      expect(last_response.status).to eq(401)

      data = JSON.parse(last_response.body)
      # Should not reveal details about why auth failed
      expect(data['error']).to eq('Unauthorized')
    end

    it "handles token with extra whitespace" do
      get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer  #{api_token}  " }
      expect(last_response.status).to eq(200)
    end

    it "updates last_used_at on successful auth" do
      expect(user.api_token_last_used_at).to be_nil

      get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}" }
      expect(last_response.status).to eq(200)

      user.reload
      expect(user.api_token_last_used_at).not_to be_nil
    end
  end

  describe "GET /api/agent/room" do
    let!(:api_token) { user.generate_api_token! }

    before do
      character_instance
    end

    it "returns room state with exits and characters" do
      get '/api/agent/room', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}" }
      expect(last_response.status).to eq(200)

      data = JSON.parse(last_response.body)
      expect(data['success']).to be true
      expect(data['room']['id']).to eq(room.id)
      expect(data['room']['name']).to eq(room.name)
      expect(data).to have_key('exits')
      expect(data).to have_key('characters')
    end
  end

  describe "GET /api/agent/status" do
    let!(:api_token) { user.generate_api_token! }

    before do
      character_instance
    end

    it "returns character status" do
      get '/api/agent/status', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}" }
      expect(last_response.status).to eq(200)

      data = JSON.parse(last_response.body)
      expect(data['success']).to be true
      expect(data).to have_key('character')
      expect(data).to have_key('instance')
    end
  end

  describe "GET /api/agent/commands" do
    let!(:api_token) { user.generate_api_token! }

    before do
      character_instance
    end

    it "returns available commands" do
      get '/api/agent/commands', {}, { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}" }
      expect(last_response.status).to eq(200)

      data = JSON.parse(last_response.body)
      expect(data['success']).to be true
      expect(data).to have_key('commands')
      expect(data['commands']).to be_an(Array)
    end
  end

  describe "POST /api/agent/command" do
    let!(:api_token) { user.generate_api_token! }

    before do
      character_instance
    end

    it "executes look command" do
      post '/api/agent/command',
           JSON.generate({ command: 'look' }),
           { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}", 'CONTENT_TYPE' => 'application/json' }

      expect(last_response.status).to eq(200)

      data = JSON.parse(last_response.body)
      expect(data['success']).to be true
    end

    it "rejects empty command" do
      post '/api/agent/command',
           JSON.generate({ command: '' }),
           { 'HTTP_AUTHORIZATION' => "Bearer #{api_token}", 'CONTENT_TYPE' => 'application/json' }

      data = JSON.parse(last_response.body)
      expect(data['success']).to be false
    end
  end
end
