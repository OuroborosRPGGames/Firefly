# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MediaSyncService do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  # Mock Redis
  let(:mock_redis) { double('Redis') }

  before do
    allow(REDIS_POOL).to receive(:with).and_yield(mock_redis)
    allow(mock_redis).to receive(:setex)
    allow(mock_redis).to receive(:rpush)
    allow(mock_redis).to receive(:expire)
    allow(mock_redis).to receive(:ltrim)
    allow(mock_redis).to receive(:del)
    allow(mock_redis).to receive(:get).and_return(nil)
    allow(mock_redis).to receive(:lrange).and_return([])
  end

  describe '.start_youtube' do
    let(:video_id) { 'dQw4w9WgXcQ' }
    let(:title) { 'Test Video' }
    let(:duration) { 300 }
    let(:other_host) { create(:character_instance, current_room: room) }

    it 'creates a new MediaSession' do
      expect {
        described_class.start_youtube(
          room_id: room.id,
          host: character_instance,
          video_id: video_id,
          title: title,
          duration: duration
        )
      }.to change { MediaSession.count }.by(1)
    end

    it 'returns the created session' do
      session = described_class.start_youtube(
        room_id: room.id,
        host: character_instance,
        video_id: video_id,
        title: title,
        duration: duration
      )

      expect(session).to be_a(MediaSession)
      expect(session.session_type).to eq('youtube')
      expect(session.youtube_video_id).to eq(video_id)
      expect(session.youtube_title).to eq(title)
      expect(session.youtube_duration_seconds).to eq(duration)
    end

    it 'sets session as active' do
      session = described_class.start_youtube(
        room_id: room.id,
        host: character_instance,
        video_id: video_id
      )

      expect(session.status).to eq('active')
      expect(session.is_playing).to be true
      expect(session.playback_position).to eq(0.0)
      expect(session.playback_started_at).not_to be_nil
    end

    it 'uses default title when not provided' do
      session = described_class.start_youtube(
        room_id: room.id,
        host: character_instance,
        video_id: video_id
      )

      expect(session.youtube_title).to eq('YouTube Video')
    end

    it 'ends any existing session in the room' do
      existing_session = MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'oldVideo',
        status: 'active',
        last_heartbeat: Time.now
      )

      described_class.start_youtube(
        room_id: room.id,
        host: character_instance,
        video_id: video_id
      )

      expect(existing_session.reload.status).to eq('ended')
    end

    it 'raises conflict if another host already has an active session' do
      MediaSession.create(
        room_id: room.id,
        host_id: other_host.id,
        session_type: 'youtube',
        youtube_video_id: 'oldVideo',
        status: 'active',
        last_heartbeat: Time.now
      )

      expect {
        described_class.start_youtube(
          room_id: room.id,
          host: character_instance,
          video_id: video_id
        )
      }.to raise_error(MediaSyncService::SessionConflictError)
    end

    it 'allows force takeover when requested' do
      existing_session = MediaSession.create(
        room_id: room.id,
        host_id: other_host.id,
        session_type: 'youtube',
        youtube_video_id: 'oldVideo',
        status: 'active',
        last_heartbeat: Time.now
      )

      session = described_class.start_youtube(
        room_id: room.id,
        host: character_instance,
        video_id: video_id,
        force: true
      )

      expect(existing_session.reload.status).to eq('ended')
      expect(session.host_id).to eq(character_instance.id)
    end

    it 'persists playlist metadata when provided' do
      playlist = MediaPlaylist.create(character_id: character.id, name: "Spec Playlist #{rand(100_000)}")
      session = described_class.start_youtube(
        room_id: room.id,
        host: character_instance,
        video_id: video_id,
        playlist_id: playlist.id,
        playlist_position: 4
      )

      expect(session.playlist_id).to eq(playlist.id)
      expect(session.playlist_position).to eq(4)
    end

    it 'caches session state in Redis' do
      expect(mock_redis).to receive(:setex).at_least(:twice)

      described_class.start_youtube(
        room_id: room.id,
        host: character_instance,
        video_id: video_id
      )
    end

    it 'broadcasts session started event' do
      expect(mock_redis).to receive(:rpush) do |key, value|
        expect(key).to include('events')
        data = JSON.parse(value)
        expect(data['type']).to eq('media_session_started')
      end

      described_class.start_youtube(
        room_id: room.id,
        host: character_instance,
        video_id: video_id
      )
    end
  end

  describe '.start_screen_share' do
    let(:peer_id) { 'peer-abc123' }
    let(:share_type) { 'screen' }
    let(:other_host) { create(:character_instance, current_room: room) }

    it 'creates a screen share session' do
      session = described_class.start_screen_share(
        room_id: room.id,
        host: character_instance,
        peer_id: peer_id,
        share_type: share_type
      )

      expect(session.session_type).to eq('screen_share')
      expect(session.peer_id).to eq(peer_id)
      expect(session.share_type).to eq(share_type)
      expect(session.is_playing).to be true
    end

    it 'creates a tab share session for tab type' do
      session = described_class.start_screen_share(
        room_id: room.id,
        host: character_instance,
        peer_id: peer_id,
        share_type: 'tab'
      )

      expect(session.session_type).to eq('tab_share')
    end

    it 'sets has_audio flag' do
      session = described_class.start_screen_share(
        room_id: room.id,
        host: character_instance,
        peer_id: peer_id,
        share_type: share_type,
        has_audio: true
      )

      expect(session.has_audio).to be true
    end

    it 'defaults has_audio to false' do
      session = described_class.start_screen_share(
        room_id: room.id,
        host: character_instance,
        peer_id: peer_id,
        share_type: share_type
      )

      expect(session.has_audio).to be false
    end

    it 'raises conflict if another host already has an active session' do
      MediaSession.create(
        room_id: room.id,
        host_id: other_host.id,
        session_type: 'youtube',
        youtube_video_id: 'oldVideo',
        status: 'active',
        last_heartbeat: Time.now
      )

      expect {
        described_class.start_screen_share(
          room_id: room.id,
          host: character_instance,
          peer_id: peer_id,
          share_type: share_type
        )
      }.to raise_error(MediaSyncService::SessionConflictError)
    end
  end

  describe '.end_room_session' do
    let!(:session) do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        status: 'active',
        last_heartbeat: Time.now
      )
    end

    it 'ends the active session' do
      described_class.end_room_session(room.id)

      expect(session.reload.status).to eq('ended')
    end

    it 'clears session cache' do
      allow(mock_redis).to receive(:get).and_return('{}')
      expect(mock_redis).to receive(:del).at_least(:once)

      described_class.end_room_session(room.id)
    end

    it 'broadcasts session ended event' do
      expect(mock_redis).to receive(:rpush) do |key, value|
        data = JSON.parse(value)
        expect(data['type']).to eq('media_session_ended')
        expect(data['session_id']).to eq(session.id)
      end

      described_class.end_room_session(room.id)
    end

    it 'does nothing if no active session' do
      session.update(status: 'ended')

      expect { described_class.end_room_session(room.id) }.not_to raise_error
    end
  end

  describe '.play' do
    let(:session) do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        status: 'paused',
        is_playing: false,
        last_heartbeat: Time.now
      )
    end

    it 'returns success and session data' do
      result = described_class.play(session)

      expect(result[:success]).to be true
      expect(result[:session]).to be_a(Hash)
    end

    it 'starts playback' do
      described_class.play(session)

      expect(session.reload.is_playing).to be true
    end

    it 'sets session to active' do
      described_class.play(session)

      expect(session.reload.status).to eq('active')
    end

    it 'seeks to position if provided' do
      described_class.play(session, position: 60.0)

      expect(session.reload.playback_position).to eq(60.0)
    end

    it 'broadcasts play event' do
      expect(mock_redis).to receive(:rpush) do |key, value|
        data = JSON.parse(value)
        expect(data['type']).to eq('media_playback_update')
        expect(data['action']).to eq('play')
      end

      described_class.play(session)
    end

    it 'returns error for ended session' do
      session.update(status: 'ended')

      result = described_class.play(session)

      expect(result[:success]).to be false
      expect(result[:error]).to eq('Session not active')
    end
  end

  describe '.pause' do
    let(:session) do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        status: 'active',
        is_playing: true,
        playback_position: 30.0,
        last_heartbeat: Time.now
      )
    end

    it 'returns success' do
      result = described_class.pause(session)

      expect(result[:success]).to be true
    end

    it 'stops playback' do
      described_class.pause(session)

      expect(session.reload.is_playing).to be false
    end

    it 'sets session to paused' do
      described_class.pause(session)

      expect(session.reload.status).to eq('paused')
    end

    it 'broadcasts pause event' do
      expect(mock_redis).to receive(:rpush) do |key, value|
        data = JSON.parse(value)
        expect(data['action']).to eq('pause')
      end

      described_class.pause(session)
    end

    it 'returns error if not playing' do
      session.update(is_playing: false)

      result = described_class.pause(session)

      expect(result[:success]).to be false
      expect(result[:error]).to eq('Not playing')
    end
  end

  describe '.seek' do
    let(:session) do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        status: 'active',
        is_playing: true,
        playback_position: 0.0,
        last_heartbeat: Time.now
      )
    end

    it 'returns success' do
      result = described_class.seek(session, 120.5)

      expect(result[:success]).to be true
    end

    it 'updates playback position' do
      described_class.seek(session, 120.5)

      expect(session.reload.playback_position).to eq(120.5)
    end

    it 'broadcasts seek event' do
      expect(mock_redis).to receive(:rpush) do |key, value|
        data = JSON.parse(value)
        expect(data['action']).to eq('seek')
        expect(data['position']).to eq(120.5)
      end

      described_class.seek(session, 120.5)
    end
  end

  describe '.buffering' do
    let(:session) do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        status: 'active',
        is_playing: true,
        playback_position: 60.0,
        last_heartbeat: Time.now
      )
    end

    it 'returns success' do
      result = described_class.buffering(session)

      expect(result[:success]).to be true
    end

    it 'sets buffering state' do
      described_class.buffering(session)

      expect(session.reload.is_buffering).to be true
    end

    it 'updates position if provided' do
      described_class.buffering(session, position: 75.0)

      expect(session.reload.playback_position).to eq(75.0)
    end

    it 'broadcasts buffering event' do
      expect(mock_redis).to receive(:rpush) do |key, value|
        data = JSON.parse(value)
        expect(data['action']).to eq('buffering')
      end

      described_class.buffering(session)
    end
  end

  describe '.set_rate' do
    let(:session) do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        status: 'active',
        playback_rate: 1.0,
        last_heartbeat: Time.now
      )
    end

    it 'returns success' do
      result = described_class.set_rate(session, 1.5)

      expect(result[:success]).to be true
    end

    it 'updates playback rate' do
      described_class.set_rate(session, 1.5)

      expect(session.reload.playback_rate).to eq(1.5)
    end

    it 'clamps rate to minimum 0.25' do
      described_class.set_rate(session, 0.1)

      expect(session.reload.playback_rate).to eq(0.25)
    end

    it 'clamps rate to maximum 2.0' do
      described_class.set_rate(session, 5.0)

      expect(session.reload.playback_rate).to eq(2.0)
    end

    it 'broadcasts rate event' do
      expect(mock_redis).to receive(:rpush) do |key, value|
        data = JSON.parse(value)
        expect(data['action']).to eq('rate')
        expect(data['playback_rate']).to eq(1.5)
      end

      described_class.set_rate(session, 1.5)
    end
  end

  describe '.broadcast_update' do
    let(:session) do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        status: 'active',
        last_heartbeat: Time.now
      )
    end

    it 'returns success' do
      result = described_class.broadcast_update(session)

      expect(result[:success]).to be true
    end

    it 'broadcasts update event' do
      expect(mock_redis).to receive(:rpush) do |key, value|
        data = JSON.parse(value)
        expect(data['action']).to eq('update')
      end

      described_class.broadcast_update(session)
    end
  end

  describe '.viewer_join' do
    let(:session) do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        status: 'active',
        last_heartbeat: Time.now
      )
    end
    let(:viewer) { create(:character_instance, current_room: room) }
    let(:peer_id) { 'viewer-peer-123' }

    it 'returns session sync hash' do
      result = described_class.viewer_join(session, viewer, peer_id)

      expect(result).to be_a(Hash)
      expect(result[:id]).to eq(session.id)
    end

    it 'creates a viewer record' do
      expect {
        described_class.viewer_join(session, viewer, peer_id)
      }.to change { MediaSessionViewer.count }.by(1)
    end

    it 'sets viewer connection status to pending' do
      described_class.viewer_join(session, viewer, peer_id)

      viewer_record = MediaSessionViewer.first(
        media_session_id: session.id,
        character_instance_id: viewer.id
      )
      expect(viewer_record.connection_status).to eq('pending')
    end

    it 'stores viewer peer_id' do
      described_class.viewer_join(session, viewer, peer_id)

      viewer_record = MediaSessionViewer.first(
        media_session_id: session.id,
        character_instance_id: viewer.id
      )
      expect(viewer_record.peer_id).to eq(peer_id)
    end

    it 'updates existing viewer record' do
      MediaSessionViewer.create(
        media_session_id: session.id,
        character_instance_id: viewer.id,
        peer_id: 'old-peer-id',
        connection_status: 'disconnected'
      )

      expect {
        described_class.viewer_join(session, viewer, peer_id)
      }.not_to change { MediaSessionViewer.count }

      viewer_record = MediaSessionViewer.first(
        media_session_id: session.id,
        character_instance_id: viewer.id
      )
      expect(viewer_record.peer_id).to eq(peer_id)
      expect(viewer_record.connection_status).to eq('pending')
    end
  end

  describe '.viewer_connected' do
    let(:session) do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        status: 'active',
        last_heartbeat: Time.now
      )
    end
    let(:viewer) { create(:character_instance, current_room: room) }
    let!(:viewer_record) do
      MediaSessionViewer.create(
        media_session_id: session.id,
        character_instance_id: viewer.id,
        connection_status: 'pending'
      )
    end

    it 'marks viewer as connected' do
      described_class.viewer_connected(session, viewer)

      expect(viewer_record.reload.connection_status).to eq('connected')
    end

    it 'handles missing viewer gracefully' do
      other_character = create(:character_instance)

      expect { described_class.viewer_connected(session, other_character) }.not_to raise_error
    end
  end

  describe '.viewer_disconnected' do
    let(:session) do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        status: 'active',
        last_heartbeat: Time.now
      )
    end
    let(:viewer) { create(:character_instance, current_room: room) }
    let!(:viewer_record) do
      MediaSessionViewer.create(
        media_session_id: session.id,
        character_instance_id: viewer.id,
        connection_status: 'connected'
      )
    end

    it 'marks viewer as disconnected' do
      described_class.viewer_disconnected(session, viewer)

      expect(viewer_record.reload.connection_status).to eq('disconnected')
    end

    it 'handles missing viewer gracefully' do
      other_character = create(:character_instance)

      expect { described_class.viewer_disconnected(session, other_character) }.not_to raise_error
    end
  end

  describe '.fetch_room_session' do
    context 'with cached session' do
      before do
        allow(mock_redis).to receive(:get)
          .with("media_sync:room:#{room.id}")
          .and_return('123')
        allow(mock_redis).to receive(:get)
          .with('media_sync:session:123')
          .and_return('{"id":123,"type":"youtube"}')
      end

      it 'returns cached data' do
        result = described_class.fetch_room_session(room.id)

        expect(result).to eq({ id: 123, type: 'youtube' })
      end
    end

    context 'with database session (no cache)' do
      let!(:session) do
        MediaSession.create(
          room_id: room.id,
          host_id: character_instance.id,
          session_type: 'youtube',
          youtube_video_id: 'test123',
          status: 'active',
          last_heartbeat: Time.now
        )
      end

      it 'returns session from database' do
        result = described_class.fetch_room_session(room.id)

        expect(result).to be_a(Hash)
        expect(result[:id]).to eq(session.id)
        expect(result[:type]).to eq('youtube')
      end

      it 'caches the session' do
        expect(mock_redis).to receive(:setex).at_least(:twice)

        described_class.fetch_room_session(room.id)
      end
    end

    context 'with no session' do
      it 'returns nil' do
        result = described_class.fetch_room_session(room.id)

        expect(result).to be_nil
      end
    end
  end

  describe '.room_events' do
    context 'with events' do
      let(:events) do
        [
          { type: 'media_session_started', timestamp: Time.now.iso8601 }.to_json,
          { type: 'media_playback_update', timestamp: (Time.now - 10).iso8601 }.to_json
        ]
      end

      before do
        allow(mock_redis).to receive(:lrange).and_return(events)
      end

      it 'returns parsed events' do
        result = described_class.room_events(room.id)

        expect(result).to be_an(Array)
        expect(result.length).to eq(2)
        expect(result.first[:type]).to eq('media_session_started')
      end

      it 'filters events by timestamp' do
        since = (Time.now - 5).iso8601
        result = described_class.room_events(room.id, since_timestamp: since)

        expect(result.length).to eq(1)
        expect(result.first[:type]).to eq('media_session_started')
      end
    end

    context 'with no events' do
      it 'returns empty array' do
        result = described_class.room_events(room.id)

        expect(result).to eq([])
      end
    end

    context 'with Redis error' do
      before do
        allow(mock_redis).to receive(:lrange).and_raise(Redis::BaseError.new('Connection failed'))
      end

      it 'returns empty array' do
        result = described_class.room_events(room.id)

        expect(result).to eq([])
      end
    end
  end

  describe '.heartbeat' do
    let(:session) do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        status: 'active',
        last_heartbeat: Time.now - 30
      )
    end

    it 'updates session heartbeat' do
      old_heartbeat = session.last_heartbeat

      described_class.heartbeat(session)

      expect(session.reload.last_heartbeat).to be > old_heartbeat
    end

    it 'refreshes Redis cache expiry' do
      expect(mock_redis).to receive(:expire).at_least(:twice)

      described_class.heartbeat(session)
    end
  end

  describe '.cleanup_stale_sessions!' do
    it 'delegates to MediaSession.cleanup_stale_sessions!' do
      expect(MediaSession).to receive(:cleanup_stale_sessions!)

      described_class.cleanup_stale_sessions!
    end
  end

  describe 'error handling' do
    context 'when Redis fails during caching' do
      before do
        allow(mock_redis).to receive(:setex).and_raise(Redis::BaseError.new('Connection failed'))
      end

      it 'logs error but continues' do
        expect {
          described_class.start_youtube(
            room_id: room.id,
            host: character_instance,
            video_id: 'test123'
          )
        }.to output(/Redis cache error/).to_stderr
      end
    end

    context 'when Redis fails during broadcast' do
      before do
        allow(mock_redis).to receive(:rpush).and_raise(Redis::BaseError.new('Connection failed'))
      end

      it 'logs error but continues' do
        expect {
          described_class.start_youtube(
            room_id: room.id,
            host: character_instance,
            video_id: 'test123'
          )
        }.to output(/Broadcast error/).to_stderr
      end
    end
  end
end
