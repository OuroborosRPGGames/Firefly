# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomMedia do
  let(:reality) { create_test_reality }
  let(:room) { create_test_room(reality_id: reality.id) }

  describe 'validations' do
    it 'requires a room_id' do
      media = RoomMedia.new(url: 'https://www.youtube.com/watch?v=test')
      expect(media.valid?).to be false
      expect(media.errors[:room_id]).not_to be_empty
    end

    it 'requires a url' do
      media = RoomMedia.new(room_id: room.id)
      expect(media.valid?).to be false
      expect(media.errors[:url]).not_to be_empty
    end
  end

  describe '#youtube?' do
    it 'returns true for youtube.com URLs' do
      media = RoomMedia.new(url: 'https://www.youtube.com/watch?v=test')
      expect(media.youtube?).to be true
    end

    it 'returns true for youtu.be URLs' do
      media = RoomMedia.new(url: 'https://youtu.be/test')
      expect(media.youtube?).to be true
    end

    it 'returns false for non-YouTube URLs' do
      media = RoomMedia.new(url: 'https://example.com/video')
      expect(media.youtube?).to be false
    end
  end

  describe '#youtube_video_id' do
    it 'extracts ID from youtube.com URL' do
      media = RoomMedia.new(url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ')
      expect(media.youtube_video_id).to eq('dQw4w9WgXcQ')
    end

    it 'extracts ID from youtu.be URL' do
      media = RoomMedia.new(url: 'https://youtu.be/dQw4w9WgXcQ')
      expect(media.youtube_video_id).to eq('dQw4w9WgXcQ')
    end

    it 'handles URLs with extra parameters' do
      media = RoomMedia.new(url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=60')
      expect(media.youtube_video_id).to eq('dQw4w9WgXcQ')
    end
  end

  describe '#embed_url' do
    it 'generates embed URL with autoplay' do
      media = RoomMedia.new(url: 'https://www.youtube.com/watch?v=test', autoplay: true)
      expect(media.embed_url).to eq('https://www.youtube.com/embed/test?autoplay=1')
    end

    it 'generates embed URL without autoplay when disabled' do
      media = RoomMedia.new(url: 'https://www.youtube.com/watch?v=test', autoplay: false)
      expect(media.embed_url).to eq('https://www.youtube.com/embed/test')
    end
  end

  describe '#playing?' do
    it 'returns true when not expired' do
      media = RoomMedia.new(ends_at: Time.now + 300)
      expect(media.playing?).to be true
    end

    it 'returns false when expired' do
      media = RoomMedia.new(ends_at: Time.now - 1)
      expect(media.playing?).to be false
    end
  end

  describe '.playing_in' do
    it 'returns currently playing media in room' do
      media = RoomMedia.create(
        room_id: room.id,
        url: 'https://www.youtube.com/watch?v=test',
        ends_at: Time.now + 300
      )
      expect(RoomMedia.playing_in(room.id)).to eq(media)
    end

    it 'returns nil if nothing is playing' do
      expect(RoomMedia.playing_in(room.id)).to be_nil
    end

    it 'ignores expired media' do
      RoomMedia.create(
        room_id: room.id,
        url: 'https://www.youtube.com/watch?v=test',
        ends_at: Time.now - 1
      )
      expect(RoomMedia.playing_in(room.id)).to be_nil
    end
  end
end
