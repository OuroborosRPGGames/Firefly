# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::BuildLocation, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let!(:zone) { create(:zone, world: world) }
  let!(:location) { create(:location, zone: zone) }
  let!(:room) { create(:room, location: location, name: 'Town Square') }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Builder') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'build location', :building, ['build building', 'create location']

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['build location']).to eq(described_class)
    end
  end

  describe 'permission checks' do
    context 'when character lacks permission' do
      before do
        allow(character).to receive(:staff?).and_return(false)
        allow(character_instance).to receive(:creator_mode?).and_return(false)
      end

      it 'rejects users without permissions' do
        result = command.execute('build location Test Building')

        expect(result[:success]).to be false
        expect(result[:message]).to include('creator mode')
      end
    end

    context 'when character is staff' do
      before do
        allow(character).to receive(:staff?).and_return(true)
        allow(character_instance).to receive(:creator_mode?).and_return(false)
      end

      it 'allows staff members' do
        result = command.execute('build location Test Building')

        expect(result[:success]).to be true
      end
    end

    context 'when in creator mode' do
      before do
        allow(character).to receive(:staff?).and_return(false)
        allow(character_instance).to receive(:creator_mode?).and_return(true)
      end

      it 'allows users in creator mode' do
        result = command.execute('build location Test Building')

        expect(result[:success]).to be true
      end
    end
  end

  describe 'argument validation' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    it 'requires location name' do
      result = command.execute('build location')

      expect(result[:success]).to be false
      expect(result[:message]).to include('What do you want to name')
    end

    it 'validates name length' do
      long_name = 'A' * 101
      result = command.execute("build location #{long_name}")

      expect(result[:success]).to be false
      expect(result[:message]).to include('100 characters')
    end

    it 'strips location/building prefix from name' do
      result = command.execute('build location location Town Hall')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Town Hall')
      expect(result[:message]).not_to include('location Town Hall')
    end
  end

  describe 'zone detection' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    context 'when current room has no zone' do
      before do
        # Stub the location's zone to return nil
        allow_any_instance_of(Location).to receive(:zone).and_return(nil)
      end

      it 'returns error about zone detection' do
        result = command.execute('build location Test')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Cannot determine current zone')
      end
    end
  end

  describe 'duplicate name check' do
    before do
      allow(character).to receive(:staff?).and_return(true)
      create(:location, zone: zone, name: 'Existing Building')
    end

    it 'prevents duplicate location names in same zone' do
      result = command.execute('build location Existing Building')

      expect(result[:success]).to be false
      expect(result[:message]).to include('already exists')
    end

    it 'allows same name in different zones' do
      other_zone = create(:zone, world: world)
      create(:location, zone: other_zone, name: 'Unique Name')

      result = command.execute('build location Unique Name')

      expect(result[:success]).to be true
    end
  end

  describe 'location creation' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    it 'creates new location in current zone' do
      expect { command.execute('build location Town Hall') }
        .to change { Location.where(zone_id: zone.id).count }.by(1)
    end

    it 'sets correct location attributes' do
      command.execute('build location Town Hall')

      new_location = Location.order(:id).last
      expect(new_location.name).to eq('Town Hall')
      expect(new_location.zone_id).to eq(zone.id)
      expect(new_location.location_type).to eq('building')
      expect(new_location.active).to be true
    end
  end

  describe 'entry room creation' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    it 'creates entry room inside new location' do
      expect { command.execute('build location Town Hall') }
        .to change { Room.count }.by(1)
    end

    it 'sets correct room attributes' do
      command.execute('build location Town Hall')

      entry_room = Room.order(:id).last
      expect(entry_room.name).to eq('Entry')
      expect(entry_room.short_description).to include('Town Hall')
      expect(entry_room.room_type).to eq('standard')
      expect(entry_room.owner_id).to eq(character.id)
    end

    it 'sets room dimensions' do
      command.execute('build location Town Hall')

      entry_room = Room.order(:id).last
      expect(entry_room.min_x).to eq(-5.0)
      expect(entry_room.max_x).to eq(5.0)
      expect(entry_room.min_y).to eq(-5.0)
      expect(entry_room.max_y).to eq(5.0)
    end
  end

  describe 'character movement' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    it 'moves character to new entry room' do
      old_room_id = character_instance.current_room_id

      command.execute('build location Town Hall')

      character_instance.refresh
      expect(character_instance.current_room_id).not_to eq(old_room_id)
    end

    it 'resets character coordinates' do
      character_instance.update(x: 50.0, y: 75.0, z: 10.0)

      command.execute('build location Town Hall')

      character_instance.refresh
      expect(character_instance.x).to eq(0.0)
      expect(character_instance.y).to eq(0.0)
      expect(character_instance.z).to eq(0.0)
    end
  end

  describe 'broadcasting' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    it 'broadcasts departure from old room' do
      command.execute('build location Town Hall')

      expect(BroadcastService).to have_received(:to_room)
        .with(room.id, a_string_including('disappears'), hash_including(exclude: [character_instance.id]))
    end
  end

  describe 'response' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    it 'returns success message' do
      result = command.execute('build location Town Hall')

      expect(result[:success]).to be true
      expect(result[:message]).to include("created 'Town Hall'")
    end

    it 'mentions entry room' do
      result = command.execute('build location Town Hall')

      expect(result[:message]).to include('entry room')
    end

    it 'mentions ownership' do
      result = command.execute('build location Town Hall')

      expect(result[:message]).to include('own this building')
    end

    it 'includes structured data' do
      result = command.execute('build location Town Hall')

      expect(result[:type]).to eq(:action)
      expect(result[:data]).not_to be_nil
      expect(result[:data][:action]).to eq('build_location')
      expect(result[:data][:location_name]).to eq('Town Hall')
      expect(result[:data][:room_name]).to eq('Entry')
      expect(result[:data][:owner_id]).to eq(character.id)
    end
  end

  describe 'edge cases' do
    before do
      allow(character).to receive(:staff?).and_return(true)
    end

    it 'handles names with special characters' do
      result = command.execute("build location O'Malley's Pub & Grill")

      expect(result[:success]).to be true
      new_location = Location.order(:id).last
      expect(new_location.name).to eq("O'Malley's Pub & Grill")
    end

    it 'preserves case in name' do
      result = command.execute('build location McDonalds')

      expect(result[:success]).to be true
      new_location = Location.order(:id).last
      expect(new_location.name).to eq('McDonalds')
    end

    it 'trims whitespace from name' do
      result = command.execute('build location   Spacey Name   ')

      expect(result[:success]).to be true
      new_location = Location.order(:id).last
      expect(new_location.name).to eq('Spacey Name')
    end
  end
end
