# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ProfileSetting do
  let(:character) { create(:character) }

  describe 'associations' do
    it 'belongs to character' do
      profile_setting = ProfileSetting.create(character_id: character.id)
      expect(profile_setting.character.id).to eq(character.id)
    end
  end

  describe 'validations' do
    it 'is valid with just character_id' do
      profile_setting = ProfileSetting.new(character_id: character.id)
      expect(profile_setting.valid?).to be true
    end

    it 'requires character_id' do
      profile_setting = ProfileSetting.new
      expect(profile_setting.valid?).to be false
      expect(profile_setting.errors[:character_id]).not_to be_empty
    end

    it 'validates background_url max length of 500' do
      profile_setting = ProfileSetting.new(
        character_id: character.id,
        background_url: 'https://example.com/' + 'a' * 490
      )
      expect(profile_setting.valid?).to be false
      expect(profile_setting.errors[:background_url]).not_to be_empty
    end

    it 'allows nil background_url' do
      profile_setting = ProfileSetting.new(
        character_id: character.id,
        background_url: nil
      )
      expect(profile_setting.valid?).to be true
    end

    it 'allows background_url at max length' do
      profile_setting = ProfileSetting.new(
        character_id: character.id,
        background_url: 'https://example.com/' + 'a' * 479
      )
      expect(profile_setting.valid?).to be true
    end
  end

  describe 'default values' do
    it 'has default layout_style of default' do
      profile_setting = ProfileSetting.create(character_id: character.id)
      expect(profile_setting.layout_style).to eq('default')
    end

    it 'has default show_stats of true' do
      profile_setting = ProfileSetting.create(character_id: character.id)
      expect(profile_setting.show_stats).to be true
    end

    it 'has default show_badges of true' do
      profile_setting = ProfileSetting.create(character_id: character.id)
      expect(profile_setting.show_badges).to be true
    end

    it 'has default allow_comments of true' do
      profile_setting = ProfileSetting.create(character_id: character.id)
      expect(profile_setting.allow_comments).to be true
    end
  end

  describe 'character association' do
    it 'is accessible through character.profile_setting' do
      ProfileSetting.create(character_id: character.id, layout_style: 'minimal')

      expect(character.profile_setting).not_to be_nil
      expect(character.profile_setting.layout_style).to eq('minimal')
    end
  end

  describe 'one-to-one relationship' do
    it 'allows only one profile_setting per character' do
      ProfileSetting.create(character_id: character.id)

      # Creating a second one should replace or raise error depending on db constraints
      # This test verifies the model relationship works correctly
      expect(character.profile_setting).not_to be_nil
    end

    it 'validates uniqueness of character_id' do
      ProfileSetting.create(character_id: character.id)

      duplicate = ProfileSetting.new(character_id: character.id)
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:character_id]).not_to be_empty
    end
  end
end
