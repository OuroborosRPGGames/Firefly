# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'TTS API Routes', type: :request do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:reality) { create(:reality) }
  let(:room) { create(:room) }
  let(:character_instance) do
    create(:character_instance, character: character, reality: reality, current_room: room, online: true)
  end

  def auth_headers
    token = user.generate_api_token!
    character_instance
    { 'HTTP_AUTHORIZATION' => "Bearer #{token}", 'CONTENT_TYPE' => 'application/json' }
  end

  describe 'GET /api/tts/voices' do
    before do
      allow(TtsService).to receive(:available_voices).and_return([
        { id: 'alloy', name: 'Alloy' },
        { id: 'echo', name: 'Echo' }
      ])
    end

    it 'returns available voices' do
      get '/api/tts/voices'
      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json['success']).to be true
      expect(json['voices']).to be_an(Array)
    end
  end

  describe 'POST /api/tts/preview' do
    before do
      allow(TtsService).to receive(:valid_voice?).and_return(true)
      allow(TtsService).to receive(:generate_preview).and_return({
        success: true,
        data: { audio_url: 'https://example.com/audio.mp3' }
      })
    end

    it 'requires voice_type' do
      post '/api/tts/preview', { voice_speed: 1.0 }.to_json, auth_headers
      expect(last_response.status).to eq(400)
      json = JSON.parse(last_response.body)
      expect(json['error']).to include('voice_type')
    end

    it 'validates voice exists' do
      allow(TtsService).to receive(:valid_voice?).and_return(false)

      post '/api/tts/preview', { voice_type: 'invalid' }.to_json, auth_headers
      expect(last_response.status).to eq(400)
      json = JSON.parse(last_response.body)
      expect(json['error']).to include('Unknown voice')
    end

    it 'generates preview with valid voice' do
      post '/api/tts/preview', {
        voice_type: 'alloy',
        voice_speed: 1.0,
        voice_pitch: 0.0
      }.to_json, auth_headers

      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json['success']).to be true
      expect(json['audio_url']).not_to be_nil
    end

    it 'handles TTS failure' do
      allow(TtsService).to receive(:generate_preview).and_return({
        success: false,
        error: 'TTS service unavailable'
      })

      post '/api/tts/preview', { voice_type: 'alloy' }.to_json, auth_headers
      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json['success']).to be false
    end

    it 'handles invalid JSON' do
      post '/api/tts/preview', 'not json', auth_headers
      expect(last_response.status).to eq(400)
    end
  end
end
