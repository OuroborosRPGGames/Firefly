# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GroupRoomUnlock do
  let(:group) { create(:group) }
  let(:room) { create(:room) }

  describe 'validations' do
    it 'requires group_id' do
      unlock = described_class.new(room_id: room.id)
      expect(unlock.valid?).to be false
    end

    it 'requires room_id' do
      unlock = described_class.new(group_id: group.id)
      expect(unlock.valid?).to be false
    end

    it 'is valid with required fields' do
      unlock = described_class.new(
        group_id: group.id,
        room_id: room.id
      )
      expect(unlock.valid?).to be true
    end
  end

  describe '#expired?' do
    it 'returns falsy when expires_at is nil' do
      unlock = described_class.new(group_id: group.id, room_id: room.id, expires_at: nil)
      expect(unlock.expired?).to be_falsey
    end

    it 'returns false when expires_at is in the future' do
      unlock = described_class.new(group_id: group.id, room_id: room.id, expires_at: Time.now + 3600)
      expect(unlock.expired?).to be false
    end

    it 'returns true when expires_at is in the past' do
      unlock = described_class.new(group_id: group.id, room_id: room.id, expires_at: Time.now - 3600)
      expect(unlock.expired?).to be true
    end
  end

  describe '#permanent?' do
    it 'returns true when expires_at is nil' do
      unlock = described_class.new(group_id: group.id, room_id: room.id, expires_at: nil)
      expect(unlock.permanent?).to be true
    end

    it 'returns false when expires_at is set' do
      unlock = described_class.new(group_id: group.id, room_id: room.id, expires_at: Time.now + 3600)
      expect(unlock.permanent?).to be false
    end
  end

  describe '.active' do
    it 'returns unlocks without expiration' do
      unlock = described_class.create(group_id: group.id, room_id: room.id, expires_at: nil)
      expect(described_class.active.all).to include(unlock)
    end

    it 'returns unlocks with future expiration' do
      unlock = described_class.create(group_id: group.id, room_id: room.id, expires_at: Time.now + 3600)
      expect(described_class.active.all).to include(unlock)
    end

    it 'excludes unlocks with past expiration' do
      unlock = described_class.create(group_id: group.id, room_id: room.id, expires_at: Time.now - 3600)
      expect(described_class.active.all).not_to include(unlock)
    end
  end

  describe '.for_room' do
    it 'filters by room' do
      unlock = described_class.create(group_id: group.id, room_id: room.id)
      other_room = create(:room)
      other_unlock = described_class.create(group_id: group.id, room_id: other_room.id)

      results = described_class.for_room(room).all
      expect(results).to include(unlock)
      expect(results).not_to include(other_unlock)
    end
  end

  describe '.for_group' do
    it 'filters by group' do
      unlock = described_class.create(group_id: group.id, room_id: room.id)
      other_group = create(:group)
      other_unlock = described_class.create(group_id: other_group.id, room_id: room.id)

      results = described_class.for_group(group).all
      expect(results).to include(unlock)
      expect(results).not_to include(other_unlock)
    end
  end
end
