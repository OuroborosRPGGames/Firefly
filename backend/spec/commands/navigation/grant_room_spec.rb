# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::GrantRoom, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, name: 'Test Room', short_description: 'A room', location: location) }
  let(:user) { create(:user) }
  let(:character) { create(:character, forename: 'Alice', surname: 'Test', user: user) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room)
  end
  let(:user2) { create(:user) }
  let(:target_character) { create(:character, forename: 'Bob', surname: 'Smith', user: user2) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'when not owner' do
      it 'returns error' do
        result = command.execute('grant room Bob')
        expect(result[:success]).to be false
        expect(result[:error]).to include("don't own this room")
      end
    end

    context 'when owner' do
      before do
        room.update(owner_id: character.id)
      end

      context 'with no target specified' do
        it 'returns error' do
          result = command.execute('grant room')
          expect(result[:success]).to be false
          expect(result[:error]).to include('Who do you want to grant room access to?')
        end
      end

      context 'with valid target' do
        before { target_character }

        it 'returns success' do
          result = command.execute('grant room Bob')
          expect(result[:success]).to be true
        end

        it 'creates a room unlock for target' do
          expect { command.execute('grant room Bob') }.to change {
            RoomUnlock.where(room_id: room.id, character_id: target_character.id).count
          }.by(1)
        end
      end

      context 'with "access" prefix' do
        before { target_character }

        it 'handles "grant room access Bob"' do
          result = command.execute('grant room access Bob')
          expect(result[:success]).to be true
        end
      end

      context 'when target already has access' do
        before do
          target_character
          room.grant_access!(target_character, permanent: true)
        end

        it 'returns error' do
          result = command.execute('grant room Bob')
          expect(result[:success]).to be false
          expect(result[:error]).to include('already has access')
        end
      end
    end

    context 'with aliases' do
      it 'works with grant room access alias' do
        command_class, _words = Commands::Base::Registry.find_command('grant room access')
        expect(command_class).to eq(Commands::Navigation::GrantRoom)
      end
    end
  end
end
