# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Navigation::EnterGame do
  let(:location) { create(:location) }
  let(:exit_hall) do
    create(:room, location: location, name: 'Exit Hall', room_type: 'standard')
  end
  let(:regular_room) do
    create(:room, location: location, name: 'Regular Room', room_type: 'standard')
  end

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Test', surname: 'Player') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           current_room: exit_hall,
           online: true,
           x: 50, y: 50, z: 0)
  end

  subject(:command) { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_room)
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_character_raw)
    allow(CityMapRenderService).to receive(:render).and_return({ svg: '<svg></svg>', metadata: {} })
  end

  def execute_command(args = nil)
    input = args.nil? ? 'enter game' : "enter game #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('enter game')
    end

    it 'has aliases' do
      alias_names = described_class.aliases.map { |a| a.is_a?(Hash) ? a[:name] : a }
      expect(alias_names).to include('entergame', 'enter world', 'start game', 'begin')
    end

    it 'has navigation category' do
      expect(described_class.category).to eq(:navigation)
    end

    it 'has help text' do
      expect(described_class.help_text).to include('tutorial')
    end
  end

  describe 'not in Exit Hall' do
    let(:character_instance) do
      create(:character_instance,
             character: character,
             current_room: regular_room,
             online: true)
    end

    it 'returns error when not in Exit Hall' do
      result = execute_command
      expect(result[:success]).to be false
      expect(result[:message]).to include('Exit Hall')
    end
  end

  describe 'in Exit Hall' do
    context 'when New Haven village exists with rooms' do
      let!(:new_haven_location) { create(:location, name: 'New Haven', city_name: 'New Haven') }
      let!(:new_haven_intersection) do
        create(:room,
               location: new_haven_location,
               name: 'Main Street & Oak Avenue',
               room_type: 'intersection',
               publicity: nil)
      end

      it 'teleports player to New Haven intersection' do
        result = execute_command
        expect(result[:success]).to be true
        expect(character_instance.reload.current_room_id).to eq(new_haven_intersection.id)
      end

      it 'sets player position to room center' do
        execute_command
        ci = character_instance.reload
        # teleport_to_room! calculates center of destination room
        expected_x = ((new_haven_intersection.min_x || 0.0) + (new_haven_intersection.max_x || 100.0)) / 2.0
        expected_y = ((new_haven_intersection.min_y || 0.0) + (new_haven_intersection.max_y || 100.0)) / 2.0
        expected_z = new_haven_intersection.min_z || 0.0
        expect(ci.x).to eq(expected_x)
        expect(ci.y).to eq(expected_y)
        expect(ci.z).to eq(expected_z)
      end

      it 'includes New Haven in message' do
        result = execute_command
        expect(result[:message]).to include('New Haven')
      end

      it 'returns action type with room data' do
        result = execute_command
        expect(result[:type]).to eq(:action)
        expect(result[:data][:action]).to eq('enter_game')
        expect(result[:data][:to_room_id]).to eq(new_haven_intersection.id)
      end

      it 'prefers New Haven over other villages' do
        other_location = create(:location, name: 'Other Village', city_name: 'Other Village')
        create(:room,
               location: other_location,
               name: 'Village Entrance',
               room_type: 'intersection',
               publicity: nil)
        result = execute_command
        expect(character_instance.reload.current_room_id).to eq(new_haven_intersection.id)
      end
    end

    context 'when New Haven has non-intersection rooms only' do
      let!(:new_haven_location) { create(:location, name: 'New Haven', city_name: 'New Haven') }
      let!(:new_haven_street) do
        create(:room,
               location: new_haven_location,
               name: 'Main Street (block 1)',
               room_type: 'street',
               publicity: nil)
      end

      it 'teleports player to any New Haven room' do
        result = execute_command
        expect(result[:success]).to be true
        expect(character_instance.reload.current_room_id).to eq(new_haven_street.id)
      end
    end

    context 'when Village Entrance exists (no New Haven)' do
      let!(:village_location) { create(:location, name: 'Test Village', city_name: 'Greendale') }
      let!(:village_entrance) do
        create(:room,
               location: village_location,
               name: 'Village Entrance',
               room_type: 'intersection',
               publicity: nil)
      end

      it 'teleports player to Village Entrance' do
        result = execute_command
        expect(result[:success]).to be true
        expect(character_instance.reload.current_room_id).to eq(village_entrance.id)
      end

      it 'includes village name in message' do
        result = execute_command
        expect(result[:message]).to include('Greendale')
      end
    end

    context 'when only public intersection exists' do
      let!(:intersection) do
        create(:room,
               location: location,
               name: 'Main Street & Oak Avenue',
               room_type: 'intersection',
               publicity: nil)
      end

      it 'teleports player to the intersection' do
        result = execute_command
        expect(result[:success]).to be true
        expect(character_instance.reload.current_room_id).to eq(intersection.id)
      end
    end

    context 'when only a public room exists' do
      let!(:public_room) do
        create(:room,
               location: location,
               name: 'Town Square',
               room_type: 'standard',
               publicity: nil)
      end

      it 'teleports player to any public room' do
        result = execute_command
        expect(result[:success]).to be true
        expect(character_instance.reload.current_room_id).to eq(public_room.id)
      end
    end

    context 'when no destination exists' do
      before do
        # Make Exit Hall the only room and mark all others private
        Room.exclude(id: exit_hall.id).update(publicity: 'private')
      end

      it 'returns error about world not being ready' do
        # Delete all rooms except Exit Hall to simulate no valid destinations
        Room.exclude(name: 'Exit Hall').delete
        result = execute_command
        expect(result[:success]).to be false
        expect(result[:message]).to include("ready yet")
      end
    end

    context 'when admin configured spawn_room_id' do
      let(:spawn_location) { create(:location, name: 'Admin City', city_name: 'Admin City') }
      let!(:spawn_room) do
        create(:room, location: spawn_location, name: 'Admin Spawn', room_type: 'standard', publicity: nil)
      end
      let!(:new_haven_location) { create(:location, name: 'New Haven', city_name: 'New Haven') }
      let!(:new_haven_room) do
        create(:room, location: new_haven_location, name: 'NH Intersection', room_type: 'intersection', publicity: nil)
      end

      before do
        GameSetting.set('spawn_room_id', spawn_room.id, type: 'integer')
      end

      after do
        setting = GameSetting.first(key: 'spawn_room_id')
        setting&.destroy
      end

      it 'uses the configured room over New Haven' do
        result = execute_command
        expect(result[:success]).to be true
        expect(character_instance.reload.current_room_id).to eq(spawn_room.id)
      end
    end

    context 'when admin configured spawn_location_id (no room)' do
      let(:spawn_location) { create(:location, name: 'Custom City', city_name: 'Custom City') }
      let!(:spawn_intersection) do
        create(:room, location: spawn_location, name: 'Custom Crossroads', room_type: 'intersection', publicity: nil)
      end
      let!(:spawn_street) do
        create(:room, location: spawn_location, name: 'Custom Street', room_type: 'street', publicity: nil)
      end

      before do
        GameSetting.set('spawn_location_id', spawn_location.id, type: 'integer')
      end

      after do
        setting = GameSetting.first(key: 'spawn_location_id')
        setting&.destroy
      end

      it 'selects the best room in that location (intersection preferred)' do
        result = execute_command
        expect(result[:success]).to be true
        expect(character_instance.reload.current_room_id).to eq(spawn_intersection.id)
      end
    end

    context 'when neither spawn setting is configured' do
      let!(:new_haven_location) { create(:location, name: 'New Haven', city_name: 'New Haven') }
      let!(:new_haven_room) do
        create(:room, location: new_haven_location, name: 'NH Intersection', room_type: 'intersection', publicity: nil)
      end

      it 'falls back to New Haven' do
        result = execute_command
        expect(result[:success]).to be true
        expect(character_instance.reload.current_room_id).to eq(new_haven_room.id)
      end
    end

    context 'welcome message' do
      let!(:destination) do
        create(:room,
               location: location,
               name: 'Town Square',
               room_type: 'standard',
               publicity: nil)
      end

      it 'includes portal flavor text' do
        result = execute_command
        expect(result[:message]).to include('portal')
      end

      it 'suggests using look command' do
        result = execute_command
        expect(result[:message]).to include('look')
      end
    end
  end
end
