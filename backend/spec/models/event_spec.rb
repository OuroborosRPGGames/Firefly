# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Event do
  let(:room) { create(:room) }
  let(:location) { room.location }
  let(:organizer) { create(:character) }

  describe 'validations' do
    it 'requires name' do
      event = Event.new(event_type: 'party', starts_at: Time.now)
      expect(event.valid?).to be false
      expect(event.errors[:name]).to include('is not present')
    end

    it 'requires event_type' do
      event = Event.new(name: 'Test Event', starts_at: Time.now)
      expect(event.valid?).to be false
      expect(event.errors[:event_type]).to include('is not present')
    end

    it 'requires starts_at' do
      event = Event.new(name: 'Test Event', event_type: 'party')
      expect(event.valid?).to be false
      expect(event.errors[:starts_at]).to include('is not present')
    end

    it 'validates name length' do
      event = Event.new(name: 'a' * 201, event_type: 'party', starts_at: Time.now)
      expect(event.valid?).to be false
      expect(event.errors[:name]).to include('is longer than 200 characters')
    end

    it 'validates event_type is one of allowed values' do
      event = Event.new(name: 'Test', event_type: 'invalid', starts_at: Time.now)
      expect(event.valid?).to be false
      expect(event.errors[:event_type]).not_to be_empty
    end

    it 'accepts all valid event types' do
      Event::EVENT_TYPES.each do |type|
        event = Event.new(name: "Test #{type}", event_type: type, starts_at: Time.now)
        expect(event.valid?).to be(true), "Expected #{type} to be valid but got errors: #{event.errors.full_messages}"
      end
    end

    it 'validates status is one of allowed values' do
      event = Event.new(name: 'Test', event_type: 'party', starts_at: Time.now, status: 'invalid')
      expect(event.valid?).to be false
    end

    it 'validates logs_visible_to is one of allowed values' do
      event = Event.new(name: 'Test', event_type: 'party', starts_at: Time.now, logs_visible_to: 'invalid')
      expect(event.valid?).to be false
    end
  end

  describe 'defaults' do
    it 'sets status to scheduled by default' do
      event = create(:event, room: room, organizer: organizer)
      expect(event.status).to eq('scheduled')
    end

    it 'sets is_public to true by default' do
      event = create(:event, room: room, organizer: organizer)
      expect(event.is_public).to be true
    end

    it 'sets logs_visible_to to public by default' do
      event = create(:event, room: room, organizer: organizer)
      expect(event.logs_visible_to).to eq('public')
    end
  end

  describe 'status predicates' do
    let(:event) { create(:event, room: room, organizer: organizer) }

    it '#scheduled? returns true when status is scheduled' do
      event.update(status: 'scheduled')
      expect(event.scheduled?).to be true
      expect(event.active?).to be false
    end

    it '#active? returns true when status is active' do
      event.update(status: 'active')
      expect(event.active?).to be true
      expect(event.scheduled?).to be false
    end

    it '#completed? returns true when status is completed' do
      event.update(status: 'completed')
      expect(event.completed?).to be true
    end

    it '#cancelled? returns true when status is cancelled' do
      event.update(status: 'cancelled')
      expect(event.cancelled?).to be true
    end
  end

  describe 'status transitions' do
    let(:event) { create(:event, room: room, organizer: organizer) }

    describe '#start!' do
      it 'changes status to active' do
        event.start!
        expect(event.status).to eq('active')
      end

      it 'sets started_at timestamp' do
        freeze_time = Time.now
        allow(Time).to receive(:now).and_return(freeze_time)

        event.start!
        expect(event.started_at).to eq(freeze_time)
      end
    end

    describe '#complete!' do
      it 'changes status to completed' do
        event.complete!
        expect(event.status).to eq('completed')
      end

      it 'sets ended_at timestamp' do
        freeze_time = Time.now
        allow(Time).to receive(:now).and_return(freeze_time)

        event.complete!
        expect(event.ended_at).to eq(freeze_time)
      end
    end

    describe '#cancel!' do
      it 'changes status to cancelled' do
        event.cancel!
        expect(event.status).to eq('cancelled')
      end
    end
  end

  describe 'timing predicates' do
    describe '#upcoming?' do
      it 'returns true when scheduled and starts in the future' do
        event = create(:event, room: room, organizer: organizer, starts_at: Time.now + 3600)
        expect(event.upcoming?).to be true
      end

      it 'returns false when starts_at is in the past' do
        event = create(:event, room: room, organizer: organizer, starts_at: Time.now - 3600)
        expect(event.upcoming?).to be false
      end

      it 'returns false when status is active' do
        event = create(:event, room: room, organizer: organizer, starts_at: Time.now + 3600, status: 'active')
        expect(event.upcoming?).to be false
      end
    end

    describe '#in_progress?' do
      it 'returns true when active' do
        event = create(:event, room: room, organizer: organizer, status: 'active')
        expect(event.in_progress?).to be true
      end

      it 'returns true when scheduled and start time has passed' do
        event = create(:event, room: room, organizer: organizer, starts_at: Time.now - 60)
        expect(event.in_progress?).to be true
      end

      it 'returns false when scheduled and end time has passed' do
        event = create(:event, room: room, organizer: organizer, starts_at: Time.now - 3600, ends_at: Time.now - 1800)
        expect(event.in_progress?).to be false
      end
    end
  end

  describe 'attendee management' do
    let(:event) { create(:event, room: room, organizer: organizer) }
    let(:character) { create(:character) }

    describe '#add_attendee' do
      it 'adds a character as an attendee' do
        event.add_attendee(character)
        expect(event.attending?(character)).to be true
      end

      it 'does not duplicate attendees' do
        event.add_attendee(character)
        event.add_attendee(character)
        expect(EventAttendee.where(event_id: event.id, character_id: character.id).count).to eq(1)
      end

      it 'accepts rsvp option' do
        event.add_attendee(character, rsvp: 'maybe')
        attendee = EventAttendee.first(event_id: event.id, character_id: character.id)
        expect(attendee.status).to eq('maybe')
      end
    end

    describe '#attending?' do
      it 'returns true when character has RSVP yes' do
        event.add_attendee(character, rsvp: 'yes')
        expect(event.attending?(character)).to be true
      end

      it 'returns false when character has RSVP maybe' do
        event.add_attendee(character, rsvp: 'maybe')
        expect(event.attending?(character)).to be false
      end

      it 'returns false when character is not an attendee' do
        expect(event.attending?(character)).to be false
      end
    end

    describe '#attendee_count' do
      it 'counts only yes RSVPs' do
        char1 = create(:character)
        char2 = create(:character)
        char3 = create(:character)

        event.add_attendee(char1, rsvp: 'yes')
        event.add_attendee(char2, rsvp: 'yes')
        event.add_attendee(char3, rsvp: 'maybe')

        expect(event.attendee_count).to eq(2)
      end
    end

    describe '#was_attending?' do
      it 'returns true when character was ever an attendee' do
        event.add_attendee(character, rsvp: 'no')
        expect(event.was_attending?(character)).to be true
      end

      it 'returns false when character was never an attendee' do
        expect(event.was_attending?(character)).to be false
      end

      it 'returns false for nil character' do
        expect(event.was_attending?(nil)).to be false
      end
    end
  end

  describe '#can_view_logs?' do
    let(:event) { create(:event, room: room, organizer: organizer) }
    let(:attendee) { create(:character) }
    let(:stranger) { create(:character) }

    before do
      event.add_attendee(attendee, rsvp: 'yes')
    end

    context 'when logs_visible_to is public' do
      before { event.update(logs_visible_to: 'public') }

      it 'returns true for anyone' do
        expect(event.can_view_logs?(stranger)).to be true
        expect(event.can_view_logs?(nil)).to be true
      end
    end

    context 'when logs_visible_to is attendees' do
      before { event.update(logs_visible_to: 'attendees') }

      it 'returns true for attendees' do
        expect(event.can_view_logs?(attendee)).to be true
      end

      it 'returns true for organizer' do
        expect(event.can_view_logs?(organizer)).to be true
      end

      it 'returns false for strangers' do
        expect(event.can_view_logs?(stranger)).to be false
      end

      it 'returns false for anonymous viewers' do
        expect(event.can_view_logs?(nil)).to be false
      end
    end

    context 'when logs_visible_to is organizer' do
      before { event.update(logs_visible_to: 'organizer') }

      it 'returns true for organizer' do
        expect(event.can_view_logs?(organizer)).to be true
      end

      it 'returns false for attendees' do
        expect(event.can_view_logs?(attendee)).to be false
      end
    end
  end

  describe 'class methods' do
    let!(:past_event) { create(:event, room: room, organizer: organizer, starts_at: Time.now - 3600, status: 'completed') }
    let!(:future_event) { create(:event, room: room, organizer: organizer, starts_at: Time.now + 3600) }
    let!(:active_event) { create(:event, room: room, organizer: organizer, starts_at: Time.now - 60, status: 'active') }
    let!(:cancelled_event) { create(:event, room: room, organizer: organizer, starts_at: Time.now + 7200, status: 'cancelled') }

    describe '.upcoming' do
      it 'returns scheduled and active events starting in the future' do
        result = Event.upcoming
        expect(result).to include(future_event)
        expect(result).not_to include(past_event)
        expect(result).not_to include(cancelled_event)
      end

      it 'respects limit parameter' do
        result = Event.upcoming(limit: 1)
        expect(result.count).to eq(1)
      end
    end

    describe '.public_upcoming' do
      it 'only returns public events' do
        # Create events with distinct start times to isolate this test
        public_event = create(:event, room: room, organizer: organizer, starts_at: Time.now + 10000, is_public: true)
        private_event = create(:event, room: room, organizer: organizer, starts_at: Time.now + 10001, is_public: false)

        result = Event.public_upcoming.all
        public_ids = result.select { |e| e.is_public }.map(&:id)
        private_ids = result.reject { |e| e.is_public }.map(&:id)

        expect(public_ids).to include(public_event.id)
        expect(private_ids).to be_empty
      end
    end

    describe '.for_character' do
      let(:character) { create(:character) }

      it 'returns events where character is organizer' do
        char_event = create(:event, room: room, organizer: character, starts_at: Time.now + 3600)
        result = Event.for_character(character)
        expect(result).to include(char_event)
      end

      it 'returns events where character is attendee' do
        future_event.add_attendee(character, rsvp: 'yes')
        result = Event.for_character(character)
        expect(result).to include(future_event)
      end
    end

    describe '.active_events' do
      it 'returns only active events' do
        result = Event.active_events
        expect(result).to include(active_event)
        expect(result).not_to include(future_event)
        expect(result).not_to include(past_event)
      end
    end

    describe '.active_at_room' do
      it 'returns active event at the room' do
        result = Event.active_at_room(room)
        expect(result).to eq(active_event)
      end

      it 'returns nil when no active event at room' do
        other_room = create(:room)
        result = Event.active_at_room(other_room)
        expect(result).to be_nil
      end
    end

    describe '.at_location' do
      it 'returns upcoming events at location' do
        event_at_location = create(:event, room: room, location: location, organizer: organizer, starts_at: Time.now + 3600)
        result = Event.at_location(location)
        expect(result).to include(event_at_location)
      end
    end

    describe '.at_room' do
      it 'returns upcoming events at room' do
        result = Event.at_room(room)
        expect(result).to include(future_event)
      end
    end
  end

  describe '#characters_in_event' do
    let(:event) { create(:event, room: room, organizer: organizer) }
    let(:character_instance) { create(:character_instance, in_event_id: event.id) }

    it 'returns character instances in the event' do
      character_instance # force creation
      result = event.characters_in_event
      expect(result).to include(character_instance)
    end
  end

  describe '#end_for_all!' do
    let(:event) { create(:event, room: room, organizer: organizer, status: 'active') }
    let!(:character_instance) { create(:character_instance, in_event_id: event.id) }

    before do
      # Mock cleanup methods
      allow(EventDecoration).to receive(:cleanup_event!)
      allow(EventPlace).to receive(:cleanup_event!)
    end

    it 'removes all characters from event' do
      event.end_for_all!
      character_instance.refresh
      expect(character_instance.in_event_id).to be_nil
    end

    it 'cleans up temporary content' do
      event.end_for_all!
      expect(EventDecoration).to have_received(:cleanup_event!).with(event)
      expect(EventPlace).to have_received(:cleanup_event!).with(event)
    end

    it 'completes the event' do
      event.end_for_all!
      expect(event.status).to eq('completed')
    end
  end
end
