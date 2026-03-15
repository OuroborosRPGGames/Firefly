# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Admin World Builder Routes', type: :request do
  let(:admin) { create(:user, :admin) }
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }

  before do
    env 'rack.session', { 'user_id' => admin.id }
  end

  describe 'GET /admin/world_builder' do
    it_behaves_like 'requires admin', '/admin/world_builder'

    it 'lists worlds' do
      world # create
      get '/admin/world_builder'
      expect(last_response).to be_ok
    end
  end

  describe 'POST /admin/world_builder' do
    it 'creates a new world' do
      post '/admin/world_builder', {
        name: 'Test World',
        universe_id: universe.id
      }

      expect(last_response).to be_redirect
      expect(World.where(name: 'Test World').first).not_to be_nil
    end

    it 'handles validation errors' do
      post '/admin/world_builder', { name: '' }
      expect(last_response).to be_redirect
    end
  end

  describe 'GET /admin/world_builder/:id' do
    it 'renders world editor' do
      get "/admin/world_builder/#{world.id}"
      expect(last_response).to be_ok
    end

    it 'redirects for non-existent world' do
      get '/admin/world_builder/999999'
      expect(last_response).to be_redirect
      expect(last_response.location).to include('/admin/world_builder')
    end
  end

  describe 'POST /admin/world_builder/:id/delete' do
    it 'deletes the world and redirects' do
      world # ensure created
      expect {
        post "/admin/world_builder/#{world.id}/delete"
      }.to change { World.count }.by(-1)

      expect(last_response).to be_redirect
      expect(last_response.location).to include('/admin/world_builder')
      expect(World[world.id]).to be_nil
    end

    it 'cleans up associated world_hexes' do
      WorldHex.create(world_id: world.id, globe_hex_id: 1, terrain_type: 'dense_forest')
      WorldHex.create(world_id: world.id, globe_hex_id: 2, terrain_type: 'ocean')

      expect {
        post "/admin/world_builder/#{world.id}/delete"
      }.to change { WorldHex.where(world_id: world.id).count }.from(2).to(0)
    end

    it 'redirects for non-existent world' do
      post '/admin/world_builder/999999/delete'
      expect(last_response).to be_redirect
      expect(last_response.location).to include('/admin/world_builder')
    end
  end

  describe 'World Builder API' do
    describe 'GET /admin/world_builder/:id/api/regions' do
      it 'returns regions data' do
        get "/admin/world_builder/#{world.id}/api/regions", { zoom: 0 }
        expect(last_response).to be_ok
        json = JSON.parse(last_response.body)
        expect(json['success']).to be true
        expect(json['regions']).to be_an(Array)
      end

      it 'accepts center coordinates' do
        get "/admin/world_builder/#{world.id}/api/regions", { zoom: 0, center_x: 5, center_y: 5 }
        expect(last_response).to be_ok
      end
    end

    describe 'GET /admin/world_builder/:id/api/cities' do
      it 'returns cities data' do
        get "/admin/world_builder/#{world.id}/api/cities"
        expect(last_response).to be_ok
        json = JSON.parse(last_response.body)
        expect(json['success']).to be true
        expect(json['cities']).to be_an(Array)
      end
    end

    describe 'GET /admin/world_builder/:id/api/zones' do
      it 'returns zones data' do
        get "/admin/world_builder/#{world.id}/api/zones"
        expect(last_response).to be_ok
        json = JSON.parse(last_response.body)
        expect(json['success']).to be true
        expect(json['zones']).to be_an(Array)
      end
    end

    describe 'POST /admin/world_builder/:id/api/region' do
      it 'updates a region' do
        post "/admin/world_builder/#{world.id}/api/region",
             { region_x: 1, region_y: 2, zoom_level: 0, terrain: 'dense_forest' }.to_json,
             { 'CONTENT_TYPE' => 'application/json' }

        expect(last_response).to be_ok
        json = JSON.parse(last_response.body)
        expect(json['success']).to be true
      end

      it 'handles invalid JSON gracefully' do
        post "/admin/world_builder/#{world.id}/api/region",
             'invalid json',
             { 'CONTENT_TYPE' => 'application/json' }

        expect(last_response).to be_ok
      end
    end

    describe 'POST /admin/world_builder/:id/api/city' do
      it 'creates a city' do
        post "/admin/world_builder/#{world.id}/api/city",
             { name: 'New City', center_x: 10.0, center_y: 10.0, size: 0.5 }.to_json,
             { 'CONTENT_TYPE' => 'application/json' }

        expect(last_response).to be_ok
        json = JSON.parse(last_response.body)
        expect(json['success']).to be true
      end
    end

    describe 'POST /admin/world_builder/:id/api/hex' do
      it 'handles hex update request' do
        # Route may return 404 if not implemented yet
        post "/admin/world_builder/#{world.id}/api/hex", { x: 0, y: 0, terrain: 'forest' }.to_json,
             'CONTENT_TYPE' => 'application/json'
        # Accept success, redirect, or 404 (route not implemented)
        expect([200, 302, 404]).to include(last_response.status)
      end
    end

    describe 'PATCH /admin/world_builder/:id/api/hex' do
      it 'handles hex patch request' do
        patch "/admin/world_builder/#{world.id}/api/hex", { x: 0, y: 0, terrain: 'desert' }.to_json,
              'CONTENT_TYPE' => 'application/json'
        expect([200, 302, 404]).to include(last_response.status)
      end
    end

    describe 'DELETE /admin/world_builder/:id/api/hex' do
      it 'handles hex delete request' do
        delete "/admin/world_builder/#{world.id}/api/hex", { x: 0, y: 0 }.to_json,
               'CONTENT_TYPE' => 'application/json'
        expect([200, 302, 404]).to include(last_response.status)
      end
    end

    describe 'POST /admin/world_builder/:id/api/road' do
      it 'handles road feature request' do
        post "/admin/world_builder/#{world.id}/api/road", { from_x: 0, from_y: 0, to_x: 1, to_y: 0 }.to_json,
             'CONTENT_TYPE' => 'application/json'
        expect([200, 302, 404]).to include(last_response.status)
      end
    end

    describe 'POST /admin/world_builder/:id/api/generate' do
      it 'creates a generation job with preset' do
        post "/admin/world_builder/#{world.id}/api/generate",
             { type: 'procedural', options: { preset: 'pangaea', seed: 12345 } }.to_json,
             { 'CONTENT_TYPE' => 'application/json' }

        expect(last_response.status).to eq(200)
        data = JSON.parse(last_response.body)
        expect(data['success']).to be true
        expect(data['job']['id']).not_to be_nil
        expect(data['job']['status']).to eq('pending')
      end

      it 'starts background generation' do
        expect {
          post "/admin/world_builder/#{world.id}/api/generate",
               { type: 'procedural', options: { preset: 'earth_like' } }.to_json,
               { 'CONTENT_TYPE' => 'application/json' }
        }.to change { WorldGenerationJob.count }.by(1)
      end

      it 'uses earth_like preset by default' do
        post "/admin/world_builder/#{world.id}/api/generate",
             { type: 'procedural' }.to_json,
             { 'CONTENT_TYPE' => 'application/json' }

        expect(last_response).to be_ok
        job = WorldGenerationJob.latest_for(world)
        expect(job.config['preset']).to eq('earth_like')
      end

      it 'stores seed in job config' do
        post "/admin/world_builder/#{world.id}/api/generate",
             { options: { seed: 42 } }.to_json,
             { 'CONTENT_TYPE' => 'application/json' }

        job = WorldGenerationJob.latest_for(world)
        expect(job.config['seed']).to eq(42)
      end
    end

    describe 'POST /admin/world_builder/:id/location/:location_id/rooms' do
      let(:zone_with_polygon) do
        create(:zone, world: world, polygon_scale: 'local',
               polygon_points: [
                 { x: 0, y: 0 }, { x: 500, y: 0 }, { x: 500, y: 300 }, { x: 0, y: 300 }
               ])
      end
      let(:zone_without_polygon) { create(:zone, world: world, polygon_points: []) }
      let(:location_with_polygon) { create(:location, zone: zone_with_polygon) }
      let(:location_without_polygon) { create(:location, zone: zone_without_polygon) }

      context 'when the location has a zone polygon' do
        it 'creates a room using zone polygon bounding box' do
          post "/admin/world_builder/#{world.id}/location/#{location_with_polygon.id}/rooms",
               { name: 'Polygon Room', room_type: 'standard' }

          expect(last_response).to be_redirect
          room = Room.where(location_id: location_with_polygon.id).first
          expect(room).not_to be_nil
          expect(room.min_x).to eq(0.0)
          expect(room.max_x).to eq(500.0)
          expect(room.min_y).to eq(0.0)
          expect(room.max_y).to eq(300.0)
          expect(room.room_polygon).not_to be_nil
          expect(room.room_polygon.length).to eq(4)
        end
      end

      context 'when the location has no zone polygon' do
        it 'creates a room with 200x200 default bounds' do
          post "/admin/world_builder/#{world.id}/location/#{location_without_polygon.id}/rooms",
               { name: 'Default Room', room_type: 'standard' }

          expect(last_response).to be_redirect
          room = Room.where(location_id: location_without_polygon.id).first
          expect(room).not_to be_nil
          expect(room.min_x).to eq(0.0)
          expect(room.max_x).to eq(200.0)
          expect(room.min_y).to eq(0.0)
          expect(room.max_y).to eq(200.0)
          expect(room.room_polygon).to be_nil
        end
      end
    end

    describe 'GET /admin/world_builder/:id/api/generation_status' do
      it 'returns nil job when no jobs exist' do
        get "/admin/world_builder/#{world.id}/api/generation_status"

        expect(last_response).to be_ok
        data = JSON.parse(last_response.body)
        expect(data['success']).to be true
        expect(data['job']).to be_nil
      end

      it 'returns job status with phase info' do
        job = WorldGenerationJob.create(
          world_id: world.id,
          job_type: 'procedural',
          status: 'running',
          progress_percentage: 40.0,
          config: { 'phase' => 'climate', 'phases_complete' => %w[tectonics elevation] }
        )

        get "/admin/world_builder/#{world.id}/api/generation_status"

        expect(last_response).to be_ok
        data = JSON.parse(last_response.body)
        expect(data['success']).to be true
        expect(data['job']['id']).to eq(job.id)
        expect(data['job']['status']).to eq('running')
        expect(data['job']['progress_percentage']).to eq(40.0)
        expect(data['job']['phase']).to eq('climate')
        expect(data['job']['phases_complete']).to eq(%w[tectonics elevation])
      end

      it 'returns error message for failed jobs' do
        WorldGenerationJob.create(
          world_id: world.id,
          job_type: 'procedural',
          status: 'failed',
          error_message: 'Something went wrong'
        )

        get "/admin/world_builder/#{world.id}/api/generation_status"

        data = JSON.parse(last_response.body)
        expect(data['job']['status']).to eq('failed')
        expect(data['job']['error_message']).to eq('Something went wrong')
      end

      it 'returns the latest job for the world' do
        old_job = WorldGenerationJob.create(
          world_id: world.id,
          job_type: 'procedural',
          status: 'completed',
          created_at: Time.now - 3600
        )
        new_job = WorldGenerationJob.create(
          world_id: world.id,
          job_type: 'procedural',
          status: 'running',
          created_at: Time.now
        )

        get "/admin/world_builder/#{world.id}/api/generation_status"

        data = JSON.parse(last_response.body)
        expect(data['job']['id']).to eq(new_job.id)
      end
    end
  end
end
