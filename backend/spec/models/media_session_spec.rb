# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MediaSession do
  let(:room) { create(:room) }
  let(:character) { create(:character) }
  let(:host) { create(:character_instance, character: character, current_room: room) }

  describe 'constants' do
    it 'has expected session types' do
      expect(MediaSession::TYPES).to eq(%w[youtube screen_share tab_share])
    end

    it 'has expected statuses' do
      expect(MediaSession::STATUSES).to eq(%w[active paused ended])
    end

    it 'has expected share types' do
      expect(MediaSession::SHARE_TYPES).to eq(%w[screen window tab])
    end
  end

  describe 'validations' do
    it 'requires room_id' do
      session = MediaSession.new(host_id: host.id, session_type: 'youtube', youtube_video_id: 'abc')
      expect(session.valid?).to be false
      expect(session.errors[:room_id]).not_to be_empty
    end

    it 'requires host_id' do
      session = MediaSession.new(room_id: room.id, session_type: 'youtube', youtube_video_id: 'abc')
      expect(session.valid?).to be false
      expect(session.errors[:host_id]).not_to be_empty
    end

    it 'requires session_type' do
      session = MediaSession.new(room_id: room.id, host_id: host.id)
      expect(session.valid?).to be false
      expect(session.errors[:session_type]).not_to be_empty
    end

    it 'validates session_type is in TYPES' do
      session = MediaSession.new(
        room_id: room.id, host_id: host.id, session_type: 'invalid'
      )
      expect(session.valid?).to be false
      expect(session.errors[:session_type]).not_to be_empty
    end

    it 'validates status is in STATUSES' do
      session = MediaSession.new(
        room_id: room.id, host_id: host.id, session_type: 'youtube',
        youtube_video_id: 'abc', status: 'invalid'
      )
      expect(session.valid?).to be false
      expect(session.errors[:status]).not_to be_empty
    end

    it 'requires youtube_video_id for youtube type' do
      session = MediaSession.new(
        room_id: room.id, host_id: host.id, session_type: 'youtube'
      )
      expect(session.valid?).to be false
      expect(session.errors[:youtube_video_id]).not_to be_empty
    end

    it 'requires peer_id for screen_share type' do
      session = MediaSession.new(
        room_id: room.id, host_id: host.id, session_type: 'screen_share'
      )
      expect(session.valid?).to be false
      expect(session.errors[:peer_id]).not_to be_empty
    end

    it 'requires peer_id for tab_share type' do
      session = MediaSession.new(
        room_id: room.id, host_id: host.id, session_type: 'tab_share'
      )
      expect(session.valid?).to be false
      expect(session.errors[:peer_id]).not_to be_empty
    end

    it 'accepts valid youtube session' do
      session = create(:media_session, :youtube, room: room, host: host)
      expect(session.valid?).to be true
    end

    it 'accepts valid screen_share session' do
      session = create(:media_session, :screen_share, room: room, host: host)
      expect(session.valid?).to be true
    end

    it 'accepts valid tab_share session' do
      session = create(:media_session, :tab_share, room: room, host: host)
      expect(session.valid?).to be true
    end
  end

  describe '.active_in_room' do
    it 'returns active session in room' do
      active = create(:media_session, room: room, host: host, status: 'active')
      expect(MediaSession.active_in_room(room.id).id).to eq(active.id)
    end

    it 'returns paused session in room' do
      paused = create(:media_session, :paused, room: room, host: host)
      expect(MediaSession.active_in_room(room.id).id).to eq(paused.id)
    end

    it 'returns nil for ended session' do
      create(:media_session, :ended, room: room, host: host)
      expect(MediaSession.active_in_room(room.id)).to be_nil
    end

    it 'returns nil when no session exists' do
      expect(MediaSession.active_in_room(room.id)).to be_nil
    end
  end

  describe '.cleanup_stale_sessions!' do
    it 'ends sessions with stale heartbeat' do
      stale = create(:media_session, room: room, host: host, status: 'active')
      stale.update(last_heartbeat: Time.now - 300)

      MediaSession.cleanup_stale_sessions!
      stale.refresh

      expect(stale.status).to eq('ended')
      expect(stale.ended_at).not_to be_nil
    end

    it 'ignores sessions with recent heartbeat' do
      recent = create(:media_session, room: room, host: host, status: 'active')
      recent.update(last_heartbeat: Time.now)

      MediaSession.cleanup_stale_sessions!
      recent.refresh

      expect(recent.status).to eq('active')
    end
  end

  describe 'type checks' do
    describe '#youtube?' do
      it 'returns true for youtube type' do
        session = create(:media_session, :youtube, room: room, host: host)
        expect(session.youtube?).to be true
      end

      it 'returns false for other types' do
        session = create(:media_session, :screen_share, room: room, host: host)
        expect(session.youtube?).to be false
      end
    end

    describe '#screen_share?' do
      it 'returns true for screen_share type' do
        session = create(:media_session, :screen_share, room: room, host: host)
        expect(session.screen_share?).to be true
      end

      it 'returns false for other types' do
        session = create(:media_session, :youtube, room: room, host: host)
        expect(session.screen_share?).to be false
      end
    end

    describe '#tab_share?' do
      it 'returns true for tab_share type' do
        session = create(:media_session, :tab_share, room: room, host: host)
        expect(session.tab_share?).to be true
      end

      it 'returns false for other types' do
        session = create(:media_session, :youtube, room: room, host: host)
        expect(session.tab_share?).to be false
      end
    end

    describe '#webrtc_share?' do
      it 'returns true for screen_share' do
        session = create(:media_session, :screen_share, room: room, host: host)
        expect(session.webrtc_share?).to be true
      end

      it 'returns true for tab_share' do
        session = create(:media_session, :tab_share, room: room, host: host)
        expect(session.webrtc_share?).to be true
      end

      it 'returns false for youtube' do
        session = create(:media_session, :youtube, room: room, host: host)
        expect(session.webrtc_share?).to be false
      end
    end
  end

  describe 'status checks' do
    describe '#active?' do
      it 'returns true for active status' do
        session = create(:media_session, room: room, host: host, status: 'active')
        expect(session.active?).to be true
      end

      it 'returns false for other statuses' do
        session = create(:media_session, :paused, room: room, host: host)
        expect(session.active?).to be false
      end
    end

    describe '#paused?' do
      it 'returns true for paused status' do
        session = create(:media_session, :paused, room: room, host: host)
        expect(session.paused?).to be true
      end

      it 'returns false for other statuses' do
        session = create(:media_session, room: room, host: host, status: 'active')
        expect(session.paused?).to be false
      end
    end

    describe '#ended?' do
      it 'returns true for ended status' do
        session = create(:media_session, :ended, room: room, host: host)
        expect(session.ended?).to be true
      end

      it 'returns false for other statuses' do
        session = create(:media_session, room: room, host: host, status: 'active')
        expect(session.ended?).to be false
      end
    end
  end

  describe '#host?' do
    let(:session) { create(:media_session, room: room, host: host) }

    it 'returns true for the host' do
      expect(session.host?(host)).to be true
    end

    it 'returns false for another character instance' do
      other = create(:character_instance, current_room: room)
      expect(session.host?(other)).to be false
    end

    it 'returns false for nil' do
      expect(session.host?(nil)).to be false
    end
  end

  describe '#current_position' do
    it 'returns playback_position when not playing' do
      session = create(:media_session, room: room, host: host, is_playing: false, playback_position: 30.0)
      expect(session.current_position).to eq(30.0)
    end

    it 'returns 0 when playback_position is nil and not playing' do
      session = create(:media_session, room: room, host: host, is_playing: false)
      session.update(playback_position: nil)
      expect(session.current_position).to eq(0.0)
    end

    it 'calculates position with elapsed time when playing' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)

      session = create(:media_session, room: room, host: host,
                       is_playing: true,
                       playback_position: 10.0,
                       playback_started_at: now - 5,
                       playback_rate: 1.0)

      expect(session.current_position).to be_within(0.1).of(15.0)
    end

    it 'accounts for playback_rate' do
      now = Time.now
      allow(Time).to receive(:now).and_return(now)

      session = create(:media_session, room: room, host: host,
                       is_playing: true,
                       playback_position: 10.0,
                       playback_started_at: now - 10,
                       playback_rate: 2.0)

      expect(session.current_position).to be_within(0.1).of(30.0)
    end
  end

  describe 'playback controls' do
    let(:session) { create(:media_session, room: room, host: host, is_playing: false, playback_position: 0.0) }

    describe '#play!' do
      it 'sets is_playing to true' do
        session.play!
        session.refresh
        expect(session.is_playing).to be true
      end

      it 'sets status to active' do
        session.play!
        session.refresh
        expect(session.status).to eq('active')
      end

      it 'sets playback_started_at' do
        session.play!
        session.refresh
        expect(session.playback_started_at).not_to be_nil
      end

      it 'sets position when provided' do
        session.play!(position: 60.0)
        session.refresh
        expect(session.playback_position).to eq(60.0)
      end
    end

    describe '#pause!' do
      before do
        session.play!
        session.refresh
      end

      it 'sets is_playing to false' do
        session.pause!
        session.refresh
        expect(session.is_playing).to be false
      end

      it 'sets status to paused' do
        session.pause!
        session.refresh
        expect(session.status).to eq('paused')
      end

      it 'saves current position' do
        session.pause!
        session.refresh
        expect(session.playback_position).to be >= 0
      end
    end

    describe '#seek!' do
      it 'updates playback_position' do
        session.seek!(120.5)
        session.refresh
        expect(session.playback_position).to eq(120.5)
      end

      it 'updates playback_started_at when playing' do
        session.play!
        old_started_at = session.playback_started_at

        sleep 0.1
        session.seek!(60.0)
        session.refresh

        expect(session.playback_started_at).to be >= old_started_at
      end
    end

    describe '#end_session!' do
      it 'sets status to ended' do
        session.end_session!
        session.refresh
        expect(session.status).to eq('ended')
      end

      it 'sets ended_at' do
        session.end_session!
        session.refresh
        expect(session.ended_at).not_to be_nil
      end

      it 'sets is_playing to false' do
        session.play!
        session.end_session!
        session.refresh
        expect(session.is_playing).to be false
      end
    end

    describe '#heartbeat!' do
      it 'updates last_heartbeat' do
        old_heartbeat = session.last_heartbeat
        session.heartbeat!
        session.refresh
        expect(session.last_heartbeat).not_to eq(old_heartbeat)
      end
    end
  end

  describe 'viewer management' do
    let(:session) { create(:media_session, room: room, host: host) }

    before do
      @viewer1 = create(:character_instance, current_room: room)
      @viewer2 = create(:character_instance, current_room: room)
      create(:media_session_viewer, media_session: session, character_instance: @viewer1, connection_status: 'connected')
      create(:media_session_viewer, media_session: session, character_instance: @viewer2, connection_status: 'disconnected')
    end

    describe '#connected_viewers' do
      it 'returns only connected viewers' do
        viewers = session.connected_viewers.all
        expect(viewers.count).to eq(1)
      end
    end

    describe '#viewer_count' do
      it 'returns count of connected viewers' do
        expect(session.viewer_count).to eq(1)
      end
    end
  end

  describe '#to_sync_hash' do
    let(:session) { create(:media_session, :youtube, room: room, host: host) }

    it 'includes all expected fields' do
      hash = session.to_sync_hash

      expect(hash).to include(
        :id, :type, :room_id, :host_id, :host_peer_id, :host_name,
        :status, :is_playing, :is_buffering, :position, :playback_rate,
        :youtube_video_id, :youtube_title, :youtube_duration,
        :share_type, :has_audio, :viewer_count, :started_at
      )
    end

    it 'includes correct session type' do
      expect(session.to_sync_hash[:type]).to eq('youtube')
    end
  end

  describe 'buffering controls' do
    let(:session) { create(:media_session, room: room, host: host, is_buffering: false) }

    describe '#buffering!' do
      it 'sets is_buffering to true' do
        session.buffering!
        session.refresh
        expect(session.is_buffering).to be true
      end
    end

    describe '#unbuffer!' do
      it 'sets is_buffering to false' do
        session.update(is_buffering: true)
        session.unbuffer!
        session.refresh
        expect(session.is_buffering).to be false
      end
    end
  end
end
