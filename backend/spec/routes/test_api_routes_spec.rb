# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Test API Routes', type: :request do
  let(:user) { create(:user, :admin) }
  let(:character) { create(:character, user: user) }
  let(:reality) { create(:reality) }
  let(:room) { create(:room) }
  let(:character_instance) do
    create(:character_instance, character: character, reality: reality, current_room: room, online: true)
  end

  def api_auth_headers(token)
    { 'HTTP_AUTHORIZATION' => "Bearer #{token}", 'CONTENT_TYPE' => 'application/json' }
  end

  def auth_headers
    token = user.generate_api_token!
    character_instance
    api_auth_headers(token)
  end

  before do
    allow(GameSetting).to receive(:get_boolean).and_call_original
    allow(GameSetting).to receive(:get_boolean).with('test_account_enabled').and_return(true)
  end

  describe 'POST /api/test/session' do
    it 'returns 403 when test endpoints disabled' do
      allow(GameSetting).to receive(:get_boolean).with('test_account_enabled').and_return(false)
      post '/api/test/session', {}.to_json, { 'CONTENT_TYPE' => 'application/json' }
      expect(last_response.status).to eq(403)
    end

    it 'creates session with valid auth' do
      post '/api/test/session', {}.to_json, auth_headers
      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json['success']).to be true
      expect(json['user_id']).to eq(user.id)
    end
  end

  describe 'POST /api/test/render' do
    it 'returns 403 when test endpoints disabled' do
      allow(GameSetting).to receive(:get_boolean).with('test_account_enabled').and_return(false)
      post '/api/test/render', { path: '/admin' }.to_json, { 'CONTENT_TYPE' => 'application/json' }
      expect(last_response.status).to eq(403)
    end

    it 'returns path info with valid auth' do
      post '/api/test/render', { path: '/admin' }.to_json, auth_headers
      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json['success']).to be true
      expect(json['path']).to eq('/admin')
    end

    it 'handles invalid JSON' do
      post '/api/test/render', 'not json', auth_headers
      expect(last_response.status).to eq(400)
    end
  end
end
