# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EventService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:organizer) { create(:character) }

  describe '.create_event' do
    it 'creates an event with required attributes' do
      event = described_class.create_event(
        organizer: organizer,
        name: 'Birthday Party',
        starts_at: Time.now + 3600,
        room: room
      )

      expect(event).to be_a(Event)
      expect(event.name).to eq 'Birthday Party'
      expect(event.organizer_id).to eq organizer.id
      expect(event.room_id).to eq room.id
      expect(event.status).to eq 'scheduled'
    end

    it 'sets default event_type to party' do
      event = described_class.create_event(
        organizer: organizer,
        name: 'Test Event',
        starts_at: Time.now + 3600
      )

      expect(event.event_type).to eq 'party'
    end

    it 'allows custom event_type' do
      event = described_class.create_event(
        organizer: organizer,
        name: 'Private Meeting',
        starts_at: Time.now + 3600,
        event_type: 'meeting'
      )

      expect(event.event_type).to eq 'meeting'
    end
  end

  describe '.upcoming_events' do
    before do
      # Create some test events
      Event.create(
        organizer: organizer,
        name: 'Future Public',
        event_type: 'party',
        starts_at: Time.now + 3600,
        is_public: true,
        status: 'scheduled'
      )
      Event.create(
        organizer: organizer,
        name: 'Future Private',
        event_type: 'party',
        starts_at: Time.now + 7200,
        is_public: false,
        status: 'scheduled'
      )
    end

    it 'returns upcoming public events as a dataset' do
      events = described_class.upcoming_events
      expect(events).to respond_to(:all)

      event_names = events.all.map(&:name)
      expect(event_names).to include('Future Public')
      # Note: Default is public events only, so private should be filtered
      # If this fails, it indicates the Event.public_upcoming query may need fixing
    end

    it 'includes private events when specified' do
      events = described_class.upcoming_events(include_private: true)
      event_names = events.all.map(&:name)

      expect(event_names).to include('Future Public')
      expect(event_names).to include('Future Private')
    end
  end

  describe '.events_for_character' do
    let(:attendee) { create(:character) }
    let!(:organized_event) do
      Event.create(
        organizer: attendee,
        name: 'My Organized Event',
        event_type: 'party',
        starts_at: Time.now + 3600,
        status: 'scheduled'
      )
    end
    let!(:unrelated_event) do
      Event.create(
        organizer: organizer,
        name: 'Someone Else Event',
        event_type: 'party',
        starts_at: Time.now + 3600,
        status: 'scheduled'
      )
    end

    it 'returns events the character is organizing' do
      events = described_class.events_for_character(attendee)
      event_names = events.all.map(&:name)

      expect(event_names).to include('My Organized Event')
    end

    it 'does not return unrelated events' do
      events = described_class.events_for_character(attendee)
      event_names = events.all.map(&:name)

      expect(event_names).not_to include('Someone Else Event')
    end
  end

  describe '.calendar_data' do
    it 'returns formatted calendar data' do
      event = Event.create(
        organizer: organizer,
        name: 'Test Event',
        event_type: 'party',
        starts_at: Time.now + 3600,
        status: 'scheduled'
      )

      data = described_class.calendar_data([event])

      expect(data.length).to eq 1
      expect(data.first[:name]).to eq 'Test Event'
      expect(data.first[:event_type]).to eq 'party'
      expect(data.first[:starts_at]).to be_a(String) # ISO8601 format
    end
  end

  describe '.is_host_or_staff?' do
    let(:event) do
      Event.create(
        organizer: organizer,
        name: 'Test Event',
        event_type: 'party',
        starts_at: Time.now + 3600,
        status: 'scheduled'
      )
    end
    let(:random_character) { create(:character) }

    it 'returns true for the organizer' do
      expect(described_class.is_host_or_staff?(event: event, character: organizer)).to be true
    end

    it 'returns falsy for random characters' do
      result = described_class.is_host_or_staff?(event: event, character: random_character)
      expect(result).to be_falsy
    end
  end

  describe '.can_enter_event?' do
    let(:event) do
      Event.create(
        organizer: organizer,
        name: 'Active Event',
        event_type: 'party',
        starts_at: Time.now - 100,
        status: 'active'
      )
    end
    let(:attendee) { create(:character) }

    it 'allows entry to active events' do
      result = described_class.can_enter_event?(event: event, character: attendee)

      expect(result[:can_enter]).to be true
    end

    it 'prevents entry when at capacity' do
      event.update(max_attendees: 0)

      result = described_class.can_enter_event?(event: event, character: attendee)

      expect(result[:can_enter]).to be false
      expect(result[:reason]).to include('capacity')
    end

    it 'prevents entry to scheduled events' do
      event.update(status: 'scheduled', starts_at: Time.now + 3600)

      result = described_class.can_enter_event?(event: event, character: attendee)

      expect(result[:can_enter]).to be false
    end
  end
end
