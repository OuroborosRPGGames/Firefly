# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Jukebox do
  let(:room) { create(:room) }
  let(:character) { create(:character) }

  describe 'validations' do
    it 'requires room_id' do
      jukebox = described_class.new(name: 'Test Jukebox')
      expect(jukebox.valid?).to be false
      expect(jukebox.errors[:room_id]).to include('is not present')
    end

    it 'requires name' do
      jukebox = described_class.new(room_id: room.id)
      expect(jukebox.valid?).to be false
      expect(jukebox.errors[:name]).to include('is not present')
    end

    it 'validates name max length' do
      jukebox = described_class.new(room_id: room.id, name: 'A' * 101)
      expect(jukebox.valid?).to be false
      expect(jukebox.errors[:name]).not_to be_empty
    end

    it 'validates unique room_id' do
      described_class.create(room_id: room.id, name: 'First Jukebox')

      duplicate = described_class.new(room_id: room.id, name: 'Second Jukebox')
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:room_id]).to include('already has a jukebox')
    end

    it 'accepts valid jukebox' do
      jukebox = described_class.new(room_id: room.id, name: 'Valid Jukebox')
      expect(jukebox.valid?).to be true
    end
  end

  describe 'associations' do
    let(:jukebox) { described_class.create(room_id: room.id, name: 'Test Jukebox', created_by_id: character.id) }

    it 'belongs to room' do
      expect(jukebox.room).to eq(room)
    end

    it 'belongs to created_by' do
      expect(jukebox.created_by).to eq(character)
    end

    it 'has many tracks' do
      expect(jukebox.tracks).to eq([])
    end
  end

  describe '#play!' do
    let(:jukebox) { described_class.create(room_id: room.id, name: 'Test Jukebox') }

    it 'sets currently_playing to 0' do
      jukebox.play!
      expect(jukebox.currently_playing).to eq(0)
    end

    it 'sets next_play to current time' do
      jukebox.play!
      expect(jukebox.next_play).to be_within(5).of(Time.now)
    end
  end

  describe '#stop!' do
    let(:jukebox) { described_class.create(room_id: room.id, name: 'Test Jukebox', currently_playing: 0) }

    it 'sets currently_playing to nil' do
      jukebox.stop!
      expect(jukebox.currently_playing).to be_nil
    end

    it 'sets next_play to nil' do
      jukebox.stop!
      expect(jukebox.next_play).to be_nil
    end
  end

  describe '#playing?' do
    let(:jukebox) { described_class.create(room_id: room.id, name: 'Test Jukebox') }

    it 'returns false when currently_playing is nil' do
      expect(jukebox.playing?).to be false
    end

    it 'returns true when currently_playing is set' do
      jukebox.update(currently_playing: 0)
      expect(jukebox.playing?).to be true
    end
  end

  describe '#toggle_shuffle!' do
    let(:jukebox) { described_class.create(room_id: room.id, name: 'Test Jukebox', shuffle_play: false) }

    it 'toggles shuffle_play from false to true' do
      jukebox.toggle_shuffle!
      expect(jukebox.shuffle_play).to be true
    end

    it 'toggles shuffle_play from true to false' do
      jukebox.update(shuffle_play: true)
      jukebox.toggle_shuffle!
      expect(jukebox.shuffle_play).to be false
    end
  end

  describe '#toggle_loop!' do
    let(:jukebox) { described_class.create(room_id: room.id, name: 'Test Jukebox', loop_play: false) }

    it 'toggles loop_play from false to true' do
      jukebox.toggle_loop!
      expect(jukebox.loop_play).to be true
    end

    it 'toggles loop_play from true to false' do
      jukebox.update(loop_play: true)
      jukebox.toggle_loop!
      expect(jukebox.loop_play).to be false
    end
  end

  describe '#current_track' do
    let(:jukebox) { described_class.create(room_id: room.id, name: 'Test Jukebox') }

    it 'returns nil when not playing' do
      expect(jukebox.current_track).to be_nil
    end

    it 'returns the track at currently_playing position' do
      track = JukeboxTrack.create(jukebox_id: jukebox.id, url: 'https://example.com/song.mp3', position: 0)
      jukebox.update(currently_playing: 0)

      expect(jukebox.current_track).to eq(track)
    end
  end

  describe '#add_track!' do
    let(:jukebox) { described_class.create(room_id: room.id, name: 'Test Jukebox') }

    it 'creates a new track' do
      track = jukebox.add_track!(url: 'https://example.com/song.mp3')

      expect(track.id).not_to be_nil
      expect(track.url).to eq('https://example.com/song.mp3')
    end

    it 'assigns position incrementally' do
      track1 = jukebox.add_track!(url: 'https://example.com/song1.mp3')
      track2 = jukebox.add_track!(url: 'https://example.com/song2.mp3')

      expect(track1.position).to eq(0)
      expect(track2.position).to eq(1)
    end

    it 'accepts optional title' do
      track = jukebox.add_track!(url: 'https://example.com/song.mp3', title: 'My Song')
      expect(track.title).to eq('My Song')
    end

    it 'accepts optional duration' do
      track = jukebox.add_track!(url: 'https://example.com/song.mp3', duration_seconds: 180)
      expect(track.duration_seconds).to eq(180)
    end
  end

  describe '#remove_track!' do
    let(:jukebox) { described_class.create(room_id: room.id, name: 'Test Jukebox') }

    before do
      jukebox.add_track!(url: 'https://example.com/song1.mp3')
      jukebox.add_track!(url: 'https://example.com/song2.mp3')
      jukebox.add_track!(url: 'https://example.com/song3.mp3')
    end

    it 'removes the track at given position' do
      jukebox.remove_track!(1)
      expect(jukebox.tracks_dataset.where(position: 1).count).to eq(0)
    end
  end

  describe '#clear_tracks!' do
    let(:jukebox) { described_class.create(room_id: room.id, name: 'Test Jukebox') }

    before do
      jukebox.add_track!(url: 'https://example.com/song1.mp3')
      jukebox.add_track!(url: 'https://example.com/song2.mp3')
    end

    it 'removes all tracks' do
      jukebox.clear_tracks!
      expect(jukebox.track_count).to eq(0)
    end
  end

  describe '#track_count' do
    let(:jukebox) { described_class.create(room_id: room.id, name: 'Test Jukebox') }

    it 'returns 0 when no tracks' do
      expect(jukebox.track_count).to eq(0)
    end

    it 'returns correct count with tracks' do
      jukebox.add_track!(url: 'https://example.com/song1.mp3')
      jukebox.add_track!(url: 'https://example.com/song2.mp3')

      expect(jukebox.track_count).to eq(2)
    end
  end

  describe '#next_track!' do
    let(:jukebox) { described_class.create(room_id: room.id, name: 'Test Jukebox') }

    before do
      jukebox.add_track!(url: 'https://example.com/song1.mp3')
      jukebox.add_track!(url: 'https://example.com/song2.mp3')
      jukebox.add_track!(url: 'https://example.com/song3.mp3')
    end

    context 'when not playing' do
      it 'does nothing' do
        jukebox.next_track!
        expect(jukebox.currently_playing).to be_nil
      end
    end

    context 'when playing without shuffle' do
      before { jukebox.play! }

      it 'advances to next position' do
        jukebox.next_track!
        expect(jukebox.currently_playing).to eq(1)
      end

      context 'at end of playlist' do
        before { jukebox.update(currently_playing: 2) }

        it 'stops when loop is off' do
          jukebox.next_track!
          expect(jukebox.playing?).to be false
        end

        it 'loops to beginning when loop is on' do
          jukebox.update(loop_play: true)
          jukebox.next_track!
          expect(jukebox.currently_playing).to eq(0)
        end
      end
    end

    context 'when playing with shuffle' do
      before do
        jukebox.update(shuffle_play: true)
        jukebox.play!
      end

      it 'selects a different track' do
        jukebox.next_track!
        expect(jukebox.currently_playing).not_to be_nil
      end
    end
  end

  describe '#status_text' do
    let(:jukebox) { described_class.create(room_id: room.id, name: 'Test Jukebox') }

    context 'when not playing' do
      it 'returns Stopped' do
        expect(jukebox.status_text).to eq('Stopped')
      end
    end

    context 'when playing' do
      before do
        jukebox.add_track!(url: 'https://example.com/song.mp3', title: 'Awesome Song')
        jukebox.play!
      end

      it 'shows current track title' do
        expect(jukebox.status_text).to include('Awesome Song')
      end

      it 'shows shuffle mode when enabled' do
        jukebox.update(shuffle_play: true)
        expect(jukebox.status_text).to include('shuffle')
      end

      it 'shows loop mode when enabled' do
        jukebox.update(loop_play: true)
        expect(jukebox.status_text).to include('loop')
      end

      it 'shows both modes when enabled' do
        jukebox.update(shuffle_play: true, loop_play: true)
        expect(jukebox.status_text).to include('shuffle')
        expect(jukebox.status_text).to include('loop')
      end
    end
  end
end
