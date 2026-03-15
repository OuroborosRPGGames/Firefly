# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::Property, type: :command do
  let(:location) { create(:location) }
  let(:room) { create(:room, room_type: 'plaza', location: location) }
  let(:reality) { create(:reality) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Alice') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: room,
           reality: reality,
           online: true)
  end

  subject { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
    allow(RoomExitCacheService).to receive(:invalidate_door_state!)
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'property', :building, ['properties', 'myproperties', 'owned', 'access', 'access list']

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['property']).to eq(described_class)
    end
  end

  # ========================================
  # Property Menu Tests
  # ========================================

  describe 'property (no args)' do
    it 'shows property menu' do
      result = subject.execute('property')

      expect(result[:interaction_id]).not_to be_nil
    end
  end

  # ========================================
  # Property List Tests
  # ========================================

  describe 'property list' do
    context 'with no owned properties' do
      it 'shows empty message' do
        result = subject.execute('property list')

        expect(result[:success]).to be true
        expect(result[:message]).to include("don't own any properties")
      end

      it 'returns empty properties array' do
        result = subject.execute('property list')

        expect(result[:data][:properties]).to eq([])
      end
    end

    context 'with owned properties' do
      let!(:owned_room) do
        create(:room, room_type: 'apartment', location: location, owner_id: character.id, name: 'My Apartment')
      end

      it 'shows owned properties' do
        result = subject.execute('property list')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Your Properties')
        expect(result[:message]).to include('My Apartment')
      end

      it 'returns properties count' do
        result = subject.execute('property list')

        expect(result[:data][:count]).to eq(1)
      end
    end
  end

  # ========================================
  # Access List Tests
  # ========================================

  describe 'property access' do
    context 'with no properties or access' do
      it 'shows access list' do
        result = subject.execute('property access')

        expect(result[:success]).to be true
        expect(result[:message]).to include("don't own any properties")
        expect(result[:message]).to include('Properties You Can Access')
      end
    end

    context 'with owned property' do
      let!(:owned_room) do
        create(:room, room_type: 'apartment', location: location, owner_id: character.id, name: 'My Apartment')
      end

      it 'shows owned properties in access list' do
        result = subject.execute('property access')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Your Properties')
        expect(result[:message]).to include('My Apartment')
      end
    end
  end

  # ========================================
  # Lock/Unlock Tests
  # ========================================

  describe 'property lock' do
    context 'as non-owner' do
      it 'returns error when locking room' do
        result = subject.execute('property lock')

        expect(result[:success]).to be false
      end
    end

    context 'as owner' do
      before do
        room.update(owner_id: character.id)
      end

      context 'with no doors' do
        it 'returns error when no doors' do
          result = subject.execute('property lock')

          expect(result[:success]).to be false
          expect(result[:error] || result[:message]).to include('no doors')
        end
      end

      context 'with door feature' do
        let!(:door_feature) do
          create(:room_feature, :door, room: room, direction: 'north', open_state: 'open')
        end

        it 'locks the door' do
          result = subject.execute('property lock')

          expect(result[:success]).to be true
          expect(result[:message]).to include('lock')
        end
      end

      context 'with connected door feature' do
        let(:connected_room) { create(:room, room_type: 'street', location: location) }
        let!(:door_feature) do
          create(:room_feature, :door, room: room, direction: 'north', open_state: 'open',
                                     connected_room_id: connected_room.id)
        end

        it 'invalidates door cache for both sides of the door connection' do
          result = subject.execute('property lock')

          expect(result[:success]).to be true
          expect(RoomExitCacheService).to have_received(:invalidate_door_state!).with(room.id)
          expect(RoomExitCacheService).to have_received(:invalidate_door_state!).with(connected_room.id)
        end
      end
    end
  end

  describe 'property unlock' do
    context 'as non-owner' do
      it 'returns error when unlocking room' do
        result = subject.execute('property unlock')

        expect(result[:success]).to be false
      end
    end

    context 'as owner' do
      before do
        room.update(owner_id: character.id)
      end

      context 'with no doors' do
        it 'returns error when no doors' do
          result = subject.execute('property unlock')

          expect(result[:success]).to be false
          expect(result[:error] || result[:message]).to include('no doors')
        end
      end

      context 'with locked door feature' do
        let!(:door_feature) do
          create(:room_feature, :door, room: room, direction: 'north', open_state: 'closed')
        end

        it 'unlocks the door' do
          result = subject.execute('property unlock')

          expect(result[:success]).to be true
          expect(result[:message]).to include('unlock')
        end
      end

      context 'with connected locked door feature' do
        let(:connected_room) { create(:room, room_type: 'street', location: location) }
        let!(:door_feature) do
          create(:room_feature, :door, room: room, direction: 'north', open_state: 'closed',
                                     connected_room_id: connected_room.id)
        end

        it 'invalidates door cache for both sides of the door connection' do
          result = subject.execute('property unlock')

          expect(result[:success]).to be true
          expect(RoomExitCacheService).to have_received(:invalidate_door_state!).with(room.id)
          expect(RoomExitCacheService).to have_received(:invalidate_door_state!).with(connected_room.id)
        end
      end
    end
  end

  # ========================================
  # Grant/Revoke Access Tests
  # ========================================

  describe 'property grant' do
    let(:other_user) { create(:user) }
    let(:other_character) { create(:character, user: other_user, forename: 'Bob') }

    before { other_character } # Ensure Bob exists

    context 'as non-owner' do
      it 'returns error' do
        result = subject.execute('property grant Bob')

        expect(result[:success]).to be false
      end
    end

    context 'as owner' do
      before do
        room.update(owner_id: character.id)
      end

      it 'returns error for nonexistent character' do
        result = subject.execute('property grant NonExistent')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('No character found')
      end

      it 'returns error when granting access to self' do
        result = subject.execute('property grant Alice')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('already have access')
      end

      it 'grants access to another character' do
        result = subject.execute('property grant Bob')

        expect(result[:success]).to be true
        expect(result[:message]).to include('grant')
        expect(result[:message]).to include('Bob')
      end
    end

    context 'with no name provided' do
      before do
        room.update(owner_id: character.id)
      end

      context 'with no one else in room' do
        it 'shows helpful message' do
          result = subject.execute('property grant')

          expect(result[:success]).to be true
          expect(result[:message]).to include('No one here')
        end
      end
    end
  end

  describe 'property revoke' do
    let(:other_user) { create(:user) }
    let(:other_character) { create(:character, user: other_user, forename: 'Bob') }

    before { other_character } # Ensure Bob exists

    context 'as non-owner' do
      it 'returns error' do
        result = subject.execute('property revoke Bob')

        expect(result[:success]).to be false
      end
    end

    context 'as owner' do
      before do
        room.update(owner_id: character.id)
      end

      it 'returns error for nonexistent character' do
        result = subject.execute('property revoke NonExistent')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include('No character found')
      end

      it 'returns error when revoking access from self' do
        result = subject.execute('property revoke Alice')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include("can't revoke your own")
      end

      it "returns error when character doesn't have access" do
        result = subject.execute('property revoke Bob')

        expect(result[:success]).to be false
        expect(result[:error] || result[:message]).to include("doesn't have access")
      end
    end

    context 'with no name provided' do
      before do
        room.update(owner_id: character.id)
      end

      context 'with no one having access' do
        it 'shows helpful message' do
          result = subject.execute('property revoke')

          expect(result[:success]).to be true
          expect(result[:message]).to include('No one has access')
        end
      end
    end
  end

  # ========================================
  # Unknown Action Tests
  # ========================================

  describe 'unknown action' do
    it 'returns error message' do
      result = subject.execute('property unknownaction')

      expect(result[:success]).to be false
      expect(result[:error] || result[:message]).to include("Unknown action")
    end
  end

  # ========================================
  # Alias Tests
  # ========================================

  describe 'aliases' do
    it 'command has properties alias' do
      alias_names = described_class.aliases.map { |a| a[:name] }
      expect(alias_names).to include('properties')
    end

    it 'command has access alias' do
      alias_names = described_class.aliases.map { |a| a[:name] }
      expect(alias_names).to include('access')
    end
  end
end
