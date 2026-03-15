# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ContentConsentService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }

  let(:user1) { create(:user) }
  let(:user2) { create(:user) }
  let(:char1) { create(:character, user: user1, forename: 'Alice') }
  let(:char2) { create(:character, user: user2, forename: 'Bob') }

  let(:instance1) do
    create(:character_instance,
           character: char1,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  let(:instance2) do
    create(:character_instance,
           character: char2,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  describe 'DISPLAY_TIMER_SECONDS' do
    it 'is 600 seconds (10 minutes)' do
      expect(described_class::DISPLAY_TIMER_SECONDS).to eq(600)
    end
  end

  describe '.allowed_for_room' do
    context 'with no characters in room' do
      it 'returns empty array' do
        result = described_class.allowed_for_room(room)
        expect(result).to eq([])
      end
    end

    context 'with characters in room' do
      before do
        instance1
        instance2
      end

      it 'returns array of content codes' do
        result = described_class.allowed_for_room(room)
        expect(result).to be_an(Array)
      end
    end
  end

  describe '.char_consents_to?' do
    it 'returns falsey when no consent record exists' do
      restriction = double('ContentRestriction', code: 'VIOLENCE')
      result = described_class.char_consents_to?(char1, restriction)
      expect(result).to be_falsey
    end
  end

  describe '.on_room_entry' do
    before { instance1 }

    it 'calls record_room_entry! on character_instance' do
      allow(instance1).to receive(:record_room_entry!)
      allow(described_class).to receive(:reset_room_timer)

      described_class.on_room_entry(instance1, room)

      expect(instance1).to have_received(:record_room_entry!)
    end

    it 'resets room timer' do
      allow(instance1).to receive(:record_room_entry!)
      expect(described_class).to receive(:reset_room_timer).with(room)

      described_class.on_room_entry(instance1, room)
    end
  end

  describe '.on_room_exit' do
    it 'resets room timer' do
      expect(described_class).to receive(:reset_room_timer).with(room)
      described_class.on_room_exit(room)
    end
  end

  describe '.reset_room_timer' do
    before do
      instance1
      instance2
    end

    it 'creates or updates room consent cache' do
      described_class.reset_room_timer(room)

      cache = RoomConsentCache.for_room(room)
      expect(cache).not_to be_nil
      expect(cache.character_count).to eq(2)
    end

    it 'resets consent_display_triggered for characters in room' do
      instance1.update(consent_display_triggered: true)
      instance2.update(consent_display_triggered: true)

      described_class.reset_room_timer(room)

      expect(instance1.refresh.consent_display_triggered).to be false
      expect(instance2.refresh.consent_display_triggered).to be false
    end
  end

  describe '.display_ready?' do
    before do
      instance1
      described_class.reset_room_timer(room)
    end

    it 'returns false when occupancy has changed' do
      # Add another character
      instance2
      expect(described_class.display_ready?(room)).to be false
    end

    context 'when 10 minutes have not passed' do
      it 'returns false' do
        expect(described_class.display_ready?(room)).to be false
      end
    end

    context 'when 10 minutes have passed' do
      before do
        cache = RoomConsentCache.for_room(room)
        cache.update(occupancy_changed_at: Time.now - 601)
      end

      it 'returns true' do
        expect(described_class.display_ready?(room)).to be true
      end
    end
  end

  describe '.time_until_display' do
    before do
      instance1
      described_class.reset_room_timer(room)
    end

    it 'returns positive number when timer not elapsed' do
      result = described_class.time_until_display(room)
      expect(result).to be > 0
      expect(result).to be <= 600
    end

    it 'returns 0 or negative when timer elapsed' do
      cache = RoomConsentCache.for_room(room)
      cache.update(occupancy_changed_at: Time.now - 601)

      result = described_class.time_until_display(room)
      expect(result).to be <= 0
    end
  end

  describe '.consent_display_for_room' do
    before do
      instance1
      described_class.reset_room_timer(room)
    end

    context 'when display not ready' do
      it 'returns nil' do
        result = described_class.consent_display_for_room(room)
        expect(result).to be_nil
      end
    end

    context 'when display is ready' do
      before do
        cache = RoomConsentCache.for_room(room)
        cache.update(occupancy_changed_at: Time.now - 601)
      end

      it 'returns hash with consent info' do
        result = described_class.consent_display_for_room(room)

        expect(result).to be_a(Hash)
        expect(result).to have_key(:allowed_content)
        expect(result).to have_key(:stable_since)
        expect(result).to have_key(:character_count)
      end

      it 'includes character count' do
        result = described_class.consent_display_for_room(room)
        expect(result[:character_count]).to eq(1)
      end
    end
  end

  describe '.consent_settings_for' do
    it 'returns hash of settings' do
      result = described_class.consent_settings_for(char1)
      expect(result).to be_a(Hash)
    end

    context 'with active restrictions' do
      before do
        # Create a content restriction
        ContentRestriction.create(
          code: 'test_content',
          name: 'Test Content',
          description: 'Test content type',
          severity: 'medium',
          is_active: true,
          universe_id: universe.id
        )
      end

      it 'includes restriction in settings' do
        result = described_class.consent_settings_for(char1)
        # Keys are stored uppercase
        expect(result).to have_key('TEST_CONTENT')
        expect(result['TEST_CONTENT'][:name]).to eq('Test Content')
        expect(result['TEST_CONTENT'][:consented]).to be false
      end
    end
  end

  describe '.set_consent!' do
    let!(:restriction) do
      ContentRestriction.create(
        code: 'test_type',
        name: 'Test Type',
        description: 'Test',
        severity: 'low',
        is_active: true,
        universe_id: universe.id
      )
    end

    it 'sets generic user permission consent when granting consent' do
      described_class.set_consent!(char1, restriction, true)

      expect(UserPermission.generic_for(user1).content_consent_for(restriction.code)).to eq('yes')
    end

    it 'updates existing generic consent setting' do
      # First grant consent
      described_class.set_consent!(char1, restriction, true)

      # Then revoke it
      described_class.set_consent!(char1, restriction, false)

      expect(UserPermission.generic_for(user1).content_consent_for(restriction.code)).to eq('no')
    end
  end

  describe '.available_restrictions' do
    it 'returns only active restrictions' do
      active = ContentRestriction.create(
        code: 'active_type',
        name: 'Active',
        description: 'Active type',
        severity: 'low',
        is_active: true,
        universe_id: universe.id
      )

      inactive = ContentRestriction.create(
        code: 'inactive_type',
        name: 'Inactive',
        description: 'Inactive type',
        severity: 'low',
        is_active: false,
        universe_id: universe.id
      )

      result = described_class.available_restrictions
      expect(result).to include(active)
      expect(result).not_to include(inactive)
    end

    it 'orders by name' do
      ContentRestriction.create(code: 'z_type', name: 'Zebra', description: 'Z', severity: 'low', is_active: true, universe_id: universe.id)
      ContentRestriction.create(code: 'a_type', name: 'Apple', description: 'A', severity: 'low', is_active: true, universe_id: universe.id)

      result = described_class.available_restrictions
      names = result.map(&:name)

      expect(names.first).to eq('Apple')
    end
  end

  describe '.process_consent_notifications!' do
    it 'returns statistics hash' do
      result = described_class.process_consent_notifications!
      expect(result).to be_a(Hash)
      expect(result).to have_key(:notified)
    end
  end
end
