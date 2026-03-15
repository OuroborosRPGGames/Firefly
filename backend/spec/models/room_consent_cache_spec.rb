# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomConsentCache do
  let(:room) { create(:room) }

  describe 'validations' do
    it 'requires room_id' do
      cache = described_class.new
      expect(cache.valid?).to be false
    end

    it 'enforces uniqueness of room_id' do
      described_class.create(room_id: room.id)
      duplicate = described_class.new(room_id: room.id)
      expect(duplicate.valid?).to be false
    end

    it 'is valid with required fields' do
      cache = described_class.new(room_id: room.id)
      expect(cache.valid?).to be true
    end
  end

  describe '#stale?' do
    it 'returns true when character count differs' do
      cache = described_class.create(room_id: room.id, character_count: 2)
      expect(cache.stale?(3)).to be true
    end

    it 'returns true when updated_at is nil' do
      cache = described_class.create(room_id: room.id, character_count: 2)
      # Force updated_at to nil by direct update
      DB[:room_consent_caches].where(id: cache.id).update(updated_at: nil)
      cache.refresh
      expect(cache.stale?(2)).to be true
    end

    it 'returns true when cache is older than 1 minute' do
      cache = described_class.create(room_id: room.id, character_count: 2)
      # Force old timestamp
      DB[:room_consent_caches].where(id: cache.id).update(updated_at: Time.now - 120)
      cache.refresh
      expect(cache.stale?(2)).to be true
    end
  end

  describe '#display_ready?' do
    it 'returns false when occupancy_changed_at is nil' do
      cache = described_class.create(room_id: room.id, occupancy_changed_at: nil)
      expect(cache.display_ready?).to be false
    end

    it 'returns false when less than 10 minutes have passed' do
      cache = described_class.create(room_id: room.id, occupancy_changed_at: Time.now - 300)
      expect(cache.display_ready?).to be false
    end

    it 'returns true when 10 minutes have passed' do
      cache = described_class.create(room_id: room.id, occupancy_changed_at: Time.now - 601)
      expect(cache.display_ready?).to be true
    end
  end

  describe '#time_until_display' do
    it 'returns 0 when display is ready' do
      cache = described_class.create(room_id: room.id, occupancy_changed_at: Time.now - 601)
      expect(cache.time_until_display).to eq(0)
    end

    it 'returns 600 when occupancy_changed_at is nil' do
      cache = described_class.create(room_id: room.id, occupancy_changed_at: nil)
      expect(cache.time_until_display).to eq(600)
    end

    it 'returns remaining seconds' do
      cache = described_class.create(room_id: room.id, occupancy_changed_at: Time.now - 300)
      expect(cache.time_until_display).to be_within(5).of(300)
    end
  end

  describe '#allowed_content_codes' do
    it 'returns empty array when allowed_codes is nil' do
      cache = described_class.new(room_id: room.id, allowed_codes: nil)
      expect(cache.allowed_content_codes).to eq([])
    end

    it 'returns array when allowed_codes is already an array' do
      cache = described_class.new(room_id: room.id, allowed_codes: %w[violence gore])
      expect(cache.allowed_content_codes).to eq(%w[violence gore])
    end
  end

  describe '.for_room' do
    it 'returns existing cache' do
      cache = described_class.create(room_id: room.id)
      expect(described_class.for_room(room)).to eq(cache)
    end

    it 'creates new cache if none exists' do
      result = described_class.for_room(room)
      expect(result).to be_a(described_class)
      expect(result.room_id).to eq(room.id)
    end
  end
end
