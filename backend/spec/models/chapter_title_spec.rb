# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ChapterTitle do
  let(:character) { create(:character) }

  describe 'associations' do
    it 'belongs to a character' do
      title = ChapterTitle.create(
        character_id: character.id,
        chapter_index: 0,
        title: 'A New Beginning'
      )
      expect(title.character).to eq(character)
    end
  end

  describe 'validations' do
    it 'requires character_id' do
      title = ChapterTitle.new(chapter_index: 0, title: 'Test')
      expect(title.valid?).to be false
      expect(title.errors[:character_id]).not_to be_empty
    end

    it 'requires chapter_index' do
      title = ChapterTitle.new(character_id: character.id, title: 'Test')
      expect(title.valid?).to be false
      expect(title.errors[:chapter_index]).not_to be_empty
    end

    it 'requires title' do
      title = ChapterTitle.new(character_id: character.id, chapter_index: 0)
      expect(title.valid?).to be false
      expect(title.errors[:title]).not_to be_empty
    end

    it 'enforces unique character_id + chapter_index' do
      ChapterTitle.create(character_id: character.id, chapter_index: 0, title: 'First')
      duplicate = ChapterTitle.new(character_id: character.id, chapter_index: 0, title: 'Second')
      expect { duplicate.save }.to raise_error(Sequel::UniqueConstraintViolation)
    end
  end

  describe '.for_character' do
    it 'returns titles ordered by chapter_index' do
      ChapterTitle.create(character_id: character.id, chapter_index: 2, title: 'Third')
      ChapterTitle.create(character_id: character.id, chapter_index: 0, title: 'First')
      ChapterTitle.create(character_id: character.id, chapter_index: 1, title: 'Second')

      titles = ChapterTitle.for_character(character.id)
      expect(titles.map(&:title)).to eq(['First', 'Second', 'Third'])
    end
  end

  describe '.find_or_create_for' do
    it 'creates a new title if one does not exist' do
      title = ChapterTitle.find_or_create_for(character.id, 0, default_title: 'Custom Title')
      expect(title.title).to eq('Custom Title')
      expect(title.chapter_index).to eq(0)
    end

    it 'returns existing title if one exists' do
      existing = ChapterTitle.create(character_id: character.id, chapter_index: 0, title: 'Existing')
      found = ChapterTitle.find_or_create_for(character.id, 0, default_title: 'New Title')
      expect(found.id).to eq(existing.id)
      expect(found.title).to eq('Existing')
    end

    it 'uses default "Chapter N" format when no title provided' do
      title = ChapterTitle.find_or_create_for(character.id, 2)
      expect(title.title).to eq('Chapter 3')
    end
  end

  describe '.clear_for' do
    it 'deletes all titles for a character' do
      ChapterTitle.create(character_id: character.id, chapter_index: 0, title: 'First')
      ChapterTitle.create(character_id: character.id, chapter_index: 1, title: 'Second')

      other_character = create(:character)
      ChapterTitle.create(character_id: other_character.id, chapter_index: 0, title: 'Other')

      ChapterTitle.clear_for(character.id)

      expect(ChapterTitle.where(character_id: character.id).count).to eq(0)
      expect(ChapterTitle.where(character_id: other_character.id).count).to eq(1)
    end
  end
end
