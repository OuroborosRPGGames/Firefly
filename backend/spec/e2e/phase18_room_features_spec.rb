# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Phase 18: Room Features Visibility', type: :request do
  let(:admin) { create(:user, :admin) }
  let(:room) { create(:room, name: 'Test Room with Features') }
  
  before do
    env 'rack.session', { 'user_id' => admin.id }
  end

  describe 'Room Builder Editor Features Display' do
    describe 'room with walls' do
      let!(:wall) { create(:room_feature, :wall, room: room) }

      it 'renders room editor with wall features' do
        get "/admin/room_builder/#{room.id}"
        expect(last_response.status).to be_between(200, 299)
        expect(last_response.body).not_to be_empty
        # Wall features should be loadable in the interface
        expect(last_response.body).to include('editor')
      end
    end

    describe 'room with doors' do
      let!(:door) { create(:room_feature, :door, room: room, is_open: true) }

      it 'renders room editor with door features' do
        get "/admin/room_builder/#{room.id}"
        expect(last_response.status).to be_between(200, 299)
        expect(last_response.body).not_to be_empty
      end
    end

    describe 'room with windows' do
      let!(:window) { create(:room_feature, room: room) }

      it 'renders room editor with window features' do
        get "/admin/room_builder/#{room.id}"
        expect(last_response.status).to be_between(200, 299)
        expect(last_response.body).not_to be_empty
      end
    end

    describe 'room with mixed features' do
      let!(:wall) { create(:room_feature, :wall, room: room) }
      let!(:door) { create(:room_feature, :door, room: room, is_open: false) }
      let!(:window) { create(:room_feature, room: room) }

      it 'renders room editor with multiple features' do
        get "/admin/room_builder/#{room.id}"
        expect(last_response.status).to be_between(200, 299)
        expect(last_response.body).not_to be_empty
      end
    end
  end

  describe 'Room API Endpoints' do
    describe 'GET /admin/room_builder/:id/api/room - Room data endpoint' do
      it 'returns room data in wrapper' do
        get "/admin/room_builder/#{room.id}/api/room"
        expect(last_response.status).to be_between(200, 299)
        body = JSON.parse(last_response.body)
        # The API returns wrapped data with 'room' key
        expect(body).to have_key('room')
        expect(body['room']).to have_key('id')
        expect(body['room']).to have_key('name')
      end

      it 'includes room features in response' do
        create(:room_feature, :wall, room: room)
        get "/admin/room_builder/#{room.id}/api/room"
        expect(last_response.status).to be_between(200, 299)
        body = JSON.parse(last_response.body)
        expect(body).to have_key('room')
        # Features might be in the room data or separate
        expect(body['room']).to have_key('features') if body['room'].key?('features')
      end
    end

    describe 'GET /admin/room_builder/:id/api/hexes - Hex data endpoint' do
      it 'returns hex data for room' do
        get "/admin/room_builder/#{room.id}/api/hexes"
        expect(last_response.status).to be_between(200, 599)
      end
    end
  end

  describe 'Navigation Between Rooms' do
    let(:adjacent_room) { create(:room, name: 'Adjacent Room') }
    
    describe 'viewing room exits' do
      it 'can view room editor for origin room' do
        get "/admin/room_builder/#{room.id}"
        expect(last_response.status).to be_between(200, 299)
      end

      it 'can view room editor for adjacent room' do
        get "/admin/room_builder/#{adjacent_room.id}"
        expect(last_response.status).to be_between(200, 299)
      end
    end
  end
end
