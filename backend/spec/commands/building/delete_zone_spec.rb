# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Building::DeleteZone, type: :command do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }

  # Zone to delete (with its hierarchy) - use let! to ensure creation
  let!(:zone_to_delete) { create(:zone, world: world, name: 'Old Slums') }
  let!(:location_in_zone) { create(:location, zone: zone_to_delete) }
  let!(:room_in_zone) { create(:room, location: location_in_zone, name: 'Slum Room') }

  # Current zone (where the character is)
  let(:current_zone) { create(:zone, world: world, name: 'Safe Zone') }
  let(:current_location) { create(:location, zone: current_zone) }
  let(:current_room) { create(:room, location: current_location, name: 'Safe Room') }

  # Spawn room (outside the zone to delete)
  let!(:spawn_room) do
    room = create(:room, location: current_location, name: 'Spawn')
    GameSetting.set('tutorial_spawn_room_id', room.id, type: 'integer')
    room
  end

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Admin') }
  let(:reality) { create(:reality) }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: current_room,
           online: true)
  end

  subject(:command) { described_class.new(character_instance) }

  before do
    allow(BroadcastService).to receive(:to_character)
    allow(BroadcastService).to receive(:to_room)
  end

  # Use shared example for command metadata
  it_behaves_like "command metadata", 'delete zone', :building, ['remove zone', 'delete area', 'remove area']

  describe 'command registration' do
    it 'is registered in the command registry' do
      expect(Commands::Base::Registry.commands['delete zone']).to eq(described_class)
    end

    it 'has DeleteArea as a backward compatibility alias' do
      expect(Commands::Building::DeleteArea).to eq(Commands::Building::DeleteZone)
    end
  end

  describe 'permission checks' do
    context 'when character is not admin' do
      before do
        allow(character).to receive(:admin?).and_return(false)
      end

      it 'rejects non-admin users' do
        result = command.execute('delete zone Old Slums')

        expect(result[:success]).to be false
        expect(result[:message]).to include('administrators')
      end
    end

    context 'when character is admin' do
      before do
        allow(character).to receive(:admin?).and_return(true)
      end

      it 'allows admin users' do
        result = command.execute('delete zone Old Slums')
        # Should not fail on permission check (may fail for other reasons)
        expect(result[:message]).not_to include('administrators')
      end
    end
  end

  describe 'argument validation' do
    before do
      allow(character).to receive(:admin?).and_return(true)
    end

    it 'requires zone name' do
      result = command.execute('delete zone')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Which zone')
    end

    it 'returns error for non-existent zone' do
      result = command.execute('delete zone Nonexistent Zone')

      expect(result[:success]).to be false
      expect(result[:message]).to include('No zone found')
    end

    it 'strips zone/area prefix from name' do
      result = command.execute('delete zone zone Old Slums')
      # Should look for 'Old Slums', not 'zone Old Slums'
      expect(result[:success]).to be true
    end
  end

  describe 'safety checks' do
    before do
      allow(character).to receive(:admin?).and_return(true)
    end

    it 'prevents deleting current zone' do
      # Move character to the zone we're trying to delete
      character_instance.update(current_room_id: room_in_zone.id)

      result = command.execute('delete zone Old Slums')

      expect(result[:success]).to be false
      expect(result[:message]).to include('cannot delete the zone you are currently in')
    end

    it 'uses fallback room when no spawn room but other rooms exist' do
      spawn_room.delete

      result = command.execute('delete zone Old Slums')

      # Should succeed using current_room as fallback
      expect(result[:success]).to be true
    end
  end

  describe 'cascading deletion' do
    let!(:decoration) { create(:decoration, room: room_in_zone) }
    let!(:place) { create(:place, room: room_in_zone) }
    let!(:shop) { create(:shop, room: room_in_zone) }
    let!(:shop_item) { create(:shop_item, shop: shop) }
    # NOTE: RoomExit model was removed - navigation now uses spatial adjacency

    before do
      allow(character).to receive(:admin?).and_return(true)
    end

    it 'deletes decorations in zone rooms' do
      expect { command.execute('delete zone Old Slums') }
        .to change { Decoration.where(id: decoration.id).count }.from(1).to(0)
    end

    it 'deletes places in zone rooms' do
      expect { command.execute('delete zone Old Slums') }
        .to change { Place.where(id: place.id).count }.from(1).to(0)
    end

    it 'deletes shops in zone rooms' do
      expect { command.execute('delete zone Old Slums') }
        .to change { Shop.where(id: shop.id).count }.from(1).to(0)
    end

    it 'deletes shop items' do
      expect { command.execute('delete zone Old Slums') }
        .to change { ShopItem.where(id: shop_item.id).count }.from(1).to(0)
    end

    # NOTE: Room exit deletion test removed - RoomExit model no longer exists
    # Navigation now uses spatial adjacency via RoomAdjacencyService

    it 'deletes all rooms in zone' do
      expect { command.execute('delete zone Old Slums') }
        .to change { Room.where(id: room_in_zone.id).count }.from(1).to(0)
    end

    it 'deletes all locations in zone' do
      expect { command.execute('delete zone Old Slums') }
        .to change { Location.where(id: location_in_zone.id).count }.from(1).to(0)
    end

    it 'deletes the zone itself' do
      expect { command.execute('delete zone Old Slums') }
        .to change { Zone.where(id: zone_to_delete.id).count }.from(1).to(0)
    end
  end

  describe 'character relocation' do
    let!(:character_in_zone) do
      create(:character_instance,
             character: create(:character, user: create(:user)),
             reality: reality,
             current_room: room_in_zone,
             online: true)
    end

    let!(:offline_character_in_zone) do
      create(:character_instance,
             character: create(:character, user: create(:user)),
             reality: reality,
             current_room: room_in_zone,
             online: false)
    end

    before do
      allow(character).to receive(:admin?).and_return(true)
    end

    it 'moves characters to spawn room' do
      command.execute('delete zone Old Slums')

      character_in_zone.refresh
      expect(character_in_zone.current_room_id).to eq(spawn_room.id)
    end

    it 'resets character coordinates' do
      character_in_zone.update(x: 50.0, y: 75.0, z: 10.0)

      command.execute('delete zone Old Slums')

      character_in_zone.refresh
      expect(character_in_zone.x).to eq(0.0)
      expect(character_in_zone.y).to eq(0.0)
      expect(character_in_zone.z).to eq(0.0)
    end

    it 'notifies online characters' do
      command.execute('delete zone Old Slums')

      expect(BroadcastService).to have_received(:to_character)
        .with(character_in_zone.id, anything, type: :message)
    end

    it 'does not notify offline characters' do
      command.execute('delete zone Old Slums')

      expect(BroadcastService).not_to have_received(:to_character)
        .with(offline_character_in_zone.id, anything, hash_including(type: :message))
    end
  end

  describe 'response' do
    before do
      allow(character).to receive(:admin?).and_return(true)
    end

    it 'returns success with counts' do
      result = command.execute('delete zone Old Slums')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Deleted zone')
      expect(result[:message]).to include('Old Slums')
      expect(result[:message]).to include('locations')
      expect(result[:message]).to include('rooms')
    end

    it 'includes structured data' do
      result = command.execute('delete zone Old Slums')

      expect(result[:data]).not_to be_nil
      expect(result[:data][:action]).to eq('delete_zone')
      expect(result[:data][:zone_name]).to eq('Old Slums')
      expect(result[:data][:locations_deleted]).to be >= 0
      expect(result[:data][:rooms_deleted]).to be >= 0
      expect(result[:data][:characters_relocated]).to be >= 0
    end
  end

  describe 'multiple locations and rooms' do
    let!(:location2) { create(:location, zone: zone_to_delete) }
    let!(:room2) { create(:room, location: location2) }
    let!(:room3) { create(:room, location: location_in_zone) }

    before do
      allow(character).to receive(:admin?).and_return(true)
    end

    it 'deletes all locations in the zone' do
      result = command.execute('delete zone Old Slums')

      expect(result[:data][:locations_deleted]).to eq(2)
    end

    it 'deletes all rooms in the zone' do
      result = command.execute('delete zone Old Slums')

      # room_in_zone + room2 + room3 = 3 rooms
      expect(result[:data][:rooms_deleted]).to eq(3)
    end
  end
end
