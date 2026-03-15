# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Fight Routes', type: :request do
  include Rack::Test::Methods

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:room) { create(:room) }
  let!(:character_instance) do
    create(:character_instance, character: character, current_room: room, online: true)
  end
  let!(:fight) { create(:fight, room: room, status: 'input') }
  let!(:participant) do
    create(:fight_participant, fight: fight, character_instance: character_instance, side: 1)
  end

  before do
    env 'rack.session', {
      'user_id' => user.id,
      'character_id' => character.id,
      'character_instance_id' => character_instance.id
    }
  end

  describe 'POST /api/fight/action' do
    it 'rejects actions while round is resolving' do
      fight.update(status: 'resolving', round_locked: true)

      header 'CONTENT_TYPE', 'application/json'
      post '/api/fight/action', { action: 'pass', value: nil }.to_json

      expect(last_response.status).to eq(400)
      body = JSON.parse(last_response.body)
      expect(body['success']).to be false
      expect(body['code']).to eq('round_resolving')
    end

    it 'rejects actions when combat input is closed' do
      fight.update(status: 'narrative', round_locked: false)

      header 'CONTENT_TYPE', 'application/json'
      post '/api/fight/action', { action: 'pass', value: nil }.to_json

      expect(last_response.status).to eq(400)
      body = JSON.parse(last_response.body)
      expect(body['success']).to be false
      expect(body['code']).to eq('input_closed')
    end

    it 'returns a clean validation error for malformed payloads' do
      fight.update(status: 'input', round_locked: false)

      header 'CONTENT_TYPE', 'application/json'
      post '/api/fight/action', { action: 'move_to_hex', value: 'bad-payload' }.to_json

      expect(last_response.status).to eq(400)
      body = JSON.parse(last_response.body)
      expect(body['success']).to be false
      expect(body['error']).to include('Invalid payload')
    end
  end
end
