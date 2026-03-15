# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Entertainment::MediaControl do
  let(:reality) { create_test_reality }
  let(:room) { create_test_room(reality_id: reality.id) }
  let(:character) { create_test_character }
  let(:character_instance) { create_test_character_instance(character: character, room: room, reality: reality) }

  subject { described_class.new(character_instance) }

  describe '#execute' do
    context 'media status with no active session' do
      it 'shows no active session message' do
        result = subject.execute('media status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('No active media session')
        expect(result[:type]).to eq(:media_status)
      end
    end

    context 'media (no args) with no active session' do
      it 'opens media GUI panel' do
        result = subject.execute('media')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:open_gui)
        expect(result[:data][:gui]).to eq('media')
      end
    end

    context 'media play with no active session' do
      it 'returns an error' do
        result = subject.execute('media play')

        expect(result[:success]).to be false
        expect(result[:error]).to include('No active media session')
      end
    end

    context 'media pause with no active session' do
      it 'returns an error' do
        result = subject.execute('media pause')

        expect(result[:success]).to be false
        expect(result[:error]).to include('No active media session')
      end
    end

    context 'media seek with no active session' do
      it 'returns an error' do
        result = subject.execute('media seek 1:30')

        expect(result[:success]).to be false
        expect(result[:error]).to include('No active media session')
      end
    end

    context 'with active YouTube session as host' do
      before do
        MediaSession.create(
          room_id: room.id,
          host_id: character_instance.id,
          session_type: 'youtube',
          youtube_video_id: 'test123',
          youtube_title: 'Test Video',
          youtube_duration_seconds: 300,
          status: 'active',
          is_playing: false,
          playback_position: 0
        )
      end

      it 'shows media status' do
        result = subject.execute('media status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Watch Party')
        expect(result[:message]).to include('Test Video')
        expect(result[:data][:is_host]).to be true
      end

      it 'starts playback' do
        result = subject.execute('media play')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Resumed')
        expect(result[:data][:action]).to eq('media_play')
      end

      it 'handles already playing' do
        # First set playing to true
        MediaSession.active_in_room(room.id).update(is_playing: true)

        result = subject.execute('media play')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Already playing')
      end

      it 'pauses playback' do
        # First set playing to true
        MediaSession.active_in_room(room.id).update(is_playing: true, playback_started_at: Time.now)

        result = subject.execute('media pause')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Paused')
        expect(result[:data][:action]).to eq('media_pause')
      end

      it 'handles already paused' do
        result = subject.execute('media pause')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Already paused')
      end

      it 'seeks to position' do
        result = subject.execute('media seek 1:30')

        expect(result[:success]).to be true
        expect(result[:message]).to include('1:30')
        expect(result[:data][:action]).to eq('media_seek')
        expect(result[:data][:position]).to eq(90)
      end

      it 'caps seek position to video duration' do
        result = subject.execute('media seek 10:00')

        expect(result[:success]).to be true
        expect(result[:data][:position]).to eq(300) # 5 minutes (video duration)
      end

      it 'requires time for seek' do
        result = subject.execute('media seek')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Specify a time')
      end

      it 'rejects non-numeric strings' do
        # Command validates numeric format, doesn't just use to_i
        result = subject.execute('media seek abc')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid time format')
      end

      it 'returns error for unknown action' do
        result = subject.execute('media invalid')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown action')
      end

      it 'stops the session' do
        result = subject.execute('media stop')

        expect(result[:success]).to be true
        expect(result[:message]).to include('ended')
        expect(result[:data][:action]).to eq('stop_media')
      end

      it 'opens media GUI panel with host session' do
        result = subject.execute('media')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:open_gui)
        expect(result[:data][:gui]).to eq('media')
      end

      it 'opens media GUI panel when paused' do
        MediaSession.active_in_room(room.id).update(is_playing: true)
        result = subject.execute('media')

        expect(result[:type]).to eq(:open_gui)
        expect(result[:data][:gui]).to eq('media')
      end
    end

    context 'with active YouTube session as viewer' do
      let(:host_character) { create_test_character(forename: 'Host', surname: 'Player') }
      let(:host_instance) { create_test_character_instance(character: host_character, room: room, reality: reality) }

      before do
        MediaSession.create(
          room_id: room.id,
          host_id: host_instance.id,
          session_type: 'youtube',
          youtube_video_id: 'test123',
          status: 'active',
          is_playing: true
        )
      end

      it 'prevents viewer from controlling playback' do
        result = subject.execute('media play')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Only')
        expect(result[:error]).to include('can control')
      end

      it 'prevents viewer from pausing' do
        result = subject.execute('media pause')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Only')
      end

      it 'prevents viewer from seeking' do
        result = subject.execute('media seek 1:00')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Only')
      end

      it 'prevents viewer from stopping session' do
        result = subject.execute('media stop')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Only')
      end

      it 'shows status as viewer' do
        result = subject.execute('media status')

        expect(result[:success]).to be true
        expect(result[:data][:is_host]).to be false
      end

      it 'opens media GUI panel as viewer' do
        result = subject.execute('media')

        expect(result[:type]).to eq(:open_gui)
        expect(result[:data][:gui]).to eq('media')
      end
    end

    context 'with screen share session' do
      let(:host_character) { create_test_character(forename: 'Host', surname: 'Sharer') }
      let(:host_instance) { create_test_character_instance(character: host_character, room: room, reality: reality) }

      before do
        MediaSession.create(
          room_id: room.id,
          host_id: host_instance.id,
          session_type: 'screen_share',
          peer_id: 'test-peer-123',
          share_type: 'screen',
          has_audio: false,
          status: 'active',
          is_playing: true
        )
      end

      it 'shows screen share status' do
        result = subject.execute('media status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Screen Share')
        expect(result[:message]).to include('screen')
      end

      it 'shows viewer count in status' do
        result = subject.execute('media status')

        expect(result[:message]).to include('Viewers')
      end
    end

    context 'with tab share session with audio' do
      before do
        MediaSession.create(
          room_id: room.id,
          host_id: character_instance.id,
          session_type: 'tab_share',
          peer_id: 'test-peer-456',
          share_type: 'tab',
          has_audio: true,
          status: 'active',
          is_playing: true
        )
      end

      it 'shows tab share status with audio indicator' do
        result = subject.execute('media status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('browser tab')
        expect(result[:message]).to include('with audio')
      end
    end
  end

  describe 'alias routing' do
    context 'share alias' do
      it 'routes to share status when called as share' do
        result = subject.execute('share')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:media_status)
        expect(result[:message]).to include('No active share')
      end

      it 'routes share screen to start screen share' do
        result = subject.execute('share screen')

        expect(result[:success]).to be true
        expect(result[:data][:action]).to eq('start_screen_share')
      end

      it 'routes share tab to start tab share' do
        result = subject.execute('share tab')

        expect(result[:success]).to be true
        expect(result[:data][:action]).to eq('start_tab_share')
      end
    end

    context 'player/jukebox alias' do
      it 'returns error when no jukebox present' do
        result = subject.execute('player')

        expect(result[:success]).to be false
        expect(result[:error]).to include('no player here')
      end

      it 'returns error when using jukebox alias with no jukebox' do
        result = subject.execute('jukebox')

        expect(result[:success]).to be false
        expect(result[:error]).to include('no player here')
      end
    end

    context 'playlist alias' do
      it 'returns error when no jukebox present' do
        result = subject.execute('playlist')

        expect(result[:success]).to be false
        expect(result[:error]).to include('no player here')
      end
    end

    context 'media subcommand routing' do
      it 'routes media share to share handler' do
        result = subject.execute('media share status')

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:media_status)
      end

      it 'routes media player to player handler' do
        result = subject.execute('media player')

        expect(result[:success]).to be false
        expect(result[:error]).to include('no player here')
      end

      it 'routes media playlist to playlist handler' do
        result = subject.execute('media playlist')

        expect(result[:success]).to be false
        expect(result[:error]).to include('no player here')
      end
    end
  end

  describe 'share commands' do
    describe 'share status' do
      context 'when host is sharing' do
        before do
          MediaSession.create(
            room_id: room.id,
            host_id: character_instance.id,
            session_type: 'screen_share',
            peer_id: 'test-peer',
            share_type: 'screen',
            status: 'active',
            is_playing: true
          )
        end

        it 'shows host is sharing with viewer count' do
          result = subject.execute('share status')

          expect(result[:success]).to be true
          expect(result[:message]).to include('You are currently sharing')
          expect(result[:data][:is_host]).to be true
        end
      end

      context 'when someone else is sharing' do
        let(:host_character) { create_test_character(forename: 'Screen', surname: 'Sharer') }
        let(:host_instance) { create_test_character_instance(character: host_character, room: room, reality: reality) }

        before do
          MediaSession.create(
            room_id: room.id,
            host_id: host_instance.id,
            session_type: 'screen_share',
            peer_id: 'test-peer',
            share_type: 'screen',
            status: 'active',
            is_playing: true
          )
        end

        it 'shows who is sharing' do
          result = subject.execute('share status')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Screen Sharer')
          expect(result[:message]).to include('sharing')
          expect(result[:data][:is_host]).to be false
        end
      end

      context 'when showing YouTube session' do
        before do
          MediaSession.create(
            room_id: room.id,
            host_id: character_instance.id,
            session_type: 'youtube',
            youtube_video_id: 'abc123',
            status: 'active',
            is_playing: true
          )
        end

        it 'indicates YouTube video in share status' do
          result = subject.execute('share status')

          expect(result[:message]).to include('YouTube video')
        end
      end
    end

    describe 'start screen share' do
      it 'starts screen share' do
        result = subject.execute('share screen')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Starting screen share')
        expect(result[:data][:action]).to eq('start_screen_share')
        expect(result[:data][:share_type]).to eq('screen')
        expect(result[:data][:room_id]).to eq(room.id)
      end

      it 'accepts window as screen share type' do
        result = subject.execute('share window')

        expect(result[:success]).to be true
        expect(result[:data][:action]).to eq('start_screen_share')
      end

      context 'when someone else is already sharing' do
        let(:other_character) { create_test_character(forename: 'Other', surname: 'Sharer') }
        let(:other_instance) { create_test_character_instance(character: other_character, room: room, reality: reality) }

        before do
          MediaSession.create(
            room_id: room.id,
            host_id: other_instance.id,
            session_type: 'screen_share',
            peer_id: 'other-peer',
            share_type: 'screen',
            status: 'active'
          )
        end

        it 'prevents starting new share' do
          result = subject.execute('share screen')

          expect(result[:success]).to be false
          expect(result[:error]).to include('already sharing')
        end
      end

      context 'when host is already sharing' do
        before do
          MediaSession.create(
            room_id: room.id,
            host_id: character_instance.id,
            session_type: 'screen_share',
            peer_id: 'my-peer',
            share_type: 'screen',
            status: 'active'
          )
        end

        it 'allows host to start new share (replaces existing)' do
          result = subject.execute('share screen')

          expect(result[:success]).to be true
        end
      end
    end

    describe 'start tab share' do
      it 'starts tab share' do
        result = subject.execute('share tab')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Starting tab share')
        expect(result[:data][:action]).to eq('start_tab_share')
        expect(result[:data][:share_type]).to eq('tab')
        expect(result[:data][:request_audio]).to be true
      end

      it 'accepts browser as tab share type' do
        result = subject.execute('share browser')

        expect(result[:success]).to be true
        expect(result[:data][:action]).to eq('start_tab_share')
      end
    end

    describe 'stop sharing' do
      context 'when no share active' do
        it 'returns error' do
          result = subject.execute('share stop')

          expect(result[:success]).to be false
          expect(result[:error]).to include('No active share')
        end
      end

      context 'when host stops their share' do
        before do
          MediaSession.create(
            room_id: room.id,
            host_id: character_instance.id,
            session_type: 'screen_share',
            peer_id: 'my-peer',
            share_type: 'screen',
            status: 'active'
          )
        end

        it 'stops the share' do
          result = subject.execute('share stop')

          expect(result[:success]).to be true
          expect(result[:message]).to include('ended')
          expect(result[:data][:action]).to eq('stop_share')
        end

        it 'works with end alias' do
          result = subject.execute('share end')

          expect(result[:success]).to be true
        end
      end

      context 'when non-host tries to stop' do
        let(:host_character) { create_test_character(forename: 'Real', surname: 'Host') }
        let(:host_instance) { create_test_character_instance(character: host_character, room: room, reality: reality) }

        before do
          MediaSession.create(
            room_id: room.id,
            host_id: host_instance.id,
            session_type: 'screen_share',
            peer_id: 'host-peer',
            share_type: 'screen',
            status: 'active'
          )
        end

        it 'prevents non-host from stopping' do
          result = subject.execute('share stop')

          expect(result[:success]).to be false
          expect(result[:error]).to include('Only')
        end
      end
    end

    describe 'unknown share type' do
      it 'returns error for unknown share type' do
        result = subject.execute('share invalid')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown share type')
      end
    end
  end

  describe 'stop command' do
    context 'with room media playing' do
      before do
        RoomMedia.create(
          room_id: room.id,
          url: 'https://www.youtube.com/watch?v=test123',
          ends_at: Time.now + 300
        )
      end

      it 'stops the room media' do
        result = subject.execute('media stop')

        expect(result[:success]).to be true
        expect(result[:message]).to include('stop')
        expect(result[:data][:action]).to eq('stop_media')
      end
    end

    context 'with nothing playing' do
      it 'returns error' do
        result = subject.execute('media stop')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Nothing is currently playing')
      end
    end
  end

  describe 'jukebox/player commands' do
    let(:jukebox) do
      Jukebox.create(
        room_id: room.id,
        name: 'Test Jukebox',
        shuffle_play: false,
        loop_play: false
      )
    end

    # Create a fresh command instance AFTER jukebox is created
    let(:command_with_jukebox) do
      jukebox # Force jukebox creation first
      cmd = described_class.new(character_instance)
      # Stub broadcast_to_room to avoid PetAnimationService database issues
      allow(cmd).to receive(:broadcast_to_room).and_return(nil)
      cmd
    end

    describe 'player status' do
      it 'shows player status when stopped' do
        result = command_with_jukebox.execute('player')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Test Jukebox')
        expect(result[:message]).to include('Stopped')
        expect(result[:data][:jukebox_id]).to eq(jukebox.id)
      end

      it 'shows playing status with modes' do
        jukebox.update(currently_playing: 0, shuffle_play: true, loop_play: true)

        result = command_with_jukebox.execute('player')

        expect(result[:message]).to include('Playing')
        expect(result[:message]).to include('shuffle')
        expect(result[:message]).to include('loop')
      end
    end

    describe 'player play' do
      context 'with empty playlist' do
        it 'returns error' do
          result = command_with_jukebox.execute('player play')

          expect(result[:success]).to be false
          expect(result[:error]).to include('playlist is empty')
        end
      end

      context 'with tracks in playlist' do
        before do
          jukebox.add_track!(url: 'https://youtube.com/watch?v=abc', title: 'Test Track')
        end

        it 'starts playback' do
          result = command_with_jukebox.execute('player play')

          expect(result[:success]).to be true
          expect(result[:message]).to include('starts')
          expect(result[:data][:action]).to eq('player_play')
        end

        it 'returns error if already playing' do
          jukebox.play!

          result = command_with_jukebox.execute('player play')

          expect(result[:success]).to be false
          expect(result[:error]).to include('already playing')
        end

        it 'works with start alias' do
          result = command_with_jukebox.execute('player start')

          expect(result[:success]).to be true
        end
      end
    end

    describe 'player stop' do
      context 'when not playing' do
        it 'returns error' do
          result = command_with_jukebox.execute('player stop')

          expect(result[:success]).to be false
          expect(result[:error]).to include('not playing')
        end
      end

      context 'when playing' do
        before do
          jukebox.add_track!(url: 'https://youtube.com/watch?v=abc', title: 'Test Track')
          jukebox.play!
        end

        it 'stops playback' do
          result = command_with_jukebox.execute('player stop')

          expect(result[:success]).to be true
          expect(result[:message]).to include('stops')
          expect(result[:data][:action]).to eq('player_stop')
        end
      end
    end

    describe 'player shuffle' do
      it 'toggles shuffle on' do
        result = command_with_jukebox.execute('player shuffle')

        expect(result[:success]).to be true
        expect(result[:message]).to include('shuffle')
        expect(result[:data][:shuffle]).to be true
      end

      it 'toggles shuffle off when already on' do
        jukebox.update(shuffle_play: true)

        result = command_with_jukebox.execute('player shuffle')

        expect(result[:message]).to include('sequential')
        expect(result[:data][:shuffle]).to be false
      end
    end

    describe 'player loop' do
      it 'toggles loop on' do
        result = command_with_jukebox.execute('player loop')

        expect(result[:success]).to be true
        expect(result[:message]).to include('loop')
        expect(result[:data][:loop]).to be true
      end

      it 'toggles loop off when already on' do
        jukebox.update(loop_play: true)

        result = command_with_jukebox.execute('player loop')

        expect(result[:message]).to include('stop looping')
        expect(result[:data][:loop]).to be false
      end
    end

    describe 'unknown player command' do
      it 'returns syntax error' do
        result = command_with_jukebox.execute('player invalid')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Syntax')
      end
    end
  end

  describe 'playlist commands' do
    let(:jukebox) do
      Jukebox.create(
        room_id: room.id,
        name: 'Test Jukebox',
        shuffle_play: false,
        loop_play: false
      )
    end

    # Create a fresh command instance AFTER jukebox is created
    let(:playlist_command) do
      jukebox # Force jukebox creation first
      cmd = described_class.new(character_instance)
      # Default: allow playlist editing
      allow(cmd).to receive(:can_edit_playlist?).and_return(true)
      cmd
    end

    describe 'show playlist' do
      context 'with empty playlist' do
        it 'shows empty message' do
          result = playlist_command.execute('playlist')

          expect(result[:success]).to be true
          expect(result[:message]).to include('empty')
          expect(result[:data][:tracks]).to eq([])
        end

        it 'also works with list subcommand' do
          result = playlist_command.execute('playlist list')

          expect(result[:success]).to be true
          expect(result[:message]).to include('empty')
        end
      end

      context 'with tracks' do
        before do
          jukebox.add_track!(url: 'https://youtube.com/watch?v=abc', title: 'First Song', duration_seconds: 180)
          jukebox.add_track!(url: 'https://youtube.com/watch?v=def', title: 'Second Song')
        end

        it 'shows playlist with tracks' do
          result = playlist_command.execute('playlist')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Playlist')
          expect(result[:message]).to include('[1] First Song')
          expect(result[:message]).to include('[2] Second Song')
          expect(result[:message]).to include('3:00') # 180 seconds
          expect(result[:data][:track_count]).to eq(2)
        end

        it 'shows status modes' do
          jukebox.update(shuffle_play: true, currently_playing: 0)

          result = playlist_command.execute('playlist')

          expect(result[:message]).to include('Playing')
          expect(result[:message]).to include('shuffle')
        end
      end
    end

    describe 'playlist add' do
      it 'adds a track with valid URL' do
        result = playlist_command.execute('playlist add https://youtube.com/watch?v=newtrack')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Added')
        expect(result[:data][:action]).to eq('playlist_add')
        expect(jukebox.track_count).to eq(1)
      end

      it 'returns error without URL' do
        result = playlist_command.execute('playlist add')

        expect(result[:success]).to be false
        expect(result[:error]).to include('provide a URL')
      end

      it 'returns error for invalid URL' do
        result = playlist_command.execute('playlist add not-a-url')

        expect(result[:success]).to be false
        expect(result[:error]).to include('valid URL')
      end

      it 'accepts http URLs' do
        result = playlist_command.execute('playlist add http://youtube.com/watch?v=test')

        expect(result[:success]).to be true
      end

      it 'auto-detects URL without add keyword' do
        result = playlist_command.execute('playlist https://youtube.com/watch?v=autodetect')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Added')
      end
    end

    describe 'playlist remove' do
      before do
        jukebox.add_track!(url: 'https://youtube.com/watch?v=abc', title: 'Track to Remove')
      end

      it 'removes a track by position' do
        result = playlist_command.execute('playlist remove 1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Removed')
        expect(result[:message]).to include('Track to Remove')
        expect(jukebox.track_count).to eq(0)
      end

      it 'returns error for invalid position' do
        result = playlist_command.execute('playlist remove 0')

        expect(result[:success]).to be false
        expect(result[:error]).to include('valid track number')
      end

      it 'returns error for non-existent track' do
        result = playlist_command.execute('playlist remove 99')

        expect(result[:success]).to be false
        expect(result[:error]).to include('not found')
      end

      it 'works with delete alias' do
        result = playlist_command.execute('playlist delete 1')

        expect(result[:success]).to be true
      end
    end

    describe 'playlist clear' do
      before do
        jukebox.add_track!(url: 'https://youtube.com/watch?v=a', title: 'Track 1')
        jukebox.add_track!(url: 'https://youtube.com/watch?v=b', title: 'Track 2')
        jukebox.play!
      end

      it 'clears all tracks and stops playback' do
        result = playlist_command.execute('playlist clear')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Cleared 2 tracks')
        expect(jukebox.track_count).to eq(0)
        expect(jukebox.reload.playing?).to be false
      end
    end

    describe 'playlist permissions' do
      # Use a different command for permission testing
      let(:perm_command) do
        jukebox # Force jukebox creation first
        described_class.new(character_instance)
      end

      context 'when user cannot edit playlist' do
        before do
          allow(perm_command).to receive(:can_edit_playlist?).and_return(false)
        end

        it 'prevents adding tracks' do
          result = perm_command.execute('playlist add https://youtube.com/watch?v=test')

          expect(result[:success]).to be false
          expect(result[:error]).to include("don't have permission")
        end

        it 'prevents removing tracks' do
          jukebox.add_track!(url: 'https://youtube.com/watch?v=a', title: 'Track')

          result = perm_command.execute('playlist remove 1')

          expect(result[:success]).to be false
          expect(result[:error]).to include("don't have permission")
        end

        it 'prevents clearing playlist' do
          result = perm_command.execute('playlist clear')

          expect(result[:success]).to be false
          expect(result[:error]).to include("don't have permission")
        end

        it 'allows viewing playlist' do
          # Viewing doesn't require edit permission
          allow(perm_command).to receive(:can_edit_playlist?).and_return(false)
          result = perm_command.execute('playlist')

          expect(result[:success]).to be true
        end
      end

      context 'when user can edit playlist' do
        before do
          allow(perm_command).to receive(:can_edit_playlist?).and_return(true)
        end

        it 'allows editing playlist' do
          result = perm_command.execute('playlist add https://youtube.com/watch?v=test')

          expect(result[:success]).to be true
        end
      end
    end

    describe 'unknown playlist command' do
      it 'returns syntax error' do
        result = playlist_command.execute('playlist invalid')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Syntax')
      end
    end
  end

  describe 'media menu with jukebox' do
    let(:jukebox) do
      Jukebox.create(
        room_id: room.id,
        name: 'Room Jukebox',
        shuffle_play: false,
        loop_play: false
      )
    end

    let(:menu_command) do
      jukebox # Force jukebox creation first
      described_class.new(character_instance)
    end

    it 'opens media GUI with jukebox available' do
      result = menu_command.execute('media')

      expect(result[:type]).to eq(:open_gui)
      expect(result[:data][:gui]).to eq('media')
    end
  end

  describe 'time parsing' do
    it 'parses MM:SS format' do
      result = subject.send(:parse_time_string, '1:30')
      expect(result).to eq(90)
    end

    it 'parses HH:MM:SS format' do
      result = subject.send(:parse_time_string, '1:30:45')
      expect(result).to eq(5445)
    end

    it 'parses plain seconds' do
      result = subject.send(:parse_time_string, '120')
      expect(result).to eq(120)
    end

    it 'returns nil for empty string' do
      expect(subject.send(:parse_time_string, '')).to be_nil
      expect(subject.send(:parse_time_string, '  ')).to be_nil
    end

    it 'returns nil for non-numeric strings' do
      expect(subject.send(:parse_time_string, 'abc')).to be_nil
      expect(subject.send(:parse_time_string, '1:ab')).to be_nil
    end

    it 'returns nil for too many colons' do
      expect(subject.send(:parse_time_string, '1:2:3:4')).to be_nil
    end

    it 'returns nil for invalid minute/second values' do
      expect(subject.send(:parse_time_string, '1:60')).to be_nil  # seconds > 59
      expect(subject.send(:parse_time_string, '1:60:30')).to be_nil  # minutes > 59
      expect(subject.send(:parse_time_string, '1:30:60')).to be_nil  # seconds > 59
    end

    it 'returns nil for excessively long duration' do
      expect(subject.send(:parse_time_string, '100000')).to be_nil  # > 86400
      expect(subject.send(:parse_time_string, '25:00:00')).to be_nil  # > 24 hours
    end

    it 'handles zero values' do
      expect(subject.send(:parse_time_string, '0')).to eq(0)
      expect(subject.send(:parse_time_string, '0:00')).to eq(0)
      expect(subject.send(:parse_time_string, '0:0:0')).to eq(0)
    end

    it 'handles leading zeros' do
      expect(subject.send(:parse_time_string, '01:05')).to eq(65)
      expect(subject.send(:parse_time_string, '001:05:09')).to eq(3909)
    end
  end

  describe 'time formatting' do
    it 'formats seconds as MM:SS' do
      expect(subject.send(:format_duration_seconds, 90)).to eq('1:30')
      expect(subject.send(:format_duration_seconds, 65)).to eq('1:05')
      expect(subject.send(:format_duration_seconds, 3600)).to eq('60:00')
    end

    it 'pads seconds with zero' do
      expect(subject.send(:format_duration_seconds, 5)).to eq('0:05')
      expect(subject.send(:format_duration_seconds, 60)).to eq('1:00')
    end

    it 'handles zero' do
      expect(subject.send(:format_duration_seconds, 0)).to eq('0:00')
    end
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('media')
    end

    it 'has aliases' do
      aliases = described_class.aliases
      alias_names = aliases.map { |a| a[:name] }
      expect(alias_names).to include('mc')
      expect(alias_names).to include('watchparty')
      expect(alias_names).to include('share')
      expect(alias_names).to include('player')
      expect(alias_names).to include('jukebox')
      expect(alias_names).to include('playlist')
    end

    it 'has help text' do
      expect(described_class.help_text).to be_a(String)
      expect(described_class.help_text).not_to be_empty
    end

    it 'belongs to entertainment category' do
      expect(described_class.category).to eq(:entertainment)
    end
  end

  # ========== Edge Case Tests ==========

  describe 'action aliases' do
    before do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        youtube_duration_seconds: 300,
        status: 'active',
        is_playing: false
      )
    end

    it 'handles resume as alias for play' do
      result = subject.execute('media resume')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Resumed')
    end

    it 'handles skip as alias for seek' do
      result = subject.execute('media skip 1:00')

      expect(result[:success]).to be true
      expect(result[:data][:position]).to eq(60)
    end

    it 'handles goto as alias for seek' do
      result = subject.execute('media goto 2:00')

      expect(result[:success]).to be true
      expect(result[:data][:position]).to eq(120)
    end
  end

  describe 'MediaSyncService error handling' do
    before do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        youtube_duration_seconds: 300,
        status: 'active',
        is_playing: false
      )
    end

    context 'when play fails' do
      before do
        allow(MediaSyncService).to receive(:play).and_return({ success: false, error: 'Playback failed' })
      end

      it 'returns the error' do
        result = subject.execute('media play')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Playback failed')
      end
    end

    context 'when pause fails' do
      before do
        MediaSession.active_in_room(room.id).update(is_playing: true, playback_started_at: Time.now)
        allow(MediaSyncService).to receive(:pause).and_return({ success: false, error: 'Pause failed' })
      end

      it 'returns the error' do
        result = subject.execute('media pause')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Pause failed')
      end
    end

    context 'when seek fails' do
      before do
        allow(MediaSyncService).to receive(:seek).and_return({ success: false, error: 'Seek failed' })
      end

      it 'returns the error' do
        result = subject.execute('media seek 1:30')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Seek failed')
      end
    end
  end

  describe 'can_edit_playlist? permission check' do
    let(:jukebox) do
      Jukebox.create(
        room_id: room.id,
        name: 'Test Jukebox',
        shuffle_play: false,
        loop_play: false
      )
    end

    let(:perm_command) do
      jukebox # Force jukebox creation first
      described_class.new(character_instance)
    end

    context 'when character owns the room' do
      before do
        # Mock on the command's location, not the test's room variable
        allow_any_instance_of(Room).to receive(:owned_by?).with(character).and_return(true)
      end

      it 'allows editing' do
        result = perm_command.send(:can_edit_playlist?)
        expect(result).to be true
      end
    end

    context 'when character is staff' do
      before do
        allow_any_instance_of(Room).to receive(:owned_by?).and_return(false)
        allow(character).to receive(:staff?).and_return(true)
      end

      it 'allows editing' do
        result = perm_command.send(:can_edit_playlist?)
        expect(result).to be true
      end
    end

    context 'when character is neither owner nor staff' do
      before do
        allow_any_instance_of(Room).to receive(:owned_by?).and_return(false)
        allow(character).to receive(:staff?).and_return(false)
      end

      it 'denies editing' do
        result = perm_command.send(:can_edit_playlist?)
        expect(result).to be false
      end
    end
  end

  describe 'session status edge cases' do
    context 'with nil host character' do
      before do
        session = MediaSession.create(
          room_id: room.id,
          host_id: character_instance.id,
          session_type: 'youtube',
          youtube_video_id: 'test123',
          status: 'active',
          is_playing: true
        )
        # Simulate host being nil
        allow_any_instance_of(MediaSession).to receive(:host).and_return(nil)
      end

      it 'handles nil host gracefully in status' do
        result = subject.execute('media status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Someone')
      end
    end

    context 'with nil youtube_title' do
      before do
        MediaSession.create(
          room_id: room.id,
          host_id: character_instance.id,
          session_type: 'youtube',
          youtube_video_id: 'test123',
          youtube_title: nil,
          youtube_duration_seconds: 300,
          status: 'active',
          is_playing: false
        )
      end

      it 'shows fallback title' do
        result = subject.execute('media status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('YouTube Video')
      end
    end

    context 'with nil youtube_duration' do
      before do
        MediaSession.create(
          room_id: room.id,
          host_id: character_instance.id,
          session_type: 'youtube',
          youtube_video_id: 'test123',
          youtube_title: 'Test',
          youtube_duration_seconds: nil,
          status: 'active',
          is_playing: false
        )
      end

      it 'omits duration in status' do
        result = subject.execute('media status')

        expect(result[:success]).to be true
        # Should only show position, not duration
        expect(result[:message]).not_to include('/')
      end
    end
  end

  describe 'share status with nil values' do
    context 'with nil share_type in share status' do
      before do
        MediaSession.create(
          room_id: room.id,
          host_id: character_instance.id,
          session_type: 'screen_share',
          peer_id: 'test-peer',
          share_type: nil,
          status: 'active',
          is_playing: true
        )
      end

      it 'uses fallback for nil share_type' do
        result = subject.execute('share status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('content')
      end
    end

    context 'when viewer views someone elses nil share_type' do
      let(:host_character) { create_test_character(forename: 'Host', surname: 'User') }
      let(:host_instance) { create_test_character_instance(character: host_character, room: room, reality: reality) }

      before do
        MediaSession.create(
          room_id: room.id,
          host_id: host_instance.id,
          session_type: 'screen_share',
          peer_id: 'test-peer',
          share_type: nil,
          status: 'active',
          is_playing: true
        )
      end

      it 'uses fallback for viewer' do
        result = subject.execute('share status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('screen')
      end
    end
  end

  describe 'seek edge cases' do
    before do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        youtube_duration_seconds: nil, # No known duration
        status: 'active',
        is_playing: false
      )
    end

    it 'allows seeking when duration is unknown' do
      result = subject.execute('media seek 5:00')

      expect(result[:success]).to be true
      expect(result[:data][:position]).to eq(300)
    end
  end

  describe 'playlist track without duration' do
    let(:jukebox) do
      Jukebox.create(
        room_id: room.id,
        name: 'Test Jukebox'
      )
    end

    let(:playlist_command) do
      jukebox
      cmd = described_class.new(character_instance)
      allow(cmd).to receive(:can_edit_playlist?).and_return(true)
      cmd
    end

    before do
      jukebox.add_track!(url: 'https://youtube.com/watch?v=abc', title: 'No Duration Track', duration_seconds: nil)
    end

    it 'shows track without duration' do
      result = playlist_command.execute('playlist')

      expect(result[:success]).to be true
      expect(result[:message]).to include('No Duration Track')
      expect(result[:message]).not_to include('(')
    end
  end

  # ========== Additional Edge Case Tests ==========

  describe 'mc alias routing' do
    it 'routes mc to media menu' do
      result = subject.execute('mc')

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:open_gui)
    end

    it 'routes mc play to play action' do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        status: 'active',
        is_playing: false
      )

      result = subject.execute('mc play')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Resumed')
    end
  end

  describe 'watchparty alias routing' do
    it 'routes watchparty to media menu' do
      result = subject.execute('watchparty')

      expect(result[:success]).to be true
      expect(result[:type]).to eq(:open_gui)
    end
  end

  describe 'media screen and media tab shortcuts' do
    it 'routes media screen to share screen' do
      result = subject.execute('media screen')

      expect(result[:success]).to be true
      expect(result[:data][:action]).to eq('start_screen_share')
    end

    it 'routes media tab to share tab' do
      result = subject.execute('media tab')

      expect(result[:success]).to be true
      expect(result[:data][:action]).to eq('start_tab_share')
    end
  end

  describe 'media jukebox routing' do
    let(:jukebox) do
      Jukebox.create(
        room_id: room.id,
        name: 'Routed Jukebox'
      )
    end

    let(:jukebox_command) do
      jukebox
      described_class.new(character_instance)
    end

    it 'routes media jukebox to player handler' do
      result = jukebox_command.execute('media jukebox')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Routed Jukebox')
    end
  end

  describe 'playlist clear with empty playlist' do
    let(:jukebox) do
      Jukebox.create(
        room_id: room.id,
        name: 'Empty Jukebox'
      )
    end

    let(:playlist_command) do
      jukebox
      cmd = described_class.new(character_instance)
      allow(cmd).to receive(:can_edit_playlist?).and_return(true)
      cmd
    end

    it 'clears zero tracks' do
      result = playlist_command.execute('playlist clear')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Cleared 0 tracks')
    end
  end

  describe 'playlist remove with negative position' do
    let(:jukebox) do
      Jukebox.create(
        room_id: room.id,
        name: 'Negative Test Jukebox'
      )
    end

    let(:playlist_command) do
      jukebox
      cmd = described_class.new(character_instance)
      allow(cmd).to receive(:can_edit_playlist?).and_return(true)
      cmd
    end

    it 'returns error for negative position' do
      result = playlist_command.execute('playlist remove -1')

      expect(result[:success]).to be false
      expect(result[:error]).to include('valid track number')
    end
  end

  describe 'seek with plain seconds' do
    before do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        youtube_duration_seconds: 600,
        status: 'active',
        is_playing: false
      )
    end

    it 'seeks to position using plain seconds' do
      result = subject.execute('media seek 120')

      expect(result[:success]).to be true
      expect(result[:data][:position]).to eq(120)
      expect(result[:message]).to include('2:00')
    end
  end

  describe 'viewer count in session status' do
    before do
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        youtube_title: 'Test Video',
        youtube_duration_seconds: 300,
        status: 'active',
        is_playing: true
      )
    end

    it 'shows viewer count in youtube status' do
      result = subject.execute('media status')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Viewers')
    end

    it 'shows viewer count in share status as host' do
      MediaSession.active_in_room(room.id)&.destroy
      MediaSession.create(
        room_id: room.id,
        host_id: character_instance.id,
        session_type: 'screen_share',
        share_type: 'screen',
        peer_id: 'test-peer-123',
        status: 'active',
        is_playing: true
      )

      result = subject.execute('share status')

      expect(result[:success]).to be true
      expect(result[:message]).to include('viewer')
    end
  end

  describe 'host name fallback in error messages' do
    let(:other_character) { create_test_character(forename: 'Session', surname: 'Host') }
    let(:other_instance) { create_test_character_instance(character: other_character, room: room, reality: reality) }

    before do
      MediaSession.create(
        room_id: room.id,
        host_id: other_instance.id,
        session_type: 'youtube',
        youtube_video_id: 'test123',
        status: 'active',
        is_playing: false
      )
    end

    context 'when host has nil character' do
      before do
        allow_any_instance_of(MediaSession).to receive(:host).and_return(double(character: nil))
      end

      it 'uses the host fallback in play error' do
        result = subject.execute('media play')

        expect(result[:success]).to be false
        expect(result[:error]).to include('the host')
      end

      it 'uses the host fallback in pause error' do
        MediaSession.active_in_room(room.id).update(is_playing: true)
        result = subject.execute('media pause')

        expect(result[:success]).to be false
        expect(result[:error]).to include('the host')
      end

      it 'uses the host fallback in seek error' do
        result = subject.execute('media seek 1:00')

        expect(result[:success]).to be false
        expect(result[:error]).to include('the host')
      end

      it 'uses the host fallback in stop error' do
        result = subject.execute('media stop')

        expect(result[:success]).to be false
        expect(result[:error]).to include('the host')
      end
    end
  end

  describe 'nested room playlist permissions' do
    let(:jukebox) do
      Jukebox.create(
        room_id: room.id,
        name: 'Nested Test Jukebox'
      )
    end

    let(:nested_command) do
      jukebox
      cmd = described_class.new(character_instance)
      # Mock the location method to return a room with nested behavior
      outer = double('outer_room')
      inner = double('inner_room')
      allow(inner).to receive(:respond_to?).with(:inside_room).and_return(true)
      allow(inner).to receive(:inside_room).and_return(outer)
      allow(outer).to receive(:respond_to?).with(:inside_room).and_return(false)
      allow(cmd).to receive(:location).and_return(inner)
      allow(outer).to receive(:owned_by?).with(character).and_return(true)
      cmd
    end

    it 'traverses to outer room for ownership check' do
      result = nested_command.send(:can_edit_playlist?)
      expect(result).to be true
    end

    it 'denies when not owner of outer room' do
      outer = double('outer_room')
      inner = double('inner_room')
      allow(inner).to receive(:respond_to?).with(:inside_room).and_return(true)
      allow(inner).to receive(:inside_room).and_return(outer)
      allow(outer).to receive(:respond_to?).with(:inside_room).and_return(false)
      allow(outer).to receive(:owned_by?).with(character).and_return(false)
      allow(character).to receive(:staff?).and_return(false)

      cmd = described_class.new(character_instance)
      jukebox # ensure jukebox exists
      allow(cmd).to receive(:location).and_return(inner)

      result = cmd.send(:can_edit_playlist?)
      expect(result).to be false
    end
  end

  describe 'media menu options visibility' do
    context 'with session that is playing' do
      before do
        MediaSession.create(
          room_id: room.id,
          host_id: character_instance.id,
          session_type: 'youtube',
          youtube_video_id: 'test123',
          status: 'active',
          is_playing: true
        )
      end

      it 'opens media GUI when playing' do
        result = subject.execute('media')

        expect(result[:type]).to eq(:open_gui)
        expect(result[:data][:gui]).to eq('media')
      end
    end

    context 'with session that is paused' do
      before do
        MediaSession.create(
          room_id: room.id,
          host_id: character_instance.id,
          session_type: 'youtube',
          youtube_video_id: 'test123',
          status: 'active',
          is_playing: false
        )
      end

      it 'opens media GUI when paused' do
        result = subject.execute('media')

        expect(result[:type]).to eq(:open_gui)
        expect(result[:data][:gui]).to eq('media')
      end
    end
  end

  describe 'jukebox status display modes' do
    let(:jukebox) do
      Jukebox.create(
        room_id: room.id,
        name: 'Mode Jukebox',
        shuffle_play: true,
        loop_play: false
      )
    end

    let(:jukebox_command) do
      jukebox
      described_class.new(character_instance)
    end

    it 'shows shuffle mode only when enabled' do
      result = jukebox_command.execute('player')

      # Check the status line has [shuffle] but not [shuffle, loop]
      expect(result[:message]).to include('[shuffle]')
      expect(result[:message]).not_to include('[shuffle, loop]')
    end

    it 'shows both modes when both enabled' do
      jukebox.update(shuffle_play: true, loop_play: true)
      result = jukebox_command.execute('player')

      expect(result[:message]).to include('[shuffle, loop]')
    end

    it 'shows no mode brackets when neither enabled' do
      jukebox.update(shuffle_play: false, loop_play: false)
      result = jukebox_command.execute('player')

      # The status line should not have mode indicators (but Controls line has [...])
      expect(result[:message]).to match(/Mode Jukebox - Stopped\n/)
    end
  end

  describe 'playlist loop status display' do
    let(:jukebox) do
      Jukebox.create(
        room_id: room.id,
        name: 'Loop Jukebox',
        loop_play: true,
        shuffle_play: false
      )
    end

    let(:playlist_command) do
      jukebox
      cmd = described_class.new(character_instance)
      allow(cmd).to receive(:can_edit_playlist?).and_return(true)
      jukebox.add_track!(url: 'https://youtube.com/watch?v=abc', title: 'Track')
      cmd
    end

    it 'shows loop mode in playlist status' do
      result = playlist_command.execute('playlist')

      expect(result[:message]).to include('loop')
      expect(result[:message]).not_to include('shuffle')
    end

    it 'shows both modes when both enabled' do
      jukebox.update(shuffle_play: true)
      result = playlist_command.execute('playlist')

      expect(result[:message]).to include('shuffle')
      expect(result[:message]).to include('loop')
    end
  end
end
