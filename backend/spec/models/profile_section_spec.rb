# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ProfileSection do
  let(:character) { create(:character) }

  describe 'associations' do
    it 'belongs to character' do
      profile_section = ProfileSection.create(
        character_id: character.id,
        content: 'This is my story...',
        position: 0
      )
      expect(profile_section.character.id).to eq(character.id)
    end
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      profile_section = ProfileSection.new(
        character_id: character.id,
        content: 'This is my story...',
        position: 0
      )
      expect(profile_section.valid?).to be true
    end

    it 'requires character_id' do
      profile_section = ProfileSection.new(content: 'This is my story...', position: 0)
      expect(profile_section.valid?).to be false
      expect(profile_section.errors[:character_id]).not_to be_empty
    end

    it 'requires content' do
      profile_section = ProfileSection.new(character_id: character.id, position: 0)
      expect(profile_section.valid?).to be false
      expect(profile_section.errors[:content]).not_to be_empty
    end

    it 'validates title max length of 200' do
      profile_section = ProfileSection.new(
        character_id: character.id,
        title: 'a' * 201,
        content: 'Some content',
        position: 0
      )
      expect(profile_section.valid?).to be false
      expect(profile_section.errors[:title]).not_to be_empty
    end

    it 'allows nil title' do
      profile_section = ProfileSection.new(
        character_id: character.id,
        title: nil,
        content: 'Some content',
        position: 0
      )
      expect(profile_section.valid?).to be true
    end

    it 'allows title at max length' do
      profile_section = ProfileSection.new(
        character_id: character.id,
        title: 'a' * 200,
        content: 'Some content',
        position: 0
      )
      expect(profile_section.valid?).to be true
    end

    it 'validates content max length of 10000' do
      profile_section = ProfileSection.new(
        character_id: character.id,
        content: 'a' * 10_001,
        position: 0
      )
      expect(profile_section.valid?).to be false
      expect(profile_section.errors[:content]).not_to be_empty
    end

    it 'allows content at max length' do
      profile_section = ProfileSection.new(
        character_id: character.id,
        content: 'a' * 10_000,
        position: 0
      )
      expect(profile_section.valid?).to be true
    end
  end

  describe 'ordering' do
    it 'orders by position' do
      section3 = ProfileSection.create(character_id: character.id, content: 'Third', position: 2)
      section1 = ProfileSection.create(character_id: character.id, content: 'First', position: 0)
      section2 = ProfileSection.create(character_id: character.id, content: 'Second', position: 1)

      sections = ProfileSection.where(character_id: character.id).order(:position).all
      expect(sections.map(&:id)).to eq([section1.id, section2.id, section3.id])
    end
  end

  describe 'character association' do
    it 'is accessible through character.profile_sections' do
      ProfileSection.create(character_id: character.id, title: 'Bio', content: 'My story', position: 0)

      expect(character.profile_sections.count).to eq(1)
      expect(character.profile_sections.first.title).to eq('Bio')
    end
  end
end
