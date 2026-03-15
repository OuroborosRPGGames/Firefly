# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldMemorySessionRoom do
  let(:room) { create(:room) }
  let(:world_memory_session) do
    WorldMemorySession.create(
      room_id: room.id,
      started_at: Time.now,
      last_activity_at: Time.now,
      status: 'active'
    )
  end

  describe 'validations' do
    it 'requires session_id' do
      record = described_class.new(room_id: room.id)
      expect(record.valid?).to be false
    end

    it 'requires room_id' do
      record = described_class.new(session_id: world_memory_session.id)
      expect(record.valid?).to be false
    end

    it 'is valid with required fields' do
      record = described_class.new(
        session_id: world_memory_session.id,
        room_id: room.id
      )
      expect(record.valid?).to be true
    end
  end
end
