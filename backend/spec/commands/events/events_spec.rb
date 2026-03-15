# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Events::EventsCmd, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character, forename: 'Alice') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true)
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with no arguments' do
      it 'returns a quickmenu' do
        result = command.execute('events')

        expect(result[:type]).to eq(:quickmenu)
      end

      context 'when there are no events' do
        it 'shows create prompt' do
          result = command.execute('events')

          expect(result[:data][:prompt]).to include('Create')
        end
      end

      context 'when there are upcoming events' do
        before do
          Event.create(
            organizer: character,
            room: room,
            name: 'Birthday Party',
            title: 'Birthday Party',
            event_type: 'party',
            starts_at: Time.now + 3600,
            is_public: true,
            status: 'scheduled'
          )
        end

        it 'shows events count in prompt' do
          result = command.execute('events')

          expect(result[:data][:prompt]).to include('Events')
        end

        it 'includes action options' do
          result = command.execute('events')

          options = result[:data][:options]
          keys = options.map { |o| o[:key] }
          expect(keys).to include('c')  # Create
          expect(keys).to include('m')  # My events
          expect(keys).to include('q')  # Close
        end
      end
    end

    context 'with "my" filter' do
      context 'when character has events' do
        before do
          Event.create(
            organizer: character,
            name: 'My Party',
            title: 'My Party',
            event_type: 'party',
            starts_at: Time.now + 3600,
            status: 'scheduled'
          )
        end

        it 'shows events character is organizing' do
          result = command.execute('events my')

          expect(result[:success]).to be true
          expect(result[:message]).to include('My Party')
        end
      end

      context 'when character has no events' do
        it 'shows helpful message' do
          result = command.execute('events my')

          expect(result[:success]).to be true
          expect(result[:message]).to include('no upcoming events')
        end
      end
    end

    context 'with "here" filter' do
      context 'when there are events at current room' do
        before do
          Event.create(
            organizer: character,
            room: room,
            name: 'Room Party',
            title: 'Room Party',
            event_type: 'party',
            starts_at: Time.now + 3600,
            status: 'scheduled'
          )
        end

        it 'shows events at current room' do
          result = command.execute('events here')

          expect(result[:success]).to be true
          expect(result[:message]).to include('Room Party')
        end
      end

      context 'when there are no events here' do
        it 'shows helpful message' do
          result = command.execute('events here')

          expect(result[:success]).to be true
          expect(result[:message]).to include('No upcoming events')
        end
      end
    end

    context 'with "create" filter' do
      it 'shows a form' do
        result = command.execute('events create')

        expect(result[:type]).to eq(:form)
      end

      it 'includes the event name field' do
        result = command.execute('events create')

        fields = result[:data][:fields]
        field_names = fields.map { |f| f[:name] }
        expect(field_names).to include('name')
      end
    end
  end
end
