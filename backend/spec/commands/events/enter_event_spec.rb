# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Events::EnterEvent, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:reality) { create(:reality) }

  let(:host_user) { create(:user) }
  let(:host_character) { create(:character, forename: 'Host', surname: 'One', user: host_user) }

  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Two', user: user) }
  let!(:character_instance) do
    create(:character_instance,
      character: character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive'
    )
  end

  let!(:event) do
    Event.create(
      name: 'Test Party',
      title: 'Test Party',
      event_type: 'party',
      organizer: host_character,
      room: room,
      location: location,
      starts_at: Time.now - 3600,
      status: 'active'
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'entering active event' do
      it 'enters the event' do
        result = command.execute('enter event')
        expect(result[:success]).to be true
        expect(result[:message]).to include('enter')
        expect(result[:message]).to include('Test Party')
      end

      it 'sets in_event_id on character instance' do
        command.execute('enter event')
        character_instance.reload
        expect(character_instance.in_event?).to be true
        expect(character_instance.in_event_id).to eq(event.id)
      end

      it 'creates attendee record with confirmed status' do
        command.execute('enter event')
        attendee = EventAttendee.first(event_id: event.id, character_id: character.id)
        expect(attendee).not_to be_nil
        expect(attendee.attending?).to be true
      end
    end

    context 'error cases' do
      it 'errors when already in an event' do
        character_instance.update(in_event_id: event.id)
        result = command.execute('enter event')
        expect(result[:success]).to be false
        expect(result[:error]).to include('already in an event')
      end

      it 'errors when no event at location' do
        event.destroy
        result = command.execute('enter event')
        expect(result[:success]).to be false
        expect(result[:error]).to include('no active event')
      end

      it 'errors when bounced from event' do
        EventAttendee.create(
          event: event,
          character: character,
          bounced: true,
          bounced_by_id: host_character.id
        )
        result = command.execute('enter event')
        expect(result[:success]).to be false
        expect(result[:error]).to include('bounced')
      end
    end

    context 'auto-start for organizer' do
      let!(:host_instance) do
        create(:character_instance,
          character: host_character,
          reality: reality,
          current_room: room,
          online: true,
          status: 'alive'
        )
      end

      let!(:scheduled_event) do
        Event.create(
          name: 'Scheduled Party',
          title: 'Scheduled Party',
          event_type: 'party',
          organizer: host_character,
          room: room,
          location: location,
          starts_at: Time.now + 1800,
          status: 'scheduled'
        )
      end

      before do
        event.destroy
      end

      it 'auto-starts event when organizer enters' do
        host_command = described_class.new(host_instance)
        host_command.execute('enter event')
        scheduled_event.reload
        expect(scheduled_event.active?).to be true
      end
    end
  end
end
