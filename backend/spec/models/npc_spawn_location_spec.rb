# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcSpawnLocation do
  let(:user) { create(:user) }
  let(:room) { create(:room) }

  describe 'validations' do
    it 'requires user_id' do
      spawn = described_class.new(room_id: room.id, name: 'Test Location')
      expect(spawn.valid?).to be false
      expect(spawn.errors[:user_id]).not_to be_empty
    end

    it 'requires room_id' do
      spawn = described_class.new(user_id: user.id, name: 'Test Location')
      expect(spawn.valid?).to be false
      expect(spawn.errors[:room_id]).not_to be_empty
    end

    it 'requires name' do
      spawn = described_class.new(user_id: user.id, room_id: room.id)
      expect(spawn.valid?).to be false
      expect(spawn.errors[:name]).not_to be_empty
    end

    it 'is valid with required fields' do
      spawn = described_class.new(
        user_id: user.id,
        room_id: room.id,
        name: 'Test Location'
      )
      expect(spawn.valid?).to be true
    end

    it 'enforces uniqueness of user_id and name combination' do
      described_class.create(user_id: user.id, room_id: room.id, name: 'Test Location')
      other_room = create(:room)
      duplicate = described_class.new(user_id: user.id, room_id: other_room.id, name: 'Test Location')
      expect(duplicate.valid?).to be false
    end
  end

  describe '.for_user' do
    it 'returns locations for the specified user' do
      location = described_class.create(user_id: user.id, room_id: room.id, name: 'Test Location')
      other_user = create(:user)
      other_location = described_class.create(user_id: other_user.id, room_id: room.id, name: 'Other Location')

      results = described_class.for_user(user).all
      expect(results).to include(location)
      expect(results).not_to include(other_location)
    end
  end

  describe '#room_display' do
    it 'returns room name with location context' do
      spawn = described_class.new(room: room)
      expect(spawn.room_display).to include(room.name)
    end
  end
end
