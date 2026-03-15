# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ProfileVideo do
  let(:character) { create(:character) }

  describe 'associations' do
    it 'belongs to character' do
      profile_video = ProfileVideo.create(
        character_id: character.id,
        youtube_id: 'dQw4w9WgXcQ',
        position: 0
      )
      expect(profile_video.character.id).to eq(character.id)
    end
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      profile_video = ProfileVideo.new(
        character_id: character.id,
        youtube_id: 'dQw4w9WgXcQ',
        position: 0
      )
      expect(profile_video.valid?).to be true
    end

    it 'requires character_id' do
      profile_video = ProfileVideo.new(youtube_id: 'dQw4w9WgXcQ', position: 0)
      expect(profile_video.valid?).to be false
      expect(profile_video.errors[:character_id]).not_to be_empty
    end

    it 'requires youtube_id' do
      profile_video = ProfileVideo.new(character_id: character.id, position: 0)
      expect(profile_video.valid?).to be false
      expect(profile_video.errors[:youtube_id]).not_to be_empty
    end

    describe 'youtube_id format validation' do
      it 'accepts valid 11-character YouTube ID' do
        profile_video = ProfileVideo.new(
          character_id: character.id,
          youtube_id: 'dQw4w9WgXcQ',
          position: 0
        )
        expect(profile_video.valid?).to be true
      end

      it 'accepts YouTube ID with hyphens and underscores' do
        profile_video = ProfileVideo.new(
          character_id: character.id,
          youtube_id: 'abc-_123ABC',
          position: 0
        )
        expect(profile_video.valid?).to be true
      end

      it 'rejects YouTube ID shorter than 11 characters' do
        profile_video = ProfileVideo.new(
          character_id: character.id,
          youtube_id: 'abc123',
          position: 0
        )
        expect(profile_video.valid?).to be false
        expect(profile_video.errors[:youtube_id]).not_to be_empty
      end

      it 'rejects YouTube ID longer than 11 characters' do
        profile_video = ProfileVideo.new(
          character_id: character.id,
          youtube_id: 'abc1234567890',
          position: 0
        )
        expect(profile_video.valid?).to be false
        expect(profile_video.errors[:youtube_id]).not_to be_empty
      end

      it 'rejects YouTube ID with invalid characters' do
        profile_video = ProfileVideo.new(
          character_id: character.id,
          youtube_id: 'abc!@#$%^&*()',
          position: 0
        )
        expect(profile_video.valid?).to be false
        expect(profile_video.errors[:youtube_id]).not_to be_empty
      end

      it 'rejects full YouTube URL' do
        profile_video = ProfileVideo.new(
          character_id: character.id,
          youtube_id: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
          position: 0
        )
        expect(profile_video.valid?).to be false
        expect(profile_video.errors[:youtube_id]).not_to be_empty
      end
    end

    it 'validates title max length of 200' do
      profile_video = ProfileVideo.new(
        character_id: character.id,
        youtube_id: 'dQw4w9WgXcQ',
        title: 'a' * 201,
        position: 0
      )
      expect(profile_video.valid?).to be false
      expect(profile_video.errors[:title]).not_to be_empty
    end

    it 'allows nil title' do
      profile_video = ProfileVideo.new(
        character_id: character.id,
        youtube_id: 'dQw4w9WgXcQ',
        title: nil,
        position: 0
      )
      expect(profile_video.valid?).to be true
    end

    it 'allows title at max length' do
      profile_video = ProfileVideo.new(
        character_id: character.id,
        youtube_id: 'dQw4w9WgXcQ',
        title: 'a' * 200,
        position: 0
      )
      expect(profile_video.valid?).to be true
    end
  end

  describe 'ordering' do
    it 'orders by position' do
      video3 = ProfileVideo.create(character_id: character.id, youtube_id: 'vid3aaaaaaa', position: 2)
      video1 = ProfileVideo.create(character_id: character.id, youtube_id: 'vid1aaaaaaa', position: 0)
      video2 = ProfileVideo.create(character_id: character.id, youtube_id: 'vid2aaaaaaa', position: 1)

      videos = ProfileVideo.where(character_id: character.id).order(:position).all
      expect(videos.map(&:id)).to eq([video1.id, video2.id, video3.id])
    end
  end

  describe 'character association' do
    it 'is accessible through character.profile_videos' do
      ProfileVideo.create(character_id: character.id, youtube_id: 'dQw4w9WgXcQ', title: 'My Theme', position: 0)

      expect(character.profile_videos.count).to eq(1)
      expect(character.profile_videos.first.title).to eq('My Theme')
    end
  end
end
