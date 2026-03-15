# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Admin Server Restart Routes', type: :request do
  let(:admin) { create(:user, :admin) }
  let(:regular_user) { create(:user) }

  before do
    REDIS_POOL.with { |r| r.del('firefly:restart:pending') }
  end

  describe 'POST /admin/server/restart' do
    before { env 'rack.session', { 'user_id' => admin.id } }

    it 'schedules a restart for admin users' do
      allow(ServerRestartJob).to receive(:perform_async)

      post '/admin/server/restart', type: 'phased', delay: '60'

      expect(last_response).to be_redirect
    end

    it 'rejects non-admin users' do
      env 'rack.session', { 'user_id' => regular_user.id }
      post '/admin/server/restart', type: 'phased', delay: '60'

      expect(last_response).to be_redirect
      expect(last_response.location).to include('/dashboard')
    end
  end

  describe 'POST /admin/server/restart/cancel' do
    before { env 'rack.session', { 'user_id' => admin.id } }

    it 'cancels a pending restart' do
      allow(BroadcastService).to receive(:to_all)
      allow(ServerRestartJob).to receive(:perform_async)
      ServerRestartService.schedule(type: 'phased', delay: 60)

      post '/admin/server/restart/cancel'

      expect(last_response).to be_redirect
      status = ServerRestartService.status
      expect(status[:pending]).to be false
    end
  end

  describe 'GET /admin/server/restart/status' do
    before { env 'rack.session', { 'user_id' => admin.id } }

    it 'returns JSON status when no restart pending' do
      get '/admin/server/restart/status'

      expect(last_response).to be_ok
      data = JSON.parse(last_response.body)
      expect(data['pending']).to be false
    end

    it 'returns JSON status with details when restart pending' do
      allow(ServerRestartJob).to receive(:perform_async)
      ServerRestartService.schedule(type: 'full', delay: 120)

      get '/admin/server/restart/status'

      expect(last_response).to be_ok
      data = JSON.parse(last_response.body)
      expect(data['pending']).to be true
      expect(data['type']).to eq('full')
      expect(data['remaining_seconds']).to be > 0
    end
  end
end
