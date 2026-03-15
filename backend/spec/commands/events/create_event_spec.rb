# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Events::CreateEvent do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, reality: reality, online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  def execute_command(args = nil)
    input = args.nil? ? 'create event' : "create event #{args}"
    command.execute(input)
  end


  describe 'command metadata' do
    it 'has correct command_name' do
      expect(described_class.command_name).to eq('create event')
    end

    it 'has correct category' do
      expect(described_class.category).to eq(:events)
    end

    it 'has aliases' do
      alias_names = described_class.aliases.map { |a| a[:name] }
      expect(alias_names).to include('newevent')
    end

    it 'has help_text' do
      expect(described_class.help_text).not_to be_nil
    end
  end

  describe '#execute' do
    context 'without arguments' do
      it 'returns modal result' do
        result = execute_command

        expect(result[:success]).to be true
        expect(result[:type]).to eq(:modal)
        expect(result[:data][:action]).to eq('create_event')
      end

      it 'includes default values' do
        result = execute_command

        expect(result[:data][:defaults]).to be_a(Hash)
        expect(result[:data][:defaults][:room_id]).to eq(room.id)
      end
    end

    context 'with event name' do
      let(:event) do
        double('Event',
          id: 1,
          name: 'Test Party',
          starts_at: Time.now + 3600,
          add_attendee: true
        )
      end

      before do
        allow(EventService).to receive(:create_event).and_return(event)
        allow(event).to receive(:add_attendee).and_return(true)
      end

      it 'creates event with quick create' do
        execute_command('Test Party')

        expect(EventService).to have_received(:create_event).with(
          hash_including(name: 'Test Party')
        )
      end

      it 'returns success result' do
        result = execute_command('Test Party')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Test Party')
      end
    end

    context 'when event creation fails' do
      before do
        allow(EventService).to receive(:create_event).and_return(nil)
      end

      it 'returns error' do
        result = execute_command('Failed Event')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Failed to create')
      end
    end
  end
end
