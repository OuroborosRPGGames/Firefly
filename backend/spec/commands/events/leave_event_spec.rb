# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Events::LeaveEvent, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:reality) { create(:reality) }

  let(:host_user) { create(:user) }
  let(:host_character) { create(:character, forename: 'Host', surname: 'One', user: host_user) }

  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Two', user: user) }

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

  let!(:character_instance) do
    create(:character_instance,
      character: character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive',
      in_event_id: event.id
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'leaving event' do
      it 'leaves the event' do
        result = command.execute('leave event')
        expect(result[:success]).to be true
        expect(result[:message]).to include('leave')
        expect(result[:message]).to include('Test Party')
      end

      it 'clears in_event_id on character instance' do
        command.execute('leave event')
        character_instance.reload
        expect(character_instance.in_event?).to be false
        expect(character_instance.in_event_id).to be_nil
      end
    end

    context 'error cases' do
      it 'errors when not in an event' do
        character_instance.update(in_event_id: nil)
        result = command.execute('leave event')
        expect(result[:success]).to be false
        expect(result[:error]).to include("not in an event")
      end
    end
  end
end
