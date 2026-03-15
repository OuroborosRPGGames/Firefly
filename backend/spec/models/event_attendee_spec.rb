# frozen_string_literal: true

require 'spec_helper'

RSpec.describe EventAttendee do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:character) { create(:character) }
  let(:event) { create(:event, organizer: character, room: room, location: location) }
  let(:attendee_character) { create(:character) }
  let(:event_attendee) { EventAttendee.create(event_id: event.id, character_id: attendee_character.id) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(event_attendee).to be_valid
    end

    it 'requires event_id' do
      ea = EventAttendee.new(character_id: character.id)
      expect(ea).not_to be_valid
    end

    it 'requires character_id' do
      ea = EventAttendee.new(event_id: event.id)
      expect(ea).not_to be_valid
    end

    it 'validates uniqueness of character per event' do
      EventAttendee.create(event_id: event.id, character_id: attendee_character.id)
      duplicate = EventAttendee.new(event_id: event.id, character_id: attendee_character.id)
      expect(duplicate).not_to be_valid
    end

    it 'validates status inclusion' do
      %w[yes no maybe pending invited].each do |status|
        ea = EventAttendee.create(event_id: event.id, character_id: create(:character).id, status: status)
        expect(ea).to be_valid
      end
    end

    it 'validates role inclusion' do
      %w[attendee host staff vip].each do |role|
        ea = EventAttendee.create(event_id: event.id, character_id: create(:character).id, role: role)
        expect(ea).to be_valid
      end
    end
  end

  describe 'associations' do
    it 'belongs to event' do
      expect(event_attendee.event).to eq(event)
    end

    it 'belongs to character' do
      expect(event_attendee.character).to eq(attendee_character)
    end
  end

  describe 'before_save defaults' do
    it 'defaults status to invited' do
      expect(event_attendee.status).to eq('invited')
    end

    it 'defaults role to attendee' do
      expect(event_attendee.role).to eq('attendee')
    end

    it 'sets responded_at' do
      expect(event_attendee.responded_at).not_to be_nil
    end
  end

  describe '#attending?' do
    it 'returns true when status is yes' do
      event_attendee.update(status: 'yes')
      expect(event_attendee.attending?).to be true
    end

    it 'returns false when status is not yes' do
      expect(event_attendee.attending?).to be false
    end
  end

  describe '#host?' do
    it 'returns true when role is host' do
      event_attendee.update(role: 'host')
      expect(event_attendee.host?).to be true
    end

    it 'returns false when role is not host' do
      expect(event_attendee.host?).to be false
    end
  end

  describe '#staff?' do
    it 'returns true when role is host' do
      event_attendee.update(role: 'host')
      expect(event_attendee.staff?).to be true
    end

    it 'returns true when role is staff' do
      event_attendee.update(role: 'staff')
      expect(event_attendee.staff?).to be true
    end

    it 'returns false when role is attendee' do
      expect(event_attendee.staff?).to be false
    end
  end

  describe '#confirm!' do
    it 'sets status to yes' do
      event_attendee.confirm!
      expect(event_attendee.reload.status).to eq('yes')
    end
  end

  describe '#decline!' do
    it 'sets status to no' do
      event_attendee.decline!
      expect(event_attendee.reload.status).to eq('no')
    end
  end

  describe '#bounced?' do
    it 'returns true when bounced is true' do
      event_attendee.update(bounced: true)
      expect(event_attendee.bounced?).to be true
    end

    it 'returns false when bounced is false' do
      expect(event_attendee.bounced?).to be false
    end
  end

  describe '#bounce!' do
    it 'sets bounced to true' do
      bouncer = create(:character)
      ea = EventAttendee.create(event_id: event.id, character_id: create(:character).id)
      ea.bounce!(bouncer)
      expect(ea.reload.bounced).to be true
    end

    it 'records bounced_by_id' do
      bouncer = create(:character)
      ea = EventAttendee.create(event_id: event.id, character_id: create(:character).id)
      ea.bounce!(bouncer)
      expect(ea.reload.bounced_by_id).to eq(bouncer.id)
    end

    it 'records bounced_at' do
      bouncer = create(:character)
      ea = EventAttendee.create(event_id: event.id, character_id: create(:character).id)
      ea.bounce!(bouncer)
      expect(ea.reload.bounced_at).not_to be_nil
    end
  end

  describe '#unban!' do
    it 'sets bounced to false' do
      bouncer = create(:character)
      ea = EventAttendee.create(event_id: event.id, character_id: create(:character).id)
      ea.bounce!(bouncer)
      ea.unban!
      expect(ea.reload.bounced).to be false
    end

    it 'clears bounced_by_id' do
      bouncer = create(:character)
      ea = EventAttendee.create(event_id: event.id, character_id: create(:character).id)
      ea.bounce!(bouncer)
      ea.unban!
      expect(ea.reload.bounced_by_id).to be_nil
    end

    it 'clears bounced_at' do
      bouncer = create(:character)
      ea = EventAttendee.create(event_id: event.id, character_id: create(:character).id)
      ea.bounce!(bouncer)
      ea.unban!
      expect(ea.reload.bounced_at).to be_nil
    end
  end

  describe '#can_enter?' do
    it 'returns true when not bounced' do
      ea = EventAttendee.create(event_id: event.id, character_id: create(:character).id)
      expect(ea.can_enter?).to be true
    end

    it 'returns false when bounced' do
      ea = EventAttendee.create(event_id: event.id, character_id: create(:character).id, bounced: true)
      expect(ea.can_enter?).to be false
    end
  end

  describe '.bounced_from?' do
    it 'returns false when attendee not found' do
      expect(described_class.bounced_from?(event, create(:character))).to be false
    end

    it 'returns false when attendee exists but not bounced' do
      char = create(:character)
      EventAttendee.create(event_id: event.id, character_id: char.id)
      expect(described_class.bounced_from?(event, char)).to be false
    end

    it 'returns true when attendee is bounced' do
      char = create(:character)
      EventAttendee.create(event_id: event.id, character_id: char.id, bounced: true)
      expect(described_class.bounced_from?(event, char)).to be true
    end
  end

  describe 'constants' do
    it 'defines STATUSES' do
      expect(described_class::STATUSES).to eq(%w[invited yes no maybe pending])
    end

    it 'defines ROLES' do
      expect(described_class::ROLES).to eq(%w[attendee host staff vip])
    end
  end
end
