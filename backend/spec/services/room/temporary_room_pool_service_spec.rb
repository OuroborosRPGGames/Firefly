# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TemporaryRoomPoolService do
  let(:location) { create(:location) }
  let(:room_template) do
    RoomTemplate.create(
      name: 'Taxi Interior',
      short_description: 'Inside a taxi',
      long_description: 'The leather seats are worn but clean.',
      category: 'taxi',
      template_type: 'taxi',
      room_type: 'vehicle'
    )
  end

  describe 'constants' do
    it 'has RELEASE_DELAY_SECONDS' do
      expect(described_class::RELEASE_DELAY_SECONDS).to eq(300)
    end

    it 'has POOL_SIZES' do
      expect(described_class::POOL_SIZES).to include('sedan', 'taxi', 'bus')
    end

    it 'has DEFAULT_POOL_SIZE' do
      expect(described_class::DEFAULT_POOL_SIZE).to eq(3)
    end
  end

  describe '.acquire_for_vehicle' do
    let(:real_vehicle) { create(:vehicle, current_room: create(:room, location: location)) }
    let(:vehicle) do
      double(
        'Vehicle',
        id: real_vehicle.id,
        vehicle_type: 'taxi',
        vtype: nil,
        preferred_template: nil,
        custom_interior_data: nil
      )
    end
    let!(:available_pool_room) do
      create(:room,
        location: location,
        is_temporary: true,
        pool_status: 'available',
        room_template_id: room_template.id
      )
    end

    before do
      allow(vehicle).to receive(:update)
      allow(RoomTemplate).to receive(:for_vehicle_type).with('taxi').and_return(room_template)
    end

    context 'when template is found' do
      it 'returns a success result' do
        result = described_class.acquire_for_vehicle(vehicle)

        expect(result.success?).to be true
        expect(result.message).to eq('Interior room acquired')
      end

      it 'returns room in data' do
        result = described_class.acquire_for_vehicle(vehicle)

        expect(result[:room]).to be_a(Room)
      end

      it 'updates vehicle with interior room id' do
        expect(vehicle).to receive(:update) do |args|
          expect(args[:interior_room_id]).to be_a(Integer)
        end

        described_class.acquire_for_vehicle(vehicle)
      end
    end

    context 'when template not found' do
      before do
        allow(RoomTemplate).to receive(:for_vehicle_type).and_return(nil)
      end

      it 'returns an error' do
        result = described_class.acquire_for_vehicle(vehicle)

        expect(result.failure?).to be true
        expect(result.message).to include('No template found')
      end
    end

    context 'with vehicle preferred template' do
      let(:preferred_template) { room_template }

      before do
        allow(vehicle).to receive(:respond_to?).with(:preferred_template).and_return(true)
        allow(vehicle).to receive(:preferred_template).and_return(preferred_template)
        # The available_pool_room created in outer context will be used (room_template_id matches)
      end

      it 'uses the preferred template' do
        expect(RoomTemplate).not_to receive(:for_vehicle_type)

        described_class.acquire_for_vehicle(vehicle)
      end
    end

    context 'with custom interior data' do
      before do
        allow(vehicle).to receive(:custom_interior_data).and_return({
          'short_description' => 'Custom taxi interior',
          'long_description' => 'Plush velvet seats.',
          'decorations' => [{ 'name' => 'Air freshener', 'description' => 'Pine scent' }]
        })
      end

      it 'applies custom descriptions' do
        described_class.acquire_for_vehicle(vehicle)

        available_pool_room.reload
        expect(available_pool_room.short_description).to eq('Custom taxi interior')
        expect(available_pool_room.long_description).to eq('Plush velvet seats.')
      end

      it 'creates custom decorations' do
        expect {
          described_class.acquire_for_vehicle(vehicle)
        }.to change { Decoration.count }.by(1)
      end
    end
  end

  describe '.acquire_for_journey' do
    let(:real_journey) { create(:world_journey) }
    let(:journey) do
      double(
        'WorldJourney',
        id: real_journey.id,
        travel_mode: 'road',
        vehicle_type: 'bus'
      )
    end
    let(:destination) { double('Location', name: 'Central Station') }
    let!(:available_pool_room) do
      create(:room,
        location: location,
        is_temporary: true,
        pool_status: 'available',
        room_template_id: room_template.id
      )
    end

    before do
      allow(journey).to receive(:update)
      allow(journey).to receive(:respond_to?).with(:destination_location).and_return(true)
      allow(journey).to receive(:destination_location).and_return(destination)
      allow(journey).to receive(:respond_to?).with(:terrain_description).and_return(false)
      allow(journey).to receive(:respond_to?).with(:vehicle_description).and_return(false)
      allow(RoomTemplate).to receive(:for_journey).and_return(room_template)
    end

    context 'when template is found' do
      it 'returns a success result' do
        result = described_class.acquire_for_journey(journey)

        expect(result.success?).to be true
        expect(result.message).to eq('Journey compartment acquired')
      end

      it 'updates journey with interior room id' do
        expect(journey).to receive(:update) do |args|
          expect(args[:interior_room_id]).to be_a(Integer)
        end

        described_class.acquire_for_journey(journey)
      end

      it 'customizes room description with destination' do
        result = described_class.acquire_for_journey(journey)
        room = result[:room]

        expect(room.short_description).to eq('Traveling to Central Station')
      end
    end

    context 'when template not found' do
      before do
        allow(RoomTemplate).to receive(:for_journey).and_return(nil)
      end

      it 'returns an error' do
        result = described_class.acquire_for_journey(journey)

        expect(result.failure?).to be true
        expect(result.message).to include('No template found')
      end
    end
  end

  describe '.release_room' do
    let(:temp_room) do
      create(:room,
        location: location,
        is_temporary: true,
        pool_status: 'in_use',
        room_template_id: room_template.id
      )
    end

    context 'with valid empty temporary room' do
      before do
        # Ensure no characters in the room
        CharacterInstance.where(current_room_id: temp_room.id).delete
      end

      it 'returns success' do
        result = described_class.release_room(temp_room)

        expect(result.success?).to be true
        expect(result.message).to eq('Room released to pool')
      end

      it 'sets pool_status to available' do
        described_class.release_room(temp_room)

        expect(temp_room.reload.pool_status).to eq('available')
      end

      it 'clears temporary associations' do
        vehicle = create(:vehicle, current_room: temp_room)
        temp_room.update(temp_vehicle_id: vehicle.id, pool_acquired_at: Time.now)
        described_class.release_room(temp_room)

        temp_room.reload
        expect(temp_room.temp_vehicle_id).to be_nil
        expect(temp_room.pool_acquired_at).to be_nil
      end
    end

    context 'when room is not temporary' do
      let(:regular_room) { create(:room, location: location, is_temporary: false) }

      it 'returns error' do
        result = described_class.release_room(regular_room)

        expect(result.failure?).to be true
        expect(result.message).to eq('Room is not temporary')
      end
    end

    context 'when room is not in use' do
      before do
        temp_room.update(pool_status: 'available')
      end

      it 'returns error' do
        result = described_class.release_room(temp_room)

        expect(result.failure?).to be true
        expect(result.message).to eq('Room is not in use')
      end
    end

    context 'when room has occupants' do
      before do
        create(:character_instance, current_room: temp_room)
      end

      it 'returns error' do
        result = described_class.release_room(temp_room)

        expect(result.failure?).to be true
        expect(result.message).to eq('Room still has occupants')
      end
    end
  end

  describe '.schedule_release' do
    let(:temp_room) do
      create(:room,
        location: location,
        is_temporary: true,
        pool_status: 'in_use'
      )
    end

    it 'sets pool_release_after' do
      described_class.schedule_release(temp_room)

      expect(temp_room.reload.pool_release_after).to be_within(5).of(Time.now + 300)
    end

    it 'sets pool_last_used_at' do
      described_class.schedule_release(temp_room)

      expect(temp_room.reload.pool_last_used_at).to be_within(2).of(Time.now)
    end

    it 'does nothing for nil room' do
      expect { described_class.schedule_release(nil) }.not_to raise_error
    end

    it 'does nothing for non-temporary room' do
      regular_room = create(:room, location: location, is_temporary: false)

      expect { described_class.schedule_release(regular_room) }.not_to raise_error
      expect(regular_room.reload.pool_release_after).to be_nil
    end

    it 'does nothing for available room' do
      temp_room.update(pool_status: 'available')

      described_class.schedule_release(temp_room)

      expect(temp_room.reload.pool_release_after).to be_nil
    end
  end

  describe '.check_and_release_empty_rooms' do
    let!(:empty_ready_room) do
      create(:room,
        location: location,
        is_temporary: true,
        pool_status: 'in_use',
        pool_release_after: Time.now - 60,
        room_template_id: room_template.id
      )
    end

    let!(:occupied_room) do
      room = create(:room,
        location: location,
        is_temporary: true,
        pool_status: 'in_use',
        pool_release_after: Time.now - 60,
        room_template_id: room_template.id
      )
      # Add a character to make it occupied
      create(:character_instance, current_room: room)
      room
    end

    let!(:not_yet_ready_room) do
      create(:room,
        location: location,
        is_temporary: true,
        pool_status: 'in_use',
        pool_release_after: Time.now + 300,
        room_template_id: room_template.id
      )
    end

    it 'returns count of released rooms' do
      count = described_class.check_and_release_empty_rooms

      expect(count).to be >= 0
    end

    it 'releases empty rooms past their release time' do
      described_class.check_and_release_empty_rooms

      # Empty room past release time should be available now
      expect(empty_ready_room.reload.pool_status).to eq('available')
    end

    it 'extends release time for occupied rooms' do
      old_release = occupied_room.pool_release_after

      described_class.check_and_release_empty_rooms

      # Occupied room should have extended release time
      expect(occupied_room.reload.pool_release_after).to be > old_release
    end

    it 'does not touch rooms not yet due for release' do
      described_class.check_and_release_empty_rooms

      expect(not_yet_ready_room.reload.pool_status).to eq('in_use')
    end
  end

  describe '.ensure_pool_size' do
    let(:pool_location) do
      Location.find_or_create(name: 'Room Pool') do |l|
        l.zone_id = location.zone_id
        l.location_type = 'building'
      end
    end

    before do
      allow(room_template).to receive(:instantiate_room) do |args|
        create(:room, location: args[:location], is_temporary: true, pool_status: 'available', room_template_id: room_template.id)
      end
      allow(room_template).to receive(:setup_default_places)
      allow(room_template).to receive(:universe).and_return(nil)
    end

    it 'creates rooms up to pool size' do
      rooms_created = described_class.ensure_pool_size(pool_location, room_template, count: 3)

      expect(rooms_created).to eq(3)
    end

    it 'uses POOL_SIZES for template category' do
      rooms_created = described_class.ensure_pool_size(pool_location, room_template)

      # 'taxi' category has pool size of 10
      expect(rooms_created).to eq(10)
    end

    it 'does not create rooms if pool is already full' do
      # Create existing rooms
      3.times do
        create(:room,
          location: pool_location,
          room_template_id: room_template.id,
          is_temporary: true,
          pool_status: 'available'
        )
      end

      rooms_created = described_class.ensure_pool_size(pool_location, room_template, count: 3)

      expect(rooms_created).to eq(0)
    end
  end

  describe '.pool_stats' do
    before do
      # Create some temporary rooms
      create(:room, location: location, is_temporary: true, pool_status: 'available')
      create(:room, location: location, is_temporary: true, pool_status: 'available')
      create(:room, location: location, is_temporary: true, pool_status: 'in_use')
      create(:room, location: location, is_temporary: false)
    end

    it 'returns hash with stats' do
      stats = described_class.pool_stats

      expect(stats).to be_a(Hash)
      expect(stats).to have_key(:total_temporary)
      expect(stats).to have_key(:available)
      expect(stats).to have_key(:in_use)
      expect(stats).to have_key(:by_template)
    end

    it 'counts temporary rooms correctly' do
      stats = described_class.pool_stats

      expect(stats[:total_temporary]).to eq(3)
      expect(stats[:available]).to eq(2)
      expect(stats[:in_use]).to eq(1)
    end
  end

  describe 'private methods' do
    describe '.resolve_template_for_vehicle' do
      let(:vehicle) do
        double('Vehicle',
          vehicle_type: 'sedan',
          vtype: nil
        )
      end

      before do
        allow(vehicle).to receive(:respond_to?).with(:preferred_template).and_return(false)
      end

      it 'calls RoomTemplate.for_vehicle_type' do
        expect(RoomTemplate).to receive(:for_vehicle_type).with('sedan')

        described_class.send(:resolve_template_for_vehicle, vehicle)
      end

      it 'falls back to vtype if vehicle_type is nil' do
        allow(vehicle).to receive(:vehicle_type).and_return(nil)
        allow(vehicle).to receive(:vtype).and_return('suv')

        expect(RoomTemplate).to receive(:for_vehicle_type).with('suv')

        described_class.send(:resolve_template_for_vehicle, vehicle)
      end

      it 'uses preferred_template if available' do
        preferred = double('RoomTemplate')
        allow(vehicle).to receive(:respond_to?).with(:preferred_template).and_return(true)
        allow(vehicle).to receive(:preferred_template).and_return(preferred)

        result = described_class.send(:resolve_template_for_vehicle, vehicle)

        expect(result).to eq(preferred)
      end
    end

    describe '.resolve_template_for_journey' do
      let(:journey) do
        double('WorldJourney',
          travel_mode: 'rail',
          vehicle_type: 'train'
        )
      end

      it 'calls RoomTemplate.for_journey with correct args' do
        expect(RoomTemplate).to receive(:for_journey).with(
          travel_mode: 'rail',
          vehicle_type: 'train'
        )

        described_class.send(:resolve_template_for_journey, journey)
      end
    end

    describe '.apply_vehicle_customizations' do
      let(:room) { create(:room, location: location) }
      let(:vehicle) { double('Vehicle') }

      context 'with valid custom data' do
        let(:custom_data) do
          {
            'short_description' => 'Custom short',
            'long_description' => 'Custom long',
            'decorations' => [
              { 'name' => 'Fuzzy dice', 'description' => 'Hanging from mirror' }
            ]
          }
        end

        it 'updates room descriptions' do
          described_class.send(:apply_vehicle_customizations, room, double(custom_interior_data: custom_data))

          room.reload
          expect(room.short_description).to eq('Custom short')
          expect(room.long_description).to eq('Custom long')
          expect(room.has_custom_interior).to be true
        end

        it 'creates decorations' do
          expect {
            described_class.send(:apply_vehicle_customizations, room, double(custom_interior_data: custom_data))
          }.to change { Decoration.count }.by(1)

          decoration = Decoration.last
          expect(decoration.name).to eq('Fuzzy dice')
        end
      end

      context 'with invalid custom data' do
        it 'handles nil custom data' do
          expect {
            described_class.send(:apply_vehicle_customizations, room, double(custom_interior_data: nil))
          }.not_to raise_error
        end

        it 'handles empty hash' do
          expect {
            described_class.send(:apply_vehicle_customizations, room, double(custom_interior_data: {}))
          }.not_to raise_error
        end

        it 'handles invalid decoration data' do
          custom_data = { 'decorations' => ['not a hash'] }

          expect {
            described_class.send(:apply_vehicle_customizations, room, double(custom_interior_data: custom_data))
          }.not_to raise_error
        end
      end
    end

    describe '.customize_journey_room' do
      let(:room) { create(:room, location: location) }
      let(:destination) { double('Location', name: 'Port City') }
      let(:journey) do
        double('WorldJourney',
          vehicle_type: 'ship'
        )
      end

      before do
        allow(journey).to receive(:respond_to?).with(:destination_location).and_return(true)
        allow(journey).to receive(:destination_location).and_return(destination)
        allow(journey).to receive(:respond_to?).with(:terrain_description).and_return(false)
        allow(journey).to receive(:respond_to?).with(:vehicle_description).and_return(false)
      end

      it 'updates short description with destination' do
        described_class.send(:customize_journey_room, room, journey)

        expect(room.reload.short_description).to eq('Traveling to Port City')
      end

      it 'includes vehicle type in long description' do
        described_class.send(:customize_journey_room, room, journey)

        expect(room.reload.long_description).to include('ship')
      end

      context 'with terrain and vehicle descriptions' do
        before do
          allow(journey).to receive(:respond_to?).with(:terrain_description).and_return(true)
          allow(journey).to receive(:terrain_description).and_return('rolling hills')
          allow(journey).to receive(:respond_to?).with(:vehicle_description).and_return(true)
          allow(journey).to receive(:vehicle_description).and_return('A grand steamship')
        end

        it 'uses custom descriptions' do
          described_class.send(:customize_journey_room, room, journey)

          room.reload
          expect(room.long_description).to include('grand steamship')
          expect(room.long_description).to include('rolling hills')
        end
      end
    end

    describe '.resolve_pool_location' do
      context 'when pool location exists' do
        let!(:pool_location) { Location.create(name: 'Room Pool', zone_id: location.zone_id, location_type: 'building') }

        it 'returns existing location' do
          result = described_class.send(:resolve_pool_location, room_template)

          expect(result.name).to eq('Room Pool')
        end
      end

      context 'when pool location does not exist' do
        before do
          Location.where(name: 'Room Pool').delete
          # Template needs universe set up for pool creation to work
          allow(room_template).to receive(:universe).and_return(location.zone.world.universe)
        end

        it 'creates a new pool location' do
          expect {
            described_class.send(:resolve_pool_location, room_template)
          }.to change { Location.where(name: 'Room Pool').count }.by(1)
        end
      end
    end
  end
end
