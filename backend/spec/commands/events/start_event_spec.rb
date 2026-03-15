# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Events::StartEvent do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'start event' : "start event #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('start event')
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
        where_double = double('where')
        allow(Event).to receive(:where).and_return(where_double)
        allow(where_double).to receive(:where).and_return(where_double)
        allow(where_double).to receive(:first).and_return(nil)
      end

      it 'shows error if no event found' do
        result = execute_command

        expect(result[:success]).to be false
        expect(result[:message]).to include('not found')
      end
    end

    context 'with event name' do
      let(:event) do
        double('Event',
               id: 1,
               name: 'Test Event',
               organizer_id: character.id,
               room: room,
               active?: false,
               completed?: false,
               cancelled?: false)
      end

      before do
        where_double = double('where')
        allow(Event).to receive(:where).and_return(where_double)
        allow(where_double).to receive(:where).and_return(where_double)
        allow(where_double).to receive(:first).and_return(event)
        allow(EventService).to receive(:start_event!).and_return({ success: true })
        allow(character_instance).to receive(:in_event_id).and_return(nil)
        allow(character_instance).to receive(:enter_event!)
      end

      it 'starts the event if user is organizer' do
        result = execute_command('Test Event')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Test Event')
      end
    end
  end
end
