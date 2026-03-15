# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Staff::Goto, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:zone, world: world) }
  let(:location) { create(:location, zone: zone) }
  let(:room) { create(:room, location: location, name: 'Starting Room') }
  let(:target_room) { create(:room, location: location, name: 'Target Room') }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Staff', surname: 'Person') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true)
  end

  let(:target_user) { create(:user, username: 'targetuser') }
  let(:target_character) { create(:character, user: target_user, forename: 'Target', surname: 'Character') }
  let(:target_character_instance) do
    create(:character_instance,
           character: target_character,
           reality: reality,
           current_room: target_room,
           online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_room)
  end

  it_behaves_like "command metadata", 'goto', :staff, ['teleport', 'tp']

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['goto']).to eq(described_class)
    end
  end

  describe 'permission validation' do
    context 'when character is not staff' do
      before do
        allow(character).to receive(:staff?).and_return(false)
      end

      it 'rejects non-staff users' do
        result = command.execute('goto 1')

        expect(result[:success]).to be false
        expect(result[:message]).to include('staff members')
      end
    end

    context 'when character is staff' do
      before do
        allow(character).to receive(:staff?).and_return(true)
      end

      it 'allows staff to teleport' do
        result = command.execute("goto #{target_room.id}")

        expect(result[:success]).to be true
      end
    end
  end

  describe 'goto by room ID' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    it 'teleports to room by ID' do
      result = command.execute("goto #{target_room.id}")

      expect(result[:success]).to be true
      expect(result[:message]).to include('Target Room')
      expect(character_instance.reload.current_room_id).to eq(target_room.id)
    end

    it 'returns error for non-existent room ID' do
      result = command.execute('goto 999999')

      expect(result[:success]).to be false
      expect(result[:message]).to include('No room found')
    end

    it 'returns error if already in that room' do
      result = command.execute("goto #{room.id}")

      expect(result[:success]).to be false
      expect(result[:message]).to include("already in")
    end

    it 'broadcasts departure from original room' do
      command.execute("goto #{target_room.id}")

      expect(BroadcastService).to have_received(:to_room).with(
        room.id,
        a_string_including('vanishes'),
        hash_including(exclude: [character_instance.id], type: :departure)
      )
    end

    it 'broadcasts arrival to target room' do
      command.execute("goto #{target_room.id}")

      expect(BroadcastService).to have_received(:to_room).with(
        target_room.id,
        a_string_including('appears'),
        hash_including(exclude: [character_instance.id], type: :arrival)
      )
    end

    it 'includes structured data in response' do
      result = command.execute("goto #{target_room.id}")

      expect(result[:data]).to include(
        action: 'teleport',
        from_room: 'Starting Room',
        to_room: 'Target Room',
        to_room_id: target_room.id
      )
    end
  end

  describe 'goto by character name' do
    before do
      allow(character).to receive(:staff?).and_return(true)
      target_character_instance # Create the target character instance
    end

    it 'teleports to online character by full name' do
      result = command.execute('goto Target Character')

      expect(result[:success]).to be true
      expect(result[:message]).to include("Target Character's location")
      expect(character_instance.reload.current_room_id).to eq(target_room.id)
    end

    it 'teleports to online character by first name' do
      result = command.execute('goto Target')

      expect(result[:success]).to be true
      expect(character_instance.reload.current_room_id).to eq(target_room.id)
    end

    it 'returns error for unknown character' do
      result = command.execute('goto Nonexistent Person')

      expect(result[:success]).to be false
      expect(result[:message]).to include('No character found')
    end

    it 'includes target character in response data' do
      result = command.execute('goto Target Character')

      expect(result[:data][:target_character]).to eq('Target Character')
    end
  end

  describe 'usage validation' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    it 'returns usage error with no arguments' do
      result = command.execute('goto')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Usage')
    end

    it 'returns usage error with empty arguments' do
      result = command.execute('goto ')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Usage')
    end
  end
end
