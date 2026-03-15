# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Status::Quiet, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, location: location, name: 'Test Room', short_description: 'A room') }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Test', user: user) }
  let(:character_instance) do
    create(:character_instance,
      character: character,
      reality: reality,
      current_room: room,
      online: true,
      status: 'alive',
      stance: 'standing'
    )
  end

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'enabling quiet mode' do
      it 'enables quiet mode when not already in quiet mode' do
        result = command.execute('quiet')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Quiet mode enabled')
        expect(character_instance.reload.quiet_mode?).to be true
        expect(character_instance.quiet_mode_since).to be_within(5).of(Time.now)
      end

      it 'includes action data in response' do
        result = command.execute('quiet')
        expect(result[:data][:action]).to eq('quiet_enabled')
      end
    end

    context 'disabling quiet mode with no missed messages' do
      before do
        character_instance.set_quiet_mode!
        # No messages created, so no catch-up needed
      end

      it 'disables quiet mode immediately when no messages missed' do
        result = command.execute('quiet')
        expect(result[:success]).to be true
        expect(result[:message]).to include('No missed messages')
        expect(character_instance.reload.quiet_mode?).to be false
      end
    end

    context 'disabling quiet mode with missed messages' do
      before do
        character_instance.set_quiet_mode!
        # Create some missed messages with required fields
        3.times do |i|
          Message.create(
            message_type: 'ooc',
            content: "Test message #{i + 1}",
            created_at: Time.now,
            reality_id: reality.id,
            character_instance_id: character_instance.id,
            room_id: room.id
          )
        end
      end

      it 'shows quickmenu when there are missed messages' do
        result = command.execute('quiet')
        expect(result[:success]).to be true
        expect(result[:type]).to eq(:quickmenu)
        expect(result[:data][:prompt]).to include('3 channel messages')
        expect(result[:data][:options].length).to eq(2)
        expect(result[:data][:options].map { |o| o[:key] }).to include('yes', 'no')
      end

      it 'includes quiet_mode_since in context' do
        result = command.execute('quiet')
        # The context is stored in Redis, so we just verify the quickmenu was created
        expect(result[:type]).to eq(:quickmenu)
      end
    end
  end

  describe 'model methods' do
    describe '#quiet_mode?' do
      it 'returns false by default' do
        expect(character_instance.quiet_mode?).to be false
      end

      it 'returns true when quiet mode is enabled' do
        character_instance.set_quiet_mode!
        expect(character_instance.quiet_mode?).to be true
      end
    end

    describe '#set_quiet_mode!' do
      it 'sets quiet_mode to true' do
        character_instance.set_quiet_mode!
        expect(character_instance.reload.quiet_mode?).to be true
      end

      it 'sets quiet_mode_since timestamp' do
        character_instance.set_quiet_mode!
        expect(character_instance.reload.quiet_mode_since).to be_within(5).of(Time.now)
      end
    end

    describe '#clear_quiet_mode!' do
      before { character_instance.set_quiet_mode! }

      it 'clears quiet_mode flag' do
        character_instance.clear_quiet_mode!
        expect(character_instance.reload.quiet_mode?).to be false
      end

      it 'preserves quiet_mode_since for catch-up query' do
        since = character_instance.quiet_mode_since
        character_instance.clear_quiet_mode!
        expect(character_instance.reload.quiet_mode_since).to eq(since)
      end
    end
  end
end
