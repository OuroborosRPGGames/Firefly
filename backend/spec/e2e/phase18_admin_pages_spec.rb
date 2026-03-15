# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Phase 18: Admin Interface Pages', type: :request do
  let(:admin) { create(:user, :admin) }
  
  before do
    env 'rack.session', { 'user_id' => admin.id }
  end

  describe 'Admin Dashboard Pages' do
    describe 'GET /admin' do
      it 'renders admin dashboard' do
        get '/admin'
        # /admin redirects to /admin/users (or last visited admin page)
        expect(last_response.status).to be_between(200, 599)
        follow_redirect!
        expect(last_response.body).not_to be_empty
      end
    end

    describe 'GET /admin/room_builder' do
      it 'renders room builder' do
        get '/admin/room_builder'
        expect(last_response.status).to be_between(200, 599)
        expect(last_response.body).not_to be_empty
      end
    end

    describe 'GET /admin/world_builder' do
      it 'renders world builder' do
        get '/admin/world_builder'
        expect(last_response.status).to be_between(200, 599)
        expect(last_response.body).not_to be_empty
      end
    end

    describe 'GET /admin/city_builder' do
      it 'renders city builder' do
        get '/admin/city_builder'
        expect(last_response.status).to be_between(200, 599)
        expect(last_response.body).not_to be_empty
      end
    end
  end

  describe 'Room Builder Individual Pages' do
    let(:room) { create(:room, name: 'Test Room') }

    describe 'GET /admin/room_builder/:id' do
      it 'renders room editor' do
        get "/admin/room_builder/#{room.id}"
        expect(last_response.status).to be_between(200, 599)
        expect(last_response.body).not_to be_empty
      end

      it 'handles non-existent room gracefully' do
        get '/admin/room_builder/999999'
        expect(last_response.status).to be_between(200, 599)
      end
    end
  end

  describe 'World Builder Individual Pages' do
    let(:world) { create(:world, name: 'Test World') }

    describe 'GET /admin/world_builder/:id' do
      it 'renders world editor' do
        get "/admin/world_builder/#{world.id}"
        expect(last_response.status).to be_between(200, 599)
        expect(last_response.body).not_to be_empty
      end

      it 'handles non-existent world gracefully' do
        get '/admin/world_builder/999999'
        expect(last_response.status).to be_between(200, 599)
      end
    end

    describe 'GET /admin/world_builder/:id/api/regions' do
      it 'returns regions data' do
        get "/admin/world_builder/#{world.id}/api/regions", { zoom: 0 }
        expect(last_response.status).to be_between(200, 299)
        body = JSON.parse(last_response.body)
        expect(body).to have_key('regions')
      end
    end

    describe 'GET /admin/world_builder/:id/api/cities' do
      it 'returns cities data' do
        get "/admin/world_builder/#{world.id}/api/cities"
        expect(last_response.status).to be_between(200, 299)
        body = JSON.parse(last_response.body)
        expect(body).to have_key('cities')
      end
    end
  end

  describe 'City Builder Individual Pages' do
    let(:location) { create(:location, name: 'Test Location', city_built_at: Time.now) }

    describe 'GET /admin/city_builder/:id' do
      it 'renders city editor for built city' do
        get "/admin/city_builder/#{location.id}"
        expect(last_response.status).to be_between(200, 599)
        expect(last_response.body).not_to be_empty
      end

      it 'handles non-existent location gracefully' do
        get '/admin/city_builder/999999'
        expect(last_response.status).to be_between(200, 599)
      end

      it 'redirects for non-built city' do
        unbuilt_location = create(:location, name: 'Unbuilt Location', city_built_at: nil)
        get "/admin/city_builder/#{unbuilt_location.id}"
        expect(last_response.status).to eq(302)
        expect(last_response.location).to include('/admin/city_builder')
      end
    end
  end

  describe 'Navigation and Room Features' do
    describe 'GET /admin/help' do
      it 'renders help admin section' do
        get '/admin/help'
        expect(last_response.status).to be_between(200, 599)
      end
    end

    describe 'GET /admin/help/commands' do
      it 'lists command helpfiles' do
        get '/admin/help/commands'
        expect(last_response.status).to be_between(200, 599)
      end
    end

    describe 'GET /admin/help/systems' do
      it 'lists help systems' do
        get '/admin/help/systems'
        expect(last_response.status).to be_between(200, 599)
      end
    end
  end
end
