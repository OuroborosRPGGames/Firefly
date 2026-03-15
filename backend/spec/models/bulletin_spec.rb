# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Bulletin do
  let(:character) { create(:character) }
  let(:bulletin) { create(:bulletin, character: character) }

  describe 'constants' do
    it 'uses GameConfig for MAX_DISPLAY' do
      expect(GameConfig::Content::BULLETIN_MAX_DISPLAY).to eq(15)
    end

    it 'uses GameConfig for EXPIRATION_DAYS' do
      expect(GameConfig::Content::BULLETIN_EXPIRATION_DAYS).to eq(10)
    end
  end

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(bulletin).to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to character' do
      expect(bulletin.character).to eq(character)
    end
  end

  describe 'before_create callbacks' do
    it 'sets posted_at if not set' do
      bulletin = Bulletin.create(character_id: character.id, body: 'Test', from_text: 'Author')
      expect(bulletin.posted_at).not_to be_nil
    end
  end

  describe '.recent' do
    let!(:recent_bulletin) { create(:bulletin, character: character, posted_at: Time.now - 86400) }
    let!(:old_bulletin) { create(:bulletin, character: character, posted_at: Time.now - (11 * 86400)) }

    it 'returns bulletins from last 10 days' do
      results = described_class.recent.all
      expect(results).to include(recent_bulletin)
      expect(results).not_to include(old_bulletin)
    end
  end

  describe '.delete_for_character' do
    let!(:my_bulletin1) { create(:bulletin, character: character) }
    let!(:my_bulletin2) { create(:bulletin, character: character) }
    let!(:other_bulletin) { create(:bulletin) }

    it 'deletes all bulletins for a character' do
      described_class.delete_for_character(character)
      expect(Bulletin[my_bulletin1.id]).to be_nil
      expect(Bulletin[my_bulletin2.id]).to be_nil
      expect(Bulletin[other_bulletin.id]).not_to be_nil
    end
  end

  describe '.by_character' do
    let!(:my_bulletin) { create(:bulletin, character: character) }
    let!(:other_bulletin) { create(:bulletin) }

    it 'returns bulletins by the character' do
      results = described_class.by_character(character).all
      expect(results).to include(my_bulletin)
      expect(results).not_to include(other_bulletin)
    end
  end

  describe '.exists_for_character?' do
    it 'returns true if character has bulletins' do
      create(:bulletin, character: character)
      expect(described_class.exists_for_character?(character)).to be true
    end

    it 'returns false if character has no bulletins' do
      expect(described_class.exists_for_character?(character)).to be false
    end
  end

  describe '#formatted_display' do
    it 'returns HTML formatted bulletin' do
      bulletin = create(:bulletin, character: character, from_text: 'Test Author', body: 'Hello World')
      expect(bulletin.formatted_display).to include('<fieldset>')
      expect(bulletin.formatted_display).to include('Test Author')
      expect(bulletin.formatted_display).to include('Hello World')
    end
  end

  describe '#expired?' do
    it 'returns true if bulletin is older than EXPIRATION_DAYS' do
      bulletin = create(:bulletin, character: character, posted_at: Time.now - (11 * 86400))
      expect(bulletin.expired?).to be true
    end

    it 'returns false if bulletin is within EXPIRATION_DAYS' do
      bulletin = create(:bulletin, character: character, posted_at: Time.now)
      expect(bulletin.expired?).to be false
    end
  end

  describe '#age_hours' do
    it 'returns age in hours' do
      bulletin = create(:bulletin, character: character, posted_at: Time.now - 7200) # 2 hours
      expect(bulletin.age_hours).to eq(2)
    end
  end
end
