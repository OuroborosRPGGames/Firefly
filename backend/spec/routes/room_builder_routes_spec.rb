# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Room Builder API Routes', type: :request do
  let(:admin) { create(:user, :admin) }
  let(:room) { create(:room, location: create(:location)) }

  before do
    env 'rack.session', { 'user_id' => admin.id }
  end

  describe 'POST /admin/room_builder/:id/api/features' do
    it 'returns JSON error instead of crashing when service raises StandardError' do
      allow(RoomBuilderService).to receive(:create_feature).and_raise(StandardError, 'boom')

      post "/admin/room_builder/#{room.id}/api/features",
           '{"name":"Test","feature_type":"door","orientation":"north"}',
           'CONTENT_TYPE' => 'application/json'

      # Must be JSON, not HTML Puma error page
      expect(last_response.content_type).to include('application/json')
      parsed = JSON.parse(last_response.body)
      expect(parsed['success']).to be false
      expect(parsed['error']).to eq('boom')
    end

    it 'creates a feature with valid data' do
      fake_feature = { id: 99, name: 'Front Door', feature_type: 'door' }
      allow(RoomBuilderService).to receive(:create_feature)
        .and_return({ success: true, feature: fake_feature })

      post "/admin/room_builder/#{room.id}/api/features",
           '{"name":"Front Door","feature_type":"door","orientation":"north"}',
           'CONTENT_TYPE' => 'application/json'

      expect(last_response).to be_ok
      parsed = JSON.parse(last_response.body)
      expect(parsed['success']).to be true
      expect(parsed['feature']).not_to be_nil
    end

    it 'returns JSON error on invalid JSON body' do
      post "/admin/room_builder/#{room.id}/api/features",
           'not-valid-json',
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.content_type).to include('application/json')
      parsed = JSON.parse(last_response.body)
      expect(parsed['success']).to be false
    end
  end

  describe 'PUT /admin/room_builder/:id/api/features/:feature_id' do
    let!(:feature) do
      RoomFeature.create(
        room_id: room.id,
        name: 'Old Door',
        feature_type: 'door',
        x: 0, y: 0, z: 0,
        width: 3.0, height: 7.0,
        orientation: 'north',
        open_state: 'closed',
        transparency_state: 'opaque',
        visibility_state: 'both_ways',
        allows_movement: true,
        allows_sight: true,
        has_curtains: false,
        curtain_state: 'open',
        sight_reduction: 0.0
      )
    end

    it 'returns JSON error instead of crashing when service raises StandardError' do
      allow(RoomBuilderService).to receive(:update_feature).and_raise(StandardError, 'update boom')

      put "/admin/room_builder/#{room.id}/api/features/#{feature.id}",
          '{"name":"New Door"}',
          'CONTENT_TYPE' => 'application/json'

      expect(last_response.content_type).to include('application/json')
      parsed = JSON.parse(last_response.body)
      expect(parsed['success']).to be false
      expect(parsed['error']).to eq('update boom')
    end

    it 'updates a feature with valid data' do
      fake_feature = { id: feature.id, name: 'Updated Door', feature_type: 'door' }
      allow(RoomBuilderService).to receive(:update_feature)
        .and_return({ success: true, feature: fake_feature })

      put "/admin/room_builder/#{room.id}/api/features/#{feature.id}",
          '{"name":"Updated Door"}',
          'CONTENT_TYPE' => 'application/json'

      expect(last_response).to be_ok
      parsed = JSON.parse(last_response.body)
      expect(parsed['success']).to be true
    end
  end

  describe 'POST /admin/room_builder/:id/api/decorations' do
    it 'returns JSON error instead of crashing when service raises StandardError' do
      allow(RoomBuilderService).to receive(:create_decoration).and_raise(StandardError, 'decoration boom')

      post "/admin/room_builder/#{room.id}/api/decorations",
           '{"name":"Test Decoration"}',
           'CONTENT_TYPE' => 'application/json'

      expect(last_response.content_type).to include('application/json')
      parsed = JSON.parse(last_response.body)
      expect(parsed['success']).to be false
      expect(parsed['error']).to eq('decoration boom')
    end

    it 'creates a decoration with valid data' do
      post "/admin/room_builder/#{room.id}/api/decorations",
           '{"name":"Wall Tapestry","description":"A colorful tapestry"}',
           'CONTENT_TYPE' => 'application/json'

      expect(last_response).to be_ok
      parsed = JSON.parse(last_response.body)
      expect(parsed['success']).to be true
      expect(parsed['decoration']).not_to be_nil
    end
  end

  describe 'PUT /admin/room_builder/:id/api/decorations/:dec_id' do
    let!(:decoration) do
      Decoration.create(
        room_id: room.id,
        name: 'Old Tapestry',
        display_order: 1
      )
    end

    it 'returns JSON error instead of crashing when service raises StandardError' do
      allow(RoomBuilderService).to receive(:update_decoration).and_raise(StandardError, 'dec update boom')

      put "/admin/room_builder/#{room.id}/api/decorations/#{decoration.id}",
          '{"name":"New Tapestry"}',
          'CONTENT_TYPE' => 'application/json'

      expect(last_response.content_type).to include('application/json')
      parsed = JSON.parse(last_response.body)
      expect(parsed['success']).to be false
      expect(parsed['error']).to eq('dec update boom')
    end

    it 'updates a decoration with valid data' do
      put "/admin/room_builder/#{room.id}/api/decorations/#{decoration.id}",
          '{"name":"Updated Tapestry"}',
          'CONTENT_TYPE' => 'application/json'

      expect(last_response).to be_ok
      parsed = JSON.parse(last_response.body)
      expect(parsed['success']).to be true
    end
  end

  describe 'DELETE /admin/room_builder/:id/api/features/:feature_id' do
    let!(:feature) do
      RoomFeature.create(
        room_id: room.id,
        name: 'Door',
        feature_type: 'door',
        x: 0, y: 0, z: 0,
        width: 3.0, height: 7.0,
        orientation: 'north',
        open_state: 'closed',
        transparency_state: 'opaque',
        visibility_state: 'both_ways',
        allows_movement: true,
        allows_sight: true,
        has_curtains: false,
        curtain_state: 'open',
        sight_reduction: 0.0
      )
    end

    it 'invalidates room exit cache when deleting a feature' do
      allow(RoomExitCacheService).to receive(:invalidate_location!)

      delete "/admin/room_builder/#{room.id}/api/features/#{feature.id}"

      expect(last_response).to be_ok
      expect(RoomExitCacheService).to have_received(:invalidate_location!).with(room.location_id)
    end
  end
end
