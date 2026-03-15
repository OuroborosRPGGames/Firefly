# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JukeboxTrack do
  let(:room) { create(:room) }
  let(:jukebox) { Jukebox.create(room_id: room.id, name: 'Test Jukebox') }

  describe 'associations' do
    it 'belongs to jukebox' do
      track = JukeboxTrack.new(jukebox_id: jukebox.id)
      expect(track.jukebox).to eq(jukebox)
    end
  end

  describe 'validations' do
    it 'requires jukebox_id' do
      track = JukeboxTrack.new(url: 'https://example.com', position: 0)
      expect(track.valid?).to be false
      expect(track.errors[:jukebox_id]).not_to be_empty
    end

    it 'requires url' do
      track = JukeboxTrack.new(jukebox_id: jukebox.id, position: 0)
      expect(track.valid?).to be false
      expect(track.errors[:url]).not_to be_empty
    end

    it 'requires position' do
      track = JukeboxTrack.new(jukebox_id: jukebox.id, url: 'https://example.com')
      expect(track.valid?).to be false
      expect(track.errors[:position]).not_to be_empty
    end

    it 'is valid with all required fields' do
      track = JukeboxTrack.new(jukebox_id: jukebox.id, url: 'https://example.com', position: 0)
      expect(track.valid?).to be true
    end
  end

  describe '#youtube?' do
    it 'returns true for youtube.com URLs' do
      track = JukeboxTrack.new(url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ')
      expect(track.youtube?).to be true
    end

    it 'returns true for youtu.be URLs' do
      track = JukeboxTrack.new(url: 'https://youtu.be/dQw4w9WgXcQ')
      expect(track.youtube?).to be true
    end

    it 'returns false for non-YouTube URLs' do
      track = JukeboxTrack.new(url: 'https://vimeo.com/123456')
      expect(track.youtube?).to be false
    end

    it 'returns false for SoundCloud URLs' do
      track = JukeboxTrack.new(url: 'https://soundcloud.com/artist/track')
      expect(track.youtube?).to be false
    end
  end

  describe '#youtube_video_id' do
    it 'extracts video ID from youtube.com/watch URL' do
      track = JukeboxTrack.new(url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ')
      expect(track.youtube_video_id).to eq('dQw4w9WgXcQ')
    end

    it 'extracts video ID from youtube.com/watch URL with additional params' do
      track = JukeboxTrack.new(url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=30s')
      expect(track.youtube_video_id).to eq('dQw4w9WgXcQ')
    end

    it 'extracts video ID from youtu.be URL' do
      track = JukeboxTrack.new(url: 'https://youtu.be/dQw4w9WgXcQ')
      expect(track.youtube_video_id).to eq('dQw4w9WgXcQ')
    end

    it 'extracts video ID from youtu.be URL with params' do
      track = JukeboxTrack.new(url: 'https://youtu.be/dQw4w9WgXcQ?t=30')
      expect(track.youtube_video_id).to eq('dQw4w9WgXcQ')
    end

    it 'extracts video ID from youtube.com/embed URL' do
      track = JukeboxTrack.new(url: 'https://www.youtube.com/embed/dQw4w9WgXcQ')
      expect(track.youtube_video_id).to eq('dQw4w9WgXcQ')
    end

    it 'extracts video ID from youtube.com/embed URL with params' do
      track = JukeboxTrack.new(url: 'https://www.youtube.com/embed/dQw4w9WgXcQ?autoplay=1')
      expect(track.youtube_video_id).to eq('dQw4w9WgXcQ')
    end

    it 'returns nil for non-YouTube URLs' do
      track = JukeboxTrack.new(url: 'https://vimeo.com/123456')
      expect(track.youtube_video_id).to be_nil
    end
  end

  describe '#embed_url' do
    it 'returns embed URL for youtube.com/watch URL' do
      track = JukeboxTrack.new(url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ')
      expect(track.embed_url).to eq('https://www.youtube.com/embed/dQw4w9WgXcQ')
    end

    it 'returns embed URL for youtu.be URL' do
      track = JukeboxTrack.new(url: 'https://youtu.be/dQw4w9WgXcQ')
      expect(track.embed_url).to eq('https://www.youtube.com/embed/dQw4w9WgXcQ')
    end

    it 'returns original URL for non-YouTube URLs' do
      track = JukeboxTrack.new(url: 'https://vimeo.com/123456')
      expect(track.embed_url).to eq('https://vimeo.com/123456')
    end

    it 'returns original URL if video ID cannot be extracted' do
      track = JukeboxTrack.new(url: 'https://youtube.com/invalid')
      expect(track.embed_url).to eq('https://youtube.com/invalid')
    end
  end

  describe '#display_title' do
    it 'returns title when set' do
      track = JukeboxTrack.new(title: 'My Favorite Song', position: 2)
      expect(track.display_title).to eq('My Favorite Song')
    end

    it 'returns "Track N" when title is nil' do
      track = JukeboxTrack.new(position: 2)
      expect(track.display_title).to eq('Track 3')
    end

    it 'returns "Track N" when title is empty' do
      track = JukeboxTrack.new(title: '', position: 0)
      expect(track.display_title).to eq('Track 1')
    end

    it 'uses 1-indexed position for display' do
      track = JukeboxTrack.new(position: 0)
      expect(track.display_title).to eq('Track 1')
    end
  end
end
