# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Events::EventInfo do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'event info' : "event info #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('event info')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:events)
    end

    it 'has help_text' do
      expect(described_class.help_text).not_to be_nil
    end
  end

  describe '#execute' do
    context 'without event specified' do
      before do
        allow(character_instance).to receive(:in_event?).and_return(false)
        allow(EventService).to receive(:find_event_at).and_return(nil)
      end

      it 'returns error when no event found' do
        result = execute_command

        expect(result[:success]).to be false
        expect(result[:message]).to include('not found')
      end
    end

    context 'with specific event name' do
      let(:event) do
        double('Event',
               id: 1,
               name: 'Test Event',
               description: 'A test event',
               starts_at: Time.now + 3600,
               ends_at: nil,
               started_at: nil,
               ended_at: nil,
               event_type: 'party',
               status: 'scheduled',
               is_public: true,
               organizer_id: character.id,
               organizer: character,
               room: double(name: 'Town Square'),
               location: nil,
               attendee_count: 0,
               max_attendees: nil,
               active?: false,
               scheduled?: true,
               attending?: false)
      end

      before do
        allow(Event).to receive(:where).and_return(double(first: event))
        allow(EventService).to receive(:is_host_or_staff?).and_return(true)
        allow(character_instance).to receive(:in_event?).and_return(false)
        allow(character_instance).to receive(:in_event_id).and_return(nil)
      end

      it 'shows event details' do
        result = execute_command('Test Event')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Test Event')
      end
    end
  end
end
