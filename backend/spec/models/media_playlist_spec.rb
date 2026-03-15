# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MediaPlaylist do
  let(:character) { create(:character) }

  describe 'validations' do
    it 'requires character_id' do
      playlist = described_class.new(name: 'My Playlist')
      expect(playlist.valid?).to be false
      expect(playlist.errors[:character_id]).to include('is not present')
    end

    it 'requires name' do
      playlist = described_class.new(character_id: character.id)
      expect(playlist.valid?).to be false
      expect(playlist.errors[:name]).to include('is not present')
    end

    it 'validates name max length' do
      playlist = described_class.new(character_id: character.id, name: 'A' * 101)
      expect(playlist.valid?).to be false
      expect(playlist.errors[:name]).not_to be_empty
    end

    it 'validates unique name per character' do
      described_class.create(character_id: character.id, name: 'My Playlist')
      duplicate = described_class.new(character_id: character.id, name: 'My Playlist')
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[[:character_id, :name]]).to include('already exists')
    end

    it 'allows same name for different characters' do
      other_character = create(:character)
      described_class.create(character_id: character.id, name: 'My Playlist')
      playlist = described_class.new(character_id: other_character.id, name: 'My Playlist')
      expect(playlist.valid?).to be true
    end

    it 'accepts valid playlist' do
      playlist = described_class.new(character_id: character.id, name: 'My Playlist')
      expect(playlist.valid?).to be true
    end
  end

  describe 'associations' do
    let(:playlist) { described_class.create(character_id: character.id, name: 'Test Playlist') }

    it 'belongs to character' do
      expect(playlist.character).to eq(character)
    end

    it 'has many items' do
      expect(playlist.items).to eq([])
    end
  end

  describe '#add_item!' do
    let(:playlist) { described_class.create(character_id: character.id, name: 'Test Playlist') }

    it 'creates a new item' do
      item = playlist.add_item!(youtube_video_id: 'dQw4w9WgXcQ', title: 'Test Video')
      expect(item.id).not_to be_nil
      expect(item.youtube_video_id).to eq('dQw4w9WgXcQ')
      expect(item.title).to eq('Test Video')
    end

    it 'assigns position incrementally' do
      item1 = playlist.add_item!(youtube_video_id: 'video1')
      item2 = playlist.add_item!(youtube_video_id: 'video2')
      expect(item1.position).to eq(0)
      expect(item2.position).to eq(1)
    end

    it 'accepts all optional attributes' do
      item = playlist.add_item!(
        youtube_video_id: 'dQw4w9WgXcQ',
        title: 'Test',
        thumbnail_url: 'https://img.youtube.com/vi/dQw4w9WgXcQ/0.jpg',
        duration_seconds: 212,
        is_embeddable: false
      )
      expect(item.thumbnail_url).to eq('https://img.youtube.com/vi/dQw4w9WgXcQ/0.jpg')
      expect(item.duration_seconds).to eq(212)
      expect(item.is_embeddable).to be false
    end
  end

  describe '#remove_item!' do
    let(:playlist) { described_class.create(character_id: character.id, name: 'Test Playlist') }

    before do
      playlist.add_item!(youtube_video_id: 'video1', title: 'First')
      playlist.add_item!(youtube_video_id: 'video2', title: 'Second')
      playlist.add_item!(youtube_video_id: 'video3', title: 'Third')
    end

    it 'removes the item at given position and reorders' do
      playlist.remove_item!(1)
      expect(playlist.item_count).to eq(2)
      titles = playlist.items_dataset.order(:position).select_map(:title)
      expect(titles).to eq(%w[First Third])
    end
  end

  describe '#clear_items!' do
    let(:playlist) { described_class.create(character_id: character.id, name: 'Test Playlist') }

    before do
      playlist.add_item!(youtube_video_id: 'video1')
      playlist.add_item!(youtube_video_id: 'video2')
    end

    it 'removes all items' do
      playlist.clear_items!
      expect(playlist.item_count).to eq(0)
    end
  end

  describe '#item_count' do
    let(:playlist) { described_class.create(character_id: character.id, name: 'Test Playlist') }

    it 'returns 0 when empty' do
      expect(playlist.item_count).to eq(0)
    end

    it 'returns correct count' do
      playlist.add_item!(youtube_video_id: 'video1')
      playlist.add_item!(youtube_video_id: 'video2')
      expect(playlist.item_count).to eq(2)
    end
  end

  describe '#to_hash' do
    let(:playlist) { described_class.create(character_id: character.id, name: 'Test Playlist') }

    before do
      playlist.add_item!(youtube_video_id: 'video1', title: 'First Video')
    end

    it 'returns hash with all fields' do
      hash = playlist.to_hash
      expect(hash[:id]).to eq(playlist.id)
      expect(hash[:name]).to eq('Test Playlist')
      expect(hash[:character_id]).to eq(character.id)
      expect(hash[:item_count]).to eq(1)
      expect(hash[:items]).to be_an(Array)
      expect(hash[:items].first[:youtube_video_id]).to eq('video1')
    end
  end
end
