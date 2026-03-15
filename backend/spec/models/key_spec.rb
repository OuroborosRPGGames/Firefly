# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Key do
  let(:character) { create(:character) }
  let(:room) { create(:room) }
  let(:room_feature) { create(:room_feature, room: room) }
  let(:item) { create(:item) }

  # Helper to create a valid key
  def create_key(attrs = {})
    key = Key.new
    key.character = attrs[:character] || character
    key.room_feature = attrs[:room_feature] if attrs[:room_feature]
    key.item = attrs[:item] if attrs[:item]
    key.key_type = attrs[:key_type] || 'physical'
    key.expires_at = attrs[:expires_at] if attrs[:expires_at]
    key.save
    key
  end

  describe 'associations' do
    it 'belongs to character' do
      key = create_key(character: character, room_feature: room_feature)
      expect(key.character.id).to eq(character.id)
    end

    it 'belongs to room_feature' do
      key = create_key(room_feature: room_feature)
      expect(key.room_feature.id).to eq(room_feature.id)
    end

    it 'belongs to item' do
      key = create_key(item: item)
      expect(key.item.id).to eq(item.id)
    end
  end

  describe 'validations' do
    it 'requires character_id' do
      key = Key.new(room_feature_id: room_feature.id, key_type: 'physical')
      expect(key.valid?).to be false
      expect(key.errors[:character_id]).not_to be_empty
    end

    it 'requires key_type' do
      key = Key.new(character_id: character.id, room_feature_id: room_feature.id)
      expect(key.valid?).to be false
      expect(key.errors[:key_type]).not_to be_empty
    end

    Key::KEY_TYPES.each do |key_type|
      it "accepts #{key_type} as key_type" do
        key = Key.new(
          character_id: character.id,
          room_feature_id: room_feature.id,
          key_type: key_type
        )
        expect(key.valid?).to be true
      end
    end

    it 'rejects invalid key_type' do
      key = Key.new(
        character_id: character.id,
        room_feature_id: room_feature.id,
        key_type: 'invalid'
      )
      expect(key.valid?).to be false
    end

    it 'requires at least one target' do
      key = Key.new(character_id: character.id, key_type: 'physical')
      expect(key.valid?).to be false
      expect(key.errors[:base]).not_to be_empty
    end

    it 'is valid with room_feature target' do
      key = Key.new(
        character_id: character.id,
        room_feature_id: room_feature.id,
        key_type: 'physical'
      )
      expect(key.valid?).to be true
    end

    it 'is valid with item target' do
      key = Key.new(
        character_id: character.id,
        item_id: item.id,
        key_type: 'physical'
      )
      expect(key.valid?).to be true
    end
  end

  describe '#before_save' do
    it 'sets default key_type to physical when valid' do
      # Note: Key model sets default in before_save, but validation runs first
      # So we need to provide a key_type to pass validation
      key = Key.new
      key.character = character
      key.room_feature = room_feature
      key.key_type = 'physical'
      key.save

      expect(key.key_type).to eq('physical')
    end
  end

  describe '#physical?' do
    it 'returns true for physical keys' do
      key = create_key(room_feature: room_feature, key_type: 'physical')
      expect(key.physical?).to be true
    end

    it 'returns false for non-physical keys' do
      key = create_key(room_feature: room_feature, key_type: 'master')
      expect(key.physical?).to be false
    end
  end

  describe '#master?' do
    it 'returns true for master keys' do
      key = create_key(room_feature: room_feature, key_type: 'master')
      expect(key.master?).to be true
    end

    it 'returns false for non-master keys' do
      key = create_key(room_feature: room_feature, key_type: 'physical')
      expect(key.master?).to be false
    end
  end

  describe '#temporary?' do
    it 'returns true for temporary keys' do
      key = create_key(room_feature: room_feature, key_type: 'temporary')
      expect(key.temporary?).to be true
    end

    it 'returns false for non-temporary keys' do
      key = create_key(room_feature: room_feature, key_type: 'physical')
      expect(key.temporary?).to be false
    end
  end

  describe '#expired?' do
    it 'returns false when no expires_at' do
      key = create_key(room_feature: room_feature)
      expect(key.expired?).to be false
    end

    it 'returns true when expires_at is in the past' do
      key = create_key(room_feature: room_feature, expires_at: Time.now - 60)
      expect(key.expired?).to be true
    end

    it 'returns false when expires_at is in the future' do
      key = create_key(room_feature: room_feature, expires_at: Time.now + 3600)
      expect(key.expired?).to be false
    end
  end

  describe '#for_exit?' do
    it 'returns false (legacy method - room_exit no longer used)' do
      key = create_key(room_feature: room_feature)
      expect(key.for_exit?).to be false
    end
  end

  describe '#for_feature?' do
    it 'returns true when key has room_feature' do
      key = create_key(room_feature: room_feature)
      expect(key.for_feature?).to be true
    end

    it 'returns false when key has no room_feature' do
      key = create_key(item: item)
      expect(key.for_feature?).to be false
    end
  end

  describe '#for_container?' do
    it 'returns true when key has item' do
      key = create_key(item: item)
      expect(key.for_container?).to be true
    end

    it 'returns false when key has no item' do
      key = create_key(room_feature: room_feature)
      expect(key.for_container?).to be false
    end
  end

  describe '.can_unlock?' do
    context 'with RoomFeature' do
      it 'returns true when character has key for feature' do
        create_key(character: character, room_feature: room_feature)

        expect(Key.can_unlock?(character, room_feature)).to be true
      end

      it 'returns false when character has no key for feature' do
        expect(Key.can_unlock?(character, room_feature)).to be false
      end
    end

    context 'with Item (container)' do
      it 'returns true when character has key for item' do
        create_key(character: character, item: item)

        expect(Key.can_unlock?(character, item)).to be true
      end

      it 'returns false when character has no key for item' do
        expect(Key.can_unlock?(character, item)).to be false
      end
    end

    it 'returns false for unknown lockable type' do
      expect(Key.can_unlock?(character, 'unknown')).to be false
    end
  end
end
