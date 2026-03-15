# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MediaPlaylistItem do
  let(:character) { create(:character) }
  let(:playlist) { MediaPlaylist.create(character_id: character.id, name: 'Test Playlist') }

  describe 'validations' do
    it 'requires media_playlist_id' do
      item = described_class.new(youtube_video_id: 'abc123', position: 0)
      expect(item.valid?).to be false
      expect(item.errors[:media_playlist_id]).to include('is not present')
    end

    it 'requires youtube_video_id' do
      item = described_class.new(media_playlist_id: playlist.id, position: 0)
      expect(item.valid?).to be false
      expect(item.errors[:youtube_video_id]).to include('is not present')
    end

    it 'requires position' do
      item = described_class.new(media_playlist_id: playlist.id, youtube_video_id: 'abc123', position: nil)
      expect(item.valid?).to be false
      expect(item.errors[:position]).to include('is not present')
    end

    it 'validates youtube_video_id max length' do
      item = described_class.new(media_playlist_id: playlist.id, youtube_video_id: 'A' * 21, position: 0)
      expect(item.valid?).to be false
      expect(item.errors[:youtube_video_id]).not_to be_empty
    end

    it 'accepts valid item' do
      item = described_class.new(media_playlist_id: playlist.id, youtube_video_id: 'dQw4w9WgXcQ', position: 0)
      expect(item.valid?).to be true
    end
  end

  describe 'associations' do
    it 'belongs to media_playlist' do
      item = playlist.add_item!(youtube_video_id: 'abc123')
      expect(item.media_playlist).to eq(playlist)
    end
  end

  describe '#display_title' do
    it 'returns title when present' do
      item = playlist.add_item!(youtube_video_id: 'abc123', title: 'My Video')
      expect(item.display_title).to eq('My Video')
    end

    it 'returns fallback when title is nil' do
      item = playlist.add_item!(youtube_video_id: 'abc123')
      expect(item.display_title).to eq('Video 1')
    end

    it 'returns fallback when title is empty' do
      item = playlist.add_item!(youtube_video_id: 'abc123', title: '')
      expect(item.display_title).to eq('Video 1')
    end
  end

  describe '#to_hash' do
    it 'returns hash with all fields' do
      item = playlist.add_item!(
        youtube_video_id: 'dQw4w9WgXcQ',
        title: 'Test',
        thumbnail_url: 'https://example.com/thumb.jpg',
        duration_seconds: 212,
        is_embeddable: true
      )

      hash = item.to_hash
      expect(hash[:id]).to eq(item.id)
      expect(hash[:youtube_video_id]).to eq('dQw4w9WgXcQ')
      expect(hash[:title]).to eq('Test')
      expect(hash[:thumbnail_url]).to eq('https://example.com/thumb.jpg')
      expect(hash[:duration_seconds]).to eq(212)
      expect(hash[:is_embeddable]).to be true
      expect(hash[:position]).to eq(0)
    end
  end
end
