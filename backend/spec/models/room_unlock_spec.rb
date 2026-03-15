# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomUnlock do
  let(:character) { create(:character) }
  let(:room) { create(:room) }

  describe 'validations' do
    it 'requires room_id' do
      unlock = described_class.new(character_id: character.id)
      expect(unlock.valid?).to be false
      expect(unlock.errors[:room_id]).not_to be_empty
    end

    it 'does not require character_id (for public unlocks)' do
      unlock = described_class.new(room_id: room.id)
      expect(unlock.valid?).to be true
    end

    it 'is valid with room_id and character_id' do
      unlock = described_class.new(
        character_id: character.id,
        room_id: room.id
      )
      expect(unlock.valid?).to be true
    end
  end

  describe '#expired?' do
    it 'returns falsy when expires_at is nil' do
      unlock = described_class.new(room_id: room.id, expires_at: nil)
      expect(unlock.expired?).to be_falsey
    end

    it 'returns false when expires_at is in the future' do
      unlock = described_class.new(room_id: room.id, expires_at: Time.now + 3600)
      expect(unlock.expired?).to be false
    end

    it 'returns true when expires_at is in the past' do
      unlock = described_class.new(room_id: room.id, expires_at: Time.now - 3600)
      expect(unlock.expired?).to be true
    end
  end

  describe '#permanent?' do
    it 'returns true when expires_at is nil' do
      unlock = described_class.new(room_id: room.id, expires_at: nil)
      expect(unlock.permanent?).to be true
    end

    it 'returns false when expires_at is set' do
      unlock = described_class.new(room_id: room.id, expires_at: Time.now + 3600)
      expect(unlock.permanent?).to be false
    end
  end

  describe '#public_unlock?' do
    it 'returns true when character_id is nil' do
      unlock = described_class.new(room_id: room.id, character_id: nil)
      expect(unlock.public_unlock?).to be true
    end

    it 'returns false when character_id is set' do
      unlock = described_class.new(room_id: room.id, character_id: character.id)
      expect(unlock.public_unlock?).to be false
    end
  end

  describe '.active' do
    it 'returns unlocks without expiration' do
      unlock = described_class.create(room_id: room.id, expires_at: nil)
      expect(described_class.active.all).to include(unlock)
    end

    it 'returns unlocks with future expiration' do
      unlock = described_class.create(room_id: room.id, expires_at: Time.now + 3600)
      expect(described_class.active.all).to include(unlock)
    end

    it 'excludes unlocks with past expiration' do
      unlock = described_class.create(room_id: room.id, expires_at: Time.now - 3600)
      expect(described_class.active.all).not_to include(unlock)
    end
  end
end
