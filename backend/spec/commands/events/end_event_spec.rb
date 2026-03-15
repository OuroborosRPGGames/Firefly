# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Events::EndEvent, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:reality) { create(:reality) }

  let(:host_user) { create(:user) }
  let(:host_character) { create(:character, forename: 'Host', surname: 'One', user: host_user) }

  let(:attendee_user) { create(:user) }
  let(:attendee_character) { create(:character, forename: 'Attendee', surname: 'Two', user: attendee_user) }

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

  let!(:host_instance) do
    create(:character_instance,
      character: host_character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive',
      in_event_id: event.id
    )
  end

  let!(:attendee_instance) do
    create(:character_instance,
      character: attendee_character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive',
      in_event_id: event.id
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(host_instance) }

    context 'as event host' do
      it 'ends the event' do
        result = command.execute('end event')
        expect(result[:success]).to be true
        expect(result[:message]).to include('ended')
        expect(result[:message]).to include('Test Party')
      end

      it 'sets event status to completed' do
        command.execute('end event')
        event.reload
        expect(event.completed?).to be true
      end

      it 'clears in_event_id for all attendees' do
        command.execute('end event')
        host_instance.reload
        attendee_instance.reload
        expect(host_instance.in_event?).to be false
        expect(attendee_instance.in_event?).to be false
      end
    end

    context 'error cases' do
      it 'errors when not in an event' do
        host_instance.update(in_event_id: nil)
        result = command.execute('end event')
        expect(result[:success]).to be false
        expect(result[:error]).to include("not in an event")
      end

      it 'errors when not the host' do
        attendee_command = described_class.new(attendee_instance)
        result = attendee_command.execute('end event')
        expect(result[:success]).to be false
        expect(result[:error]).to include("not the host")
      end

      it 'errors when event already ended' do
        event.update(status: 'completed')
        result = command.execute('end event')
        expect(result[:success]).to be false
        expect(result[:error]).to include("already ended")
      end
    end
  end
end
