# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Media API Routes', type: :request do
  let(:user) { create(:user) }
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

  describe 'Media API authentication' do
    it 'returns 401 without auth' do
      get '/api/media/session', {}, { 'CONTENT_TYPE' => 'application/json' }
      expect(last_response.status).to eq(401)
    end
  end

  describe 'GET /api/media/session' do
    it 'returns current session state' do
      get '/api/media/session', {}, auth_headers
      expect(last_response.status).to eq(200)
      expect(json_response['success']).to be true
    end
  end

  describe 'GET /api/media/events' do
    it 'returns media events' do
      get '/api/media/events', {}, auth_headers
      expect(last_response.status).to eq(200)
      expect(json_response['success']).to be true
      expect(json_response['events']).to be_an(Array)
    end

    it 'accepts since parameter' do
      get '/api/media/events', { since: Time.now.iso8601 }, auth_headers
      expect(last_response.status).to eq(200)
    end
  end

  describe 'POST /api/media/youtube' do
    it 'requires video_id' do
      post '/api/media/youtube', { title: 'Test' }.to_json, auth_headers
      expect(last_response.status).to eq(400)
      expect(json_response['error']).to include('video_id')
    end

    it 'starts YouTube session with valid params' do
      allow(MediaSyncService).to receive(:start_youtube).and_return(
        double(to_sync_hash: { id: 1, video_id: 'test123' })
      )

      post '/api/media/youtube', {
        video_id: 'test123',
        title: 'Test Video',
        duration: 300
      }.to_json, auth_headers

      expect(last_response.status).to eq(200)
      expect(json_response['success']).to be true
    end

    it 'returns 409 when another host has an active room session' do
      allow(MediaSyncService).to receive(:start_youtube).and_raise(
        MediaSyncService::SessionConflictError, 'Another host is already running media in this room'
      )

      post '/api/media/youtube', { video_id: 'test123', title: 'Blocked' }.to_json, auth_headers

      expect(last_response.status).to eq(409)
      expect(json_response['success']).to be false
      expect(json_response['error']).to include('Another host')
    end
  end

  describe 'POST /api/media/register_share' do
    it 'requires peer_id' do
      post '/api/media/register_share', { share_type: 'screen' }.to_json, auth_headers
      expect(last_response.status).to eq(400)
      expect(json_response['error']).to include('peer_id')
    end

    it 'registers screen share with valid params' do
      allow(MediaSyncService).to receive(:start_screen_share).and_return(
        double(to_sync_hash: { id: 1, peer_id: 'peer123' })
      )

      post '/api/media/register_share', {
        peer_id: 'peer123',
        share_type: 'screen',
        has_audio: false
      }.to_json, auth_headers

      expect(last_response.status).to eq(200)
      expect(json_response['success']).to be true
    end

    it 'returns 409 when another host has an active room session' do
      allow(MediaSyncService).to receive(:start_screen_share).and_raise(
        MediaSyncService::SessionConflictError, 'Another host is already running media in this room'
      )

      post '/api/media/register_share', { peer_id: 'peer123', share_type: 'screen' }.to_json, auth_headers

      expect(last_response.status).to eq(409)
      expect(json_response['success']).to be false
      expect(json_response['error']).to include('Another host')
    end
  end

  describe 'POST /api/media/control' do
    before do
      allow(MediaSyncService).to receive(:play).and_return({ success: true })
      allow(MediaSyncService).to receive(:pause).and_return({ success: true })
      allow(MediaSyncService).to receive(:seek).and_return({ success: true })
      allow(MediaSyncService).to receive(:buffering).and_return({ success: true })
      allow(MediaSyncService).to receive(:set_rate).and_return({ success: true })
      allow(MediaSyncService).to receive(:end_room_session).and_return({ success: true })
      allow(MediaSyncService).to receive(:broadcast_update).and_return(
        { success: true, session: { id: 1, youtube_video_id: 'next123' } }
      )
    end

    it 'returns 404 for non-existent session' do
      post '/api/media/control', { session_id: 999999, action: 'play' }.to_json, auth_headers
      expect(last_response.status).to eq(404)
    end

    it 'returns error for invalid JSON' do
      post '/api/media/control', 'not json', auth_headers
      expect(last_response.status).to eq(400)
    end

    it 'handles actions with valid session' do
      media_session = create(:media_session, room: room, host: character_instance)
      post '/api/media/control', { session_id: media_session.id, action: 'play' }.to_json, auth_headers
      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json['success']).to be true
    end

    it 'rejects controlling a session outside current room' do
      other_room = create(:room)
      media_session = create(:media_session, room: other_room, host: character_instance)

      post '/api/media/control', { session_id: media_session.id, action: 'play' }.to_json, auth_headers

      expect(last_response.status).to eq(403)
      expect(json_response['error']).to include('not in your room')
    end

    it 'broadcasts update when advancing to next playlist track' do
      playlist = MediaPlaylist.create(character_id: character.id, name: "Route Playlist #{rand(100_000)}")
      MediaPlaylistItem.create(media_playlist_id: playlist.id, youtube_video_id: 'first1', position: 0)
      MediaPlaylistItem.create(media_playlist_id: playlist.id, youtube_video_id: 'next2', position: 1)
      media_session = create(
        :media_session,
        room: room,
        host: character_instance,
        session_type: 'youtube',
        youtube_video_id: 'first1',
        playlist_id: playlist.id,
        playlist_position: 0
      )

      post '/api/media/control', { session_id: media_session.id, action: 'next_track' }.to_json, auth_headers

      expect(last_response).to be_ok
      expect(MediaSyncService).to have_received(:broadcast_update).with(instance_of(MediaSession))
    end
  end

  describe 'POST /api/media/heartbeat' do
    it 'sends heartbeat' do
      post '/api/media/heartbeat', {}.to_json, auth_headers
      expect(last_response.status).to eq(200)
      expect(json_response['success']).to be true
    end
  end

  describe 'POST /api/media/join' do
    it 'returns 404 for non-existent session' do
      post '/api/media/join', { session_id: 999999, peer_id: 'peer123' }.to_json, auth_headers
      expect(last_response.status).to eq(404)
    end

    it 'joins session successfully' do
      media_session = create(:media_session, room: room, host: character_instance)
      post '/api/media/join', { session_id: media_session.id, peer_id: 'peer123' }.to_json, auth_headers
      expect(last_response).to be_ok
      json = JSON.parse(last_response.body)
      expect(json['success']).to be true
    end

    it 'rejects joining a session outside current room' do
      other_room = create(:room)
      other_host = create(:character_instance, current_room: other_room)
      media_session = create(:media_session, room: other_room, host: other_host)

      post '/api/media/join', { session_id: media_session.id, peer_id: 'peer123' }.to_json, auth_headers

      expect(last_response.status).to eq(403)
      expect(json_response['error']).to include('not in your room')
    end
  end

  describe 'POST /api/media/viewer_connected' do
    it 'handles viewer connected' do
      post '/api/media/viewer_connected', { session_id: 1 }.to_json, auth_headers
      expect(last_response.status).to eq(200)
      expect(json_response['success']).to be true
    end

    it 'does not mark connected for session outside current room' do
      allow(MediaSyncService).to receive(:viewer_connected)
      other_room = create(:room)
      other_host = create(:character_instance, current_room: other_room)
      media_session = create(:media_session, room: other_room, host: other_host)

      post '/api/media/viewer_connected', { session_id: media_session.id }.to_json, auth_headers

      expect(last_response.status).to eq(200)
      expect(MediaSyncService).not_to have_received(:viewer_connected)
    end
  end

  describe 'POST /api/media/viewer_disconnected' do
    it 'handles viewer disconnected' do
      post '/api/media/viewer_disconnected', { session_id: 1 }.to_json, auth_headers
      expect(last_response.status).to eq(200)
      expect(json_response['success']).to be true
    end

    it 'does not mark disconnected for session outside current room' do
      allow(MediaSyncService).to receive(:viewer_disconnected)
      other_room = create(:room)
      other_host = create(:character_instance, current_room: other_room)
      media_session = create(:media_session, room: other_room, host: other_host)

      post '/api/media/viewer_disconnected', { session_id: media_session.id }.to_json, auth_headers

      expect(last_response.status).to eq(200)
      expect(MediaSyncService).not_to have_received(:viewer_disconnected)
    end
  end

  describe 'POST /api/media/playlists/:id/play' do
    let!(:playlist) { MediaPlaylist.create(character_id: character.id, name: "Room Mix #{rand(100_000)}") }
    let!(:item) do
      MediaPlaylistItem.create(
        media_playlist_id: playlist.id,
        youtube_video_id: 'abc123',
        title: 'Track 1',
        duration_seconds: 210,
        position: 0
      )
    end

    it 'starts playlist playback through MediaSyncService' do
      mock_session = double(to_sync_hash: { id: 99, youtube_video_id: 'abc123' })
      allow(MediaSyncService).to receive(:start_youtube).and_return(mock_session)

      post "/api/media/playlists/#{playlist.id}/play", {}.to_json, auth_headers

      expect(last_response.status).to eq(200)
      expect(MediaSyncService).to have_received(:start_youtube).with(
        room_id: room.id,
        host: character_instance,
        video_id: 'abc123',
        title: 'Track 1',
        duration: 210,
        playlist_id: playlist.id,
        playlist_position: 0
      )
    end

    it 'returns 409 when playlist playback conflicts with another host session' do
      allow(MediaSyncService).to receive(:start_youtube).and_raise(
        MediaSyncService::SessionConflictError, 'Another host is already running media in this room'
      )

      post "/api/media/playlists/#{playlist.id}/play", {}.to_json, auth_headers

      expect(last_response.status).to eq(409)
      expect(json_response['success']).to be false
      expect(json_response['error']).to include('Another host')
    end
  end
end
