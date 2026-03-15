# frozen_string_literal: true

require 'spec_helper'

RSpec.describe VehicleInteriorService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:exterior_room) { create(:room, location: location, name: 'Street') }
  let(:interior_room) do
    create(:room,
      location: location,
      name: 'Vehicle Interior',
      is_temporary: true,
      room_type: 'standard'
    )
  end
  let(:character) { create(:character, forename: 'Driver') }
  let(:reality) { create(:reality) }
  let(:character_instance) do
    create(:character_instance,
      character: character,
      reality: reality,
      current_room: exterior_room,
      online: true
    )
  end
  let(:vehicle) do
    create(:vehicle,
      owner: character,
      current_room: exterior_room,
      name: 'Taxi',
      max_passengers: 4,
      condition: 100
    )
  end

  before do
    # Stub TemporaryRoomPoolService for isolation
    allow(TemporaryRoomPoolService).to receive(:acquire_for_vehicle).and_return(
      ResultHandler::Result.new(success: true, message: 'Acquired', data: { room: interior_room })
    )
    allow(TemporaryRoomPoolService).to receive(:schedule_release)
    allow(TemporaryRoomPoolService).to receive(:release_room)
  end

  describe '.enter_vehicle' do
    context 'when vehicle has no interior room' do
      before do
        vehicle.update(interior_room_id: nil)
        allow(TemporaryRoomPoolService).to receive(:acquire_for_vehicle).and_return(
          ResultHandler::Result.new(success: true, message: 'Acquired', data: { room: interior_room })
        )
        # Simulate acquiring room by setting interior_room_id on reload
        allow(vehicle).to receive(:reload).and_wrap_original do |original|
          vehicle.interior_room_id = interior_room.id
          original.call
          vehicle
        end
      end

      it 'acquires a room from the pool' do
        expect(TemporaryRoomPoolService).to receive(:acquire_for_vehicle).with(vehicle)

        described_class.enter_vehicle(character_instance, vehicle)
      end
    end

    context 'when vehicle has an interior room' do
      before do
        vehicle.update(interior_room_id: interior_room.id)
      end

      it 'returns success' do
        result = described_class.enter_vehicle(character_instance, vehicle)

        expect(result.success?).to be true
        expect(result.message).to include('Taxi')
      end

      it 'moves character to interior room' do
        described_class.enter_vehicle(character_instance, vehicle)

        expect(character_instance.reload.current_room_id).to eq(interior_room.id)
      end

      it 'sets current_vehicle_id on character' do
        described_class.enter_vehicle(character_instance, vehicle)

        expect(character_instance.reload.current_vehicle_id).to eq(vehicle.id)
      end

      it 'updates room pool_last_used_at' do
        freeze_time = Time.now
        allow(Time).to receive(:now).and_return(freeze_time)

        described_class.enter_vehicle(character_instance, vehicle)

        expect(interior_room.reload.pool_last_used_at).to be_within(1).of(freeze_time)
      end

      it 'returns room and vehicle in data' do
        result = described_class.enter_vehicle(character_instance, vehicle)

        # Compare by ID since timestamps may differ after update
        expect(result[:room].id).to eq(interior_room.id)
        expect(result[:vehicle].id).to eq(vehicle.id)
      end
    end

    context 'when vehicle is full' do
      before do
        vehicle.update(interior_room_id: interior_room.id)
        allow(vehicle).to receive(:full?).and_return(true)
      end

      it 'returns error' do
        result = described_class.enter_vehicle(character_instance, vehicle)

        expect(result.success?).to be false
        expect(result.message).to include('full')
      end
    end

    context 'when vehicle is not operational' do
      before do
        vehicle.update(interior_room_id: interior_room.id)
        allow(vehicle).to receive(:operational?).and_return(false)
      end

      it 'returns error' do
        result = described_class.enter_vehicle(character_instance, vehicle)

        expect(result.success?).to be false
        expect(result.message).to include('not operational')
      end
    end

    context 'when pool acquisition fails' do
      before do
        vehicle.update(interior_room_id: nil)
        allow(TemporaryRoomPoolService).to receive(:acquire_for_vehicle).and_return(
          ResultHandler::Result.new(success: false, message: 'No pool rooms available')
        )
      end

      it 'returns the pool error' do
        result = described_class.enter_vehicle(character_instance, vehicle)

        expect(result.success?).to be false
        expect(result.message).to include('No pool rooms available')
      end
    end
  end

  describe '.exit_vehicle' do
    before do
      vehicle.update(interior_room_id: interior_room.id)
      character_instance.update(
        current_room_id: interior_room.id,
        current_vehicle_id: vehicle.id
      )
    end

    it 'returns success' do
      result = described_class.exit_vehicle(character_instance)

      expect(result.success?).to be true
      expect(result.message).to include('Taxi')
    end

    it 'moves character to exit room' do
      described_class.exit_vehicle(character_instance)

      expect(character_instance.reload.current_room_id).to eq(exterior_room.id)
    end

    it 'clears current_vehicle_id' do
      described_class.exit_vehicle(character_instance)

      expect(character_instance.reload.current_vehicle_id).to be_nil
    end

    it 'returns room and vehicle in data' do
      result = described_class.exit_vehicle(character_instance)

      # Compare by ID since timestamps may differ after update
      expect(result[:room].id).to eq(exterior_room.id)
      expect(result[:vehicle].id).to eq(vehicle.id)
    end

    it 'schedules interior release when room is temporary and empty' do
      allow(interior_room).to receive(:characters_here).and_return([])

      expect(TemporaryRoomPoolService).to receive(:schedule_release).with(interior_room)

      described_class.exit_vehicle(character_instance)
    end

    context 'when not in a vehicle' do
      before do
        character_instance.update(current_vehicle_id: nil)
      end

      it 'returns error' do
        result = described_class.exit_vehicle(character_instance)

        expect(result.success?).to be false
        expect(result.message).to include("not in a vehicle")
      end
    end

    context 'when exit room cannot be determined' do
      let(:broken_vehicle) do
        v = create(:vehicle, owner: character, current_room: exterior_room, name: 'Broken Car')
        v.update(interior_room_id: interior_room.id)
        v
      end

      before do
        character_instance.update(
          current_room_id: interior_room.id,
          current_vehicle_id: broken_vehicle.id
        )
        allow(broken_vehicle).to receive(:current_room).and_return(nil)
        allow(broken_vehicle).to receive(:room_id).and_return(nil)
        allow(character_instance).to receive(:current_vehicle).and_return(broken_vehicle)
      end

      it 'returns error' do
        result = described_class.exit_vehicle(character_instance)

        expect(result.success?).to be false
        expect(result.message).to include('Cannot determine exit location')
      end
    end
  end

  describe '.save_interior_customizations' do
    before do
      vehicle.update(interior_room_id: interior_room.id)
      interior_room.update(
        short_description: 'A cozy taxi interior',
        long_description: 'Leather seats and a pine air freshener'
      )
    end

    it 'returns success' do
      result = described_class.save_interior_customizations(vehicle)

      expect(result.success?).to be true
    end

    it 'saves room descriptions to vehicle' do
      described_class.save_interior_customizations(vehicle)

      custom_data = vehicle.reload.custom_interior_data
      expect(custom_data['short_description']).to eq('A cozy taxi interior')
      expect(custom_data['long_description']).to eq('Leather seats and a pine air freshener')
    end

    it 'saves decorations if present' do
      decoration = double('Decoration',
        name: 'Fuzzy Dice',
        description: 'Hanging from the mirror',
        display_order: 1
      )
      # Need to stub on the room that vehicle.interior_room returns
      allow(vehicle).to receive(:interior_room).and_return(interior_room)
      allow(interior_room).to receive(:short_description).and_return('A cozy taxi interior')
      allow(interior_room).to receive(:long_description).and_return('Leather seats and a pine air freshener')
      allow(interior_room).to receive(:decorations).and_return([decoration])

      described_class.save_interior_customizations(vehicle)

      custom_data = vehicle.reload.custom_interior_data
      expect(custom_data['decorations']).to be_an(Array)
      expect(custom_data['decorations'].first['name']).to eq('Fuzzy Dice')
    end

    context 'when vehicle has no interior room' do
      before do
        vehicle.update(interior_room_id: nil)
      end

      it 'returns error' do
        result = described_class.save_interior_customizations(vehicle)

        expect(result.success?).to be false
        expect(result.message).to include('no interior room')
      end
    end
  end

  describe '.clear_interior_customizations' do
    before do
      vehicle.update(custom_interior_data: Sequel.pg_jsonb_wrap({
        'short_description' => 'test',
        'decorations' => []
      }))
    end

    it 'returns success' do
      result = described_class.clear_interior_customizations(vehicle)

      expect(result.success?).to be true
    end

    it 'clears custom_interior_data' do
      described_class.clear_interior_customizations(vehicle)

      expect(vehicle.reload.custom_interior_data).to eq({})
    end
  end

  describe '.characters_inside' do
    before do
      vehicle.update(interior_room_id: interior_room.id)
    end

    context 'when vehicle has occupants' do
      let(:occupant) do
        create(:character_instance,
          character: create(:character, forename: 'Passenger'),
          reality: reality,
          current_room: interior_room,
          online: true
        )
      end

      before do
        occupant
        # Mock the characters_here method
        allow(interior_room).to receive(:characters_here).and_return([occupant])
      end

      it 'returns the characters inside' do
        result = described_class.characters_inside(vehicle)

        expect(result).to include(occupant)
      end
    end

    context 'when vehicle is empty' do
      before do
        allow(interior_room).to receive(:characters_here).and_return([])
      end

      it 'returns empty array' do
        result = described_class.characters_inside(vehicle)

        expect(result).to be_empty
      end
    end

    context 'when vehicle has no interior room' do
      before do
        vehicle.update(interior_room_id: nil)
      end

      it 'returns empty array' do
        result = described_class.characters_inside(vehicle)

        expect(result).to be_empty
      end
    end
  end

  describe '.interior_empty?' do
    before do
      vehicle.update(interior_room_id: interior_room.id)
    end

    context 'when no one is inside' do
      before do
        allow(interior_room).to receive(:characters_here).and_return([])
      end

      it 'returns true' do
        expect(described_class.interior_empty?(vehicle)).to be true
      end
    end

    context 'when someone is inside' do
      before do
        # Stub vehicle.interior_room to return our stubbed room
        allow(vehicle).to receive(:interior_room).and_return(interior_room)
        allow(interior_room).to receive(:characters_here).and_return([character_instance])
      end

      it 'returns false' do
        expect(described_class.interior_empty?(vehicle)).to be false
      end
    end

    context 'when vehicle has no interior room' do
      before do
        vehicle.update(interior_room_id: nil)
      end

      it 'returns true' do
        expect(described_class.interior_empty?(vehicle)).to be true
      end
    end
  end

  describe '.release_interior' do
    before do
      vehicle.update(interior_room_id: interior_room.id)
    end

    context 'when interior is empty' do
      before do
        allow(interior_room).to receive(:characters_here).and_return([])
      end

      it 'returns success' do
        result = described_class.release_interior(vehicle)

        expect(result.success?).to be true
      end

      it 'clears interior_room_id' do
        described_class.release_interior(vehicle)

        expect(vehicle.reload.interior_room_id).to be_nil
      end

      it 'releases room to pool' do
        expect(TemporaryRoomPoolService).to receive(:release_room).with(interior_room)

        described_class.release_interior(vehicle)
      end
    end

    context 'when interior has occupants and force_eject is false' do
      before do
        # Stub vehicle.interior_room to return our stubbed room
        allow(vehicle).to receive(:interior_room).and_return(interior_room)
        allow(interior_room).to receive(:characters_here).and_return([character_instance])
      end

      it 'returns error' do
        result = described_class.release_interior(vehicle)

        expect(result.success?).to be false
        expect(result.message).to include('still has occupants')
      end
    end

    context 'when interior has occupants and force_eject is true' do
      before do
        character_instance.update(
          current_room_id: interior_room.id,
          current_vehicle_id: vehicle.id
        )
        allow(interior_room).to receive(:characters_here).and_return([character_instance])
      end

      it 'returns success' do
        result = described_class.release_interior(vehicle, force_eject: true)

        expect(result.success?).to be true
      end

      it 'moves occupants to exit room' do
        described_class.release_interior(vehicle, force_eject: true)

        expect(character_instance.reload.current_room_id).to eq(exterior_room.id)
        expect(character_instance.current_vehicle_id).to be_nil
      end
    end

    context 'when vehicle has no interior' do
      before do
        vehicle.update(interior_room_id: nil)
      end

      it 'returns success' do
        result = described_class.release_interior(vehicle)

        expect(result.success?).to be true
        expect(result.message).to include('No interior to release')
      end
    end
  end

  describe 'private methods' do
    describe '#vehicle_name' do
      it 'returns vehicle name if present' do
        allow(vehicle).to receive(:name).and_return('My Car')
        result = described_class.send(:vehicle_name, vehicle)

        expect(result).to eq('My Car')
      end

      it 'returns default if name is empty' do
        allow(vehicle).to receive(:name).and_return('')
        result = described_class.send(:vehicle_name, vehicle)

        expect(result).to eq('vehicle')
      end

      it 'returns default if name is nil' do
        allow(vehicle).to receive(:name).and_return(nil)
        result = described_class.send(:vehicle_name, vehicle)

        expect(result).to eq('vehicle')
      end

      it 'returns default if name is only whitespace' do
        allow(vehicle).to receive(:name).and_return('   ')
        result = described_class.send(:vehicle_name, vehicle)

        expect(result).to eq('vehicle')
      end
    end
  end
end
