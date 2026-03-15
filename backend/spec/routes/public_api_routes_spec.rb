# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Public API Routes', type: :request do
  describe 'World Map API' do
    let(:universe) { create(:universe) }
    let(:world) { create(:world, universe: universe) }

    describe 'GET /api/world/:id/map' do
      it 'returns world map data with cities' do
        get "/api/world/#{world.id}/map"
        expect(last_response).to be_ok
        json = JSON.parse(last_response.body)
        expect(json['success']).to be true
        expect(json['world']).to be_a(Hash)
        expect(json['cities']).to be_an(Array)
      end

      it 'returns 404 for non-existent world' do
        get '/api/world/999999/map'
        expect(last_response.status).to eq(404)
        json = JSON.parse(last_response.body)
        expect(json['success']).to be false
      end
    end

    describe 'GET /api/world/:id/nearest_hex' do
      it 'returns nearest hex for valid coordinates' do
        get "/api/world/#{world.id}/nearest_hex", { lat: 40.0, lng: -74.0 }
        expect(last_response).to be_ok
        json = JSON.parse(last_response.body)
        expect(json['success']).to be true
      end

      it 'returns 400 without lat/lng parameters' do
        get "/api/world/#{world.id}/nearest_hex"
        expect(last_response.status).to eq(400)
      end
    end

    describe 'GET /world/:id' do
      it 'renders globe view' do
        get "/world/#{world.id}"
        expect(last_response).to be_ok
      end

      it 'redirects for non-existent world' do
        get '/world/999999'
        expect(last_response).to be_redirect
        expect(last_response.location).to include('/world')
      end
    end
  end

  describe 'Body Positions API' do
    describe 'GET /api/body-positions' do
      before do
        # Create some body positions
        %w[head torso arm leg].each_with_index do |region, i|
          BodyPosition.find_or_create(label: "test_#{region}", region: region) do |bp|
            bp.display_order = i
            bp.is_private = false
          end
        end
      end

      it 'returns body positions grouped by region' do
        get '/api/body-positions'
        expect(last_response).to be_ok
        json = JSON.parse(last_response.body)
        expect(json['success']).to be true
        expect(json['positions']).to be_a(Hash)
      end
    end
  end

  describe 'Profiles API' do
    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }

    describe 'GET /profiles' do
      it 'renders profiles index' do
        get '/profiles'
        expect(last_response).to be_ok
      end

      it 'accepts page parameter' do
        get '/profiles', { page: 1 }
        expect(last_response).to be_ok
      end

      it 'accepts search parameter' do
        get '/profiles', { search: 'test' }
        expect(last_response).to be_ok
      end

      it 'accepts online filter' do
        get '/profiles', { online: '1' }
        expect(last_response).to be_ok
      end
    end
  end

end
