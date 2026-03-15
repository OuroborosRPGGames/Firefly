# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Events::Bounce, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:reality) { create(:reality) }

  # Host character
  let(:host_user) { create(:user) }
  let(:host_character) { create(:character, forename: 'Host', surname: 'One', user: host_user) }
  let!(:host_instance) do
    create(:character_instance,
      character: host_character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive'
    )
  end

  # Target character
  let(:target_user) { create(:user) }
  let(:target_character) { create(:character, forename: 'Troublemaker', surname: 'Two', user: target_user) }
  let!(:target_instance) do
    create(:character_instance,
      character: target_character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive'
    )
  end

  # Active event where host is organizer
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
    subject(:command) { described_class.new(host_instance) }

    context 'as event organizer' do
      it 'bounces target from event' do
        result = command.execute('bounce Troublemaker')
        expect(result[:success]).to be true
        expect(result[:message]).to include('bounce')
        expect(result[:message]).to include('Troublemaker')
      end

      it 'sets bounced flag on attendee record' do
        command.execute('bounce Troublemaker')
        attendee = EventAttendee.first(event_id: event.id, character_id: target_character.id)
        expect(attendee.bounced?).to be true
        expect(attendee.bounced_by_id).to eq(host_character.id)
      end

      it 'prevents re-bouncing already bounced character' do
        EventAttendee.create(
          event: event,
          character: target_character,
          bounced: true,
          bounced_by_id: host_character.id
        )
        result = command.execute('bounce Troublemaker')
        expect(result[:success]).to be false
        expect(result[:error]).to include('already bounced')
      end
    end

    context 'as event staff' do
      let(:staff_user) { create(:user) }
      let(:staff_character) { create(:character, forename: 'Staff', surname: 'Three', user: staff_user) }
      let(:staff_instance) do
        create(:character_instance,
          character: staff_character,
          reality: reality,
          current_room: room,
          online: true,
          status: 'alive'
        )
      end

      before do
        EventAttendee.create(event: event, character: staff_character, role: 'staff', status: 'yes')
      end

      it 'allows staff to bounce' do
        staff_command = described_class.new(staff_instance)
        result = staff_command.execute('bounce Troublemaker')
        expect(result[:success]).to be true
      end
    end

    context 'error cases' do
      it 'errors with no target specified' do
        result = command.execute('bounce')
        expect(result[:success]).to be false
        expect(result[:error]).to include('whom')
      end

      it 'errors when target not found' do
        result = command.execute('bounce Nobody')
        expect(result[:success]).to be false
        expect(result[:error]).to include('not here')
      end

      it 'errors when bouncing self' do
        result = command.execute('bounce Host')
        expect(result[:success]).to be false
        expect(result[:error]).to include('yourself')
      end

      it 'errors when not hosting an event' do
        event.update(status: 'completed')
        result = command.execute('bounce Troublemaker')
        expect(result[:success]).to be false
        expect(result[:error]).to include('not hosting')
      end

      it 'errors when not organizer or staff' do
        regular_command = described_class.new(target_instance)
        result = regular_command.execute('bounce Host')
        expect(result[:success]).to be false
        expect(result[:error]).to include('not hosting')
      end
    end
  end
end
