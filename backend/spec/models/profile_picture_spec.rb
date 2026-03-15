# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ProfilePicture do
  let(:character) { create(:character) }

  describe 'associations' do
    it 'belongs to character' do
      profile_picture = ProfilePicture.create(
        character_id: character.id,
        url: 'https://example.com/pic.jpg',
        position: 0
      )
      expect(profile_picture.character.id).to eq(character.id)
    end
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      profile_picture = ProfilePicture.new(
        character_id: character.id,
        url: 'https://example.com/pic.jpg',
        position: 0
      )
      expect(profile_picture.valid?).to be true
    end

    it 'requires character_id' do
      profile_picture = ProfilePicture.new(url: 'https://example.com/pic.jpg', position: 0)
      expect(profile_picture.valid?).to be false
      expect(profile_picture.errors[:character_id]).not_to be_empty
    end

    it 'requires url' do
      profile_picture = ProfilePicture.new(character_id: character.id, position: 0)
      expect(profile_picture.valid?).to be false
      expect(profile_picture.errors[:url]).not_to be_empty
    end

    it 'validates url max length of 500' do
      profile_picture = ProfilePicture.new(
        character_id: character.id,
        url: 'https://example.com/' + 'a' * 490,
        position: 0
      )
      expect(profile_picture.valid?).to be false
      expect(profile_picture.errors[:url]).not_to be_empty
    end

    it 'accepts url at max length' do
      profile_picture = ProfilePicture.new(
        character_id: character.id,
        url: 'https://example.com/' + 'a' * 479,
        position: 0
      )
      expect(profile_picture.valid?).to be true
    end

    it 'validates caption max length of 200' do
      profile_picture = ProfilePicture.new(
        character_id: character.id,
        url: 'https://example.com/pic.jpg',
        caption: 'a' * 201,
        position: 0
      )
      expect(profile_picture.valid?).to be false
      expect(profile_picture.errors[:caption]).not_to be_empty
    end

    it 'allows nil caption' do
      profile_picture = ProfilePicture.new(
        character_id: character.id,
        url: 'https://example.com/pic.jpg',
        caption: nil,
        position: 0
      )
      expect(profile_picture.valid?).to be true
    end
  end

  describe 'ordering' do
    it 'orders by position' do
      pic3 = ProfilePicture.create(character_id: character.id, url: 'https://example.com/3.jpg', position: 2)
      pic1 = ProfilePicture.create(character_id: character.id, url: 'https://example.com/1.jpg', position: 0)
      pic2 = ProfilePicture.create(character_id: character.id, url: 'https://example.com/2.jpg', position: 1)

      pictures = ProfilePicture.where(character_id: character.id).order(:position).all
      expect(pictures.map(&:id)).to eq([pic1.id, pic2.id, pic3.id])
    end
  end

  describe 'character association' do
    it 'is accessible through character.profile_pictures' do
      ProfilePicture.create(character_id: character.id, url: 'https://example.com/pic.jpg', position: 0)

      expect(character.profile_pictures.count).to eq(1)
      expect(character.profile_pictures.first.url).to eq('https://example.com/pic.jpg')
    end
  end
end
