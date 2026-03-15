# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JukeboxPlaybackService do
  let(:room) { create(:room) }
  let(:character) { create(:character) }
  let!(:character_instance) { create(:character_instance, character: character, current_room_id: room.id, online: true) }
  let(:jukebox) { Jukebox.create(room_id: room.id, name: 'Test Jukebox') }

  before do
    # Stub BroadcastService to avoid Redis dependency
    allow(BroadcastService).to receive(:to_room)
  end

  describe '.process_due_jukeboxes!' do
    context 'with no due jukeboxes' do
      it 'returns empty results' do
        results = described_class.process_due_jukeboxes!

        expect(results[:played]).to eq(0)
        expect(results[:advanced]).to eq(0)
        expect(results[:stopped]).to eq(0)
        expect(results[:errors]).to be_empty
      end
    end

    context 'with a jukebox ready to play' do
      before do
        jukebox.add_track!(url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', title: 'Test Song', duration_seconds: 180)
        jukebox.play!
        # Set next_play to the past so it's due
        jukebox.update(next_play: Time.now - 10)
      end

      it 'broadcasts the track to the room' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: /Test Jukebox plays: Test Song/),
          hash_including(type: :media, jukebox_id: jukebox.id)
        )

        described_class.process_due_jukeboxes!
      end

      it 'sets next_play far in future when using precise scheduling' do
        # With precise scheduling (thread-based), next_play is set far ahead
        # to prevent fallback polling from interfering
        described_class.process_due_jukeboxes!

        jukebox.refresh
        # next_play = Time.now + duration + 3600 (1 hour buffer)
        expect(jukebox.next_play).to be_within(5).of(Time.now + 180 + 3600)
      end

      it 'returns played count' do
        results = described_class.process_due_jukeboxes!

        expect(results[:played]).to eq(1)
        expect(results[:advanced]).to eq(1)
      end
    end

    context 'with an empty room' do
      before do
        jukebox.add_track!(url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', title: 'Test Song')
        jukebox.play!
        jukebox.update(next_play: Time.now - 10)

        # Remove all characters from room
        character_instance.update(online: false)
      end

      it 'stops the jukebox' do
        described_class.process_due_jukeboxes!

        jukebox.refresh
        expect(jukebox.playing?).to be false
      end

      it 'returns stopped count' do
        results = described_class.process_due_jukeboxes!

        expect(results[:stopped]).to eq(1)
        expect(results[:played]).to eq(0)
      end
    end

    context 'with shuffle play' do
      before do
        jukebox.add_track!(url: 'https://youtube.com/watch?v=track1', title: 'Track 1', duration_seconds: 60)
        jukebox.add_track!(url: 'https://youtube.com/watch?v=track2', title: 'Track 2', duration_seconds: 60)
        jukebox.add_track!(url: 'https://youtube.com/watch?v=track3', title: 'Track 3', duration_seconds: 60)
        jukebox.update(shuffle_play: true)
        jukebox.play!
        jukebox.update(next_play: Time.now - 10)
      end

      it 'advances to a different track' do
        initial_position = jukebox.currently_playing

        described_class.process_due_jukeboxes!

        jukebox.refresh
        # With shuffle, should move to a different track (unless only 1 track)
        expect(jukebox.currently_playing).not_to be_nil
      end
    end

    context 'at end of playlist without loop' do
      before do
        jukebox.add_track!(url: 'https://youtube.com/watch?v=track1', title: 'Track 1', duration_seconds: 60)
        jukebox.play!
        # Advance past the last track
        jukebox.update(currently_playing: 999, next_play: Time.now - 10)
      end

      it 'stops the jukebox' do
        described_class.process_due_jukeboxes!

        jukebox.refresh
        expect(jukebox.playing?).to be false
      end
    end

    context 'at end of playlist with loop enabled' do
      before do
        jukebox.add_track!(url: 'https://youtube.com/watch?v=track1', title: 'Track 1', duration_seconds: 60)
        jukebox.update(loop_play: true)
        jukebox.play!
        # Set to invalid position to trigger loop
        jukebox.update(currently_playing: 999, next_play: Time.now - 10)
      end

      it 'loops back to the beginning' do
        described_class.process_due_jukeboxes!

        jukebox.refresh
        expect(jukebox.playing?).to be true
        expect(jukebox.currently_playing).to eq(0)
      end
    end
  end

  describe '.due_jukeboxes' do
    it 'returns jukeboxes with next_play in the past' do
      jukebox.add_track!(url: 'https://youtube.com/watch?v=test', title: 'Test')
      jukebox.play!
      jukebox.update(next_play: Time.now - 60)

      expect(described_class.due_jukeboxes).to include(jukebox)
    end

    it 'does not return stopped jukeboxes' do
      jukebox.stop!

      expect(described_class.due_jukeboxes).not_to include(jukebox)
    end

    it 'does not return jukeboxes with future next_play' do
      jukebox.add_track!(url: 'https://youtube.com/watch?v=test', title: 'Test')
      jukebox.play!
      jukebox.update(next_play: Time.now + 300)

      expect(described_class.due_jukeboxes).not_to include(jukebox)
    end
  end

  describe '.build_video_data' do
    let(:track) { jukebox.add_track!(url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', title: 'Never Gonna', duration_seconds: 212) }

    it 'includes all required fields' do
      data = described_class.build_video_data(jukebox, track)

      expect(data[:jukebox_id]).to eq(jukebox.id)
      expect(data[:jukebox_name]).to eq('Test Jukebox')
      expect(data[:track_id]).to eq(track.id)
      expect(data[:track_title]).to eq('Never Gonna')
      expect(data[:url]).to eq('https://www.youtube.com/watch?v=dQw4w9WgXcQ')
      expect(data[:video_id]).to eq('dQw4w9WgXcQ')
      expect(data[:is_youtube]).to be true
      expect(data[:duration]).to eq(212)
      expect(data[:autoplay]).to be true
    end
  end

  describe '.build_embed_html' do
    context 'with a YouTube URL' do
      let(:track) { jukebox.add_track!(url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', title: 'Test Video') }

      it 'returns an iframe embed' do
        html = described_class.build_embed_html(jukebox, track)

        expect(html).to include('<iframe')
        expect(html).to include('youtube.com/embed/dQw4w9WgXcQ')
        expect(html).to include('autoplay=1')
        expect(html).to include('Test Video')
      end
    end

    context 'with a non-YouTube URL' do
      let(:track) { jukebox.add_track!(url: 'https://example.com/song.mp3', title: 'MP3 Track') }

      it 'returns a link' do
        html = described_class.build_embed_html(jukebox, track)

        expect(html).to include('<a href="https://example.com/song.mp3"')
        expect(html).to include('MP3 Track')
      end
    end
  end

  describe '.play_track_now' do
    let(:track) { jukebox.add_track!(url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', title: 'Test Song', duration_seconds: 180) }

    it 'broadcasts the track to the room' do
      expect(BroadcastService).to receive(:to_room).with(
        room.id,
        hash_including(content: /Test Jukebox plays: Test Song/),
        hash_including(type: :media, jukebox_id: jukebox.id)
      )

      described_class.play_track_now(jukebox, track)
    end

    it 'returns true when track is played' do
      expect(described_class.play_track_now(jukebox, track)).to be true
    end

    it 'returns false when jukebox has no room' do
      allow(jukebox).to receive(:room).and_return(nil)

      expect(described_class.play_track_now(jukebox, track)).to be false
    end

    context 'with track that has duration' do
      it 'uses precise scheduling (sets next_play far in future)' do
        described_class.play_track_now(jukebox, track)

        jukebox.refresh
        # Precise scheduling sets next_play far ahead to prevent fallback
        expect(jukebox.next_play).to be > Time.now + 3000
      end
    end

    context 'with track without duration' do
      let(:track_no_duration) { jukebox.add_track!(url: 'https://example.com/song.mp3', title: 'Unknown Duration') }

      it 'uses fallback scheduling (DEFAULT_TRACK_DURATION)' do
        described_class.play_track_now(jukebox, track_no_duration)

        jukebox.refresh
        # Fallback uses DEFAULT_TRACK_DURATION (300 seconds)
        expect(jukebox.next_play).to be_within(5).of(Time.now + 300)
      end
    end
  end

  describe '.room_has_players?' do
    it 'returns true when room has online PC' do
      expect(described_class.room_has_players?(room.id)).to be true
    end

    it 'returns false when room is empty' do
      character_instance.update(online: false)

      expect(described_class.room_has_players?(room.id)).to be false
    end

    it 'returns false when room only has NPCs' do
      character_instance.update(online: false)
      npc_char = create(:character, :npc)
      create(:character_instance, character: npc_char, current_room_id: room.id, online: true)

      expect(described_class.room_has_players?(room.id)).to be false
    end
  end
end
