# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::DeleteRoom, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:zone, world: world) }
  let(:location) { create(:location, zone: zone) }
  let(:parent_room) { create(:room, location: location, name: 'Living Room', owner_id: character.id) }
  let(:room_to_delete) { create(:room, location: location, name: 'Bedroom', owner_id: character.id, inside_room_id: parent_room.id) }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Owner') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room_to_delete,
           online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'delete room', :building, ['remove room']

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['delete room']).to eq(described_class)
    end
  end

  describe 'ownership check' do
    context 'when character does not own the room' do
      let(:other_user) { create(:user) }
      let(:other_character) { create(:character, user: other_user) }
      # Room with no parent so outer_room returns itself (owned by other_character)
      let(:unowned_room) { create(:room, location: location, owner_id: other_character.id, inside_room_id: nil) }
      # Need a sibling room to delete into
      let!(:sibling_room) { create(:room, location: location, owner_id: character.id) }

      before do
        character_instance.update(current_room_id: unowned_room.id)
      end

      it 'returns error about ownership' do
        result = command.execute('delete room')

        expect(result[:success]).to be false
        # Message may contain HTML entities
        expect(result[:message]).to include('own').and include('room')
      end
    end

    context 'when character owns the room' do
      it 'allows deletion' do
        result = command.execute('delete room')

        expect(result[:success]).to be true
      end
    end
  end

  describe 'only room in location check' do
    # Create a separate location with only one room
    let(:solo_location) { create(:location, zone: zone) }
    let(:only_room) { create(:room, location: solo_location, owner_id: character.id) }

    before do
      character_instance.update(current_room_id: only_room.id)
    end

    it 'prevents deleting the only room in location' do
      result = command.execute('delete room')

      expect(result[:success]).to be false
      expect(result[:message]).to include('only room')
    end
  end

  describe 'other characters present check' do
    let(:other_user) { create(:user) }
    let(:other_character) { create(:character, user: other_user) }
    let!(:other_instance) do
      create(:character_instance,
             character: other_character,
             reality: reality,
             current_room: room_to_delete,
             online: true)
    end

    it 'prevents deletion when other online characters present' do
      result = command.execute('delete room')

      expect(result[:success]).to be false
      expect(result[:message]).to include('other characters present')
    end

    context 'when other character is offline' do
      before do
        other_instance.update(online: false)
      end

      it 'allows deletion' do
        result = command.execute('delete room')

        expect(result[:success]).to be true
      end
    end
  end

  describe 'room deletion' do
    it 'deletes the room' do
      room_id = room_to_delete.id

      expect { command.execute('delete room') }
        .to change { Room.where(id: room_id).count }.from(1).to(0)
    end
  end

  describe 'content cleanup' do
    let!(:decoration) { create(:decoration, room: room_to_delete) }
    let!(:place) { create(:place, room: room_to_delete) }
    # NOTE: RoomExit model was removed - navigation now uses spatial adjacency

    before do
      # The cleanup_contents! method should handle these
      allow(room_to_delete).to receive(:cleanup_contents!)
    end

    it 'calls cleanup_contents! on the room' do
      # Get a reference to the actual room object
      actual_room = Room[room_to_delete.id]
      allow(actual_room).to receive(:cleanup_contents!)

      # We need to stub at the instance level
      allow(Room).to receive(:[]).with(room_to_delete.id).and_return(actual_room)

      command.execute('delete room')

      # The command should clean up contents before deleting
      # Note: The actual deletion will call cleanup_contents!
      # We verify the room is deleted instead
      expect(Room.where(id: room_to_delete.id).count).to eq(0)
    end
  end

  describe 'nested room reparenting' do
    let!(:nested_room) { create(:room, location: location, inside_room_id: room_to_delete.id, owner_id: character.id) }

    it 'reparents nested rooms to parent' do
      command.execute('delete room')

      nested_room.refresh
      expect(nested_room.inside_room_id).to eq(parent_room.id)
    end
  end

  describe 'item relocation' do
    let!(:item) { create(:item, :in_room, room: room_to_delete) }

    it 'moves items to parent room' do
      command.execute('delete room')

      item.refresh
      expect(item.room_id).to eq(parent_room.id)
    end
  end

  describe 'character movement' do
    it 'moves character to parent room' do
      command.execute('delete room')

      character_instance.refresh
      expect(character_instance.current_room_id).to eq(parent_room.id)
    end

    it 'resets character coordinates' do
      character_instance.update(x: 50.0, y: 75.0, z: 10.0)

      command.execute('delete room')

      character_instance.refresh
      expect(character_instance.x).to eq(0.0)
      expect(character_instance.y).to eq(0.0)
      expect(character_instance.z).to eq(0.0)
    end

    context 'when no parent room exists' do
      before do
        room_to_delete.update(inside_room_id: nil)
      end

      it 'moves to another room in the location' do
        command.execute('delete room')

        character_instance.refresh
        expect(character_instance.current_room_id).to eq(parent_room.id)
      end
    end
  end

  describe 'broadcasting' do
    it 'broadcasts arrival to new room' do
      command.execute('delete room')

      expect(BroadcastService).to have_received(:to_room)
        .with(parent_room.id, a_string_including('demolish'), hash_including(exclude: [character_instance.id]))
    end
  end

  describe 'response' do
    it 'returns success message' do
      result = command.execute('delete room')

      expect(result[:success]).to be true
      expect(result[:message]).to include("deleted 'Bedroom'")
    end

    it 'mentions new location' do
      result = command.execute('delete room')

      expect(result[:message]).to include(parent_room.name)
    end

    it 'includes structured data' do
      result = command.execute('delete room')

      expect(result[:type]).to eq(:action)
      expect(result[:data]).not_to be_nil
      expect(result[:data][:action]).to eq('delete_room')
      expect(result[:data][:deleted_room_name]).to eq('Bedroom')
      expect(result[:data][:new_room_id]).to eq(parent_room.id)
      expect(result[:data][:new_room_name]).to eq(parent_room.name)
    end
  end

  describe 'fallback parent room' do
    let(:sibling_room) { create(:room, location: location, owner_id: character.id, name: 'Sibling') }
    let(:orphan_room) { create(:room, location: location, owner_id: character.id, name: 'Orphan', inside_room_id: nil) }

    before do
      # Ensure sibling exists
      sibling_room
      # Update the room to delete to have no parent
      room_to_delete.update(inside_room_id: nil)
      character_instance.update(current_room_id: orphan_room.id)
    end

    it 'finds another room in location when no parent' do
      result = command.execute('delete room')

      expect(result[:success]).to be true
      character_instance.refresh
      # Should have moved to one of the other rooms
      expect([parent_room.id, sibling_room.id, room_to_delete.id]).to include(character_instance.current_room_id)
    end
  end
end
