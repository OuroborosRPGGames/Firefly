# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Vehicle do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:character) { create(:character) }
  let(:vehicle) { create(:vehicle, owner: character, current_room: room) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(vehicle).to be_valid
    end

    it 'requires name' do
      vehicle = build(:vehicle, owner: character, current_room: room, name: nil)
      expect(vehicle).not_to be_valid
    end

    it 'validates max length of name' do
      vehicle = build(:vehicle, owner: character, current_room: room, name: 'x' * 101)
      expect(vehicle).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to owner' do
      expect(vehicle.owner).to eq(character)
    end

    it 'belongs to current_room' do
      expect(vehicle.current_room).to eq(room)
    end
  end

  describe 'alias accessors' do
    it 'aliases owner_id to char_id' do
      expect(vehicle.owner_id).to eq(vehicle.char_id)
    end

    it 'aliases current_room_id to room_id' do
      expect(vehicle.current_room_id).to eq(vehicle.room_id)
    end

    it 'aliases roof_open to opentop' do
      expect(vehicle.roof_open).to eq(vehicle.opentop)
    end
  end

  describe '#parked?' do
    it 'returns true when parked' do
      expect(vehicle.parked?).to be true
    end

    it 'returns false when moving' do
      vehicle = create(:vehicle, :moving, owner: character, current_room: room)
      expect(vehicle.parked?).to be false
    end
  end

  describe '#moving?' do
    it 'returns false when parked' do
      expect(vehicle.moving?).to be false
    end

    it 'returns true when not parked' do
      vehicle = create(:vehicle, :moving, owner: character, current_room: room)
      expect(vehicle.moving?).to be true
    end
  end

  describe '#damaged?' do
    it 'returns true when condition is below 50' do
      vehicle = create(:vehicle, :damaged, owner: character, current_room: room)
      expect(vehicle.damaged?).to be true
    end

    it 'returns false when condition is 50 or above' do
      expect(vehicle.damaged?).to be false
    end
  end

  describe '#operational?' do
    it 'returns true when condition is above 0' do
      expect(vehicle.operational?).to be true
    end

    it 'returns false when condition is 0' do
      vehicle.update(condition: 0)
      expect(vehicle.operational?).to be false
    end
  end

  describe '#available_seats' do
    it 'returns max_passengers for empty vehicle' do
      expect(vehicle.available_seats).to eq(4)
    end
  end

  describe '#full?' do
    it 'returns false when seats are available' do
      expect(vehicle.full?).to be false
    end
  end

  describe '#convertible?' do
    it 'returns true for convertible vehicles' do
      vehicle = create(:vehicle, :convertible, owner: character, current_room: room)
      expect(vehicle.convertible?).to be true
    end

    it 'returns false for non-convertible vehicles' do
      expect(vehicle.convertible?).to be false
    end
  end

  describe '#roof_open?' do
    it 'returns true when roof is open' do
      vehicle = create(:vehicle, :roof_open, owner: character, current_room: room)
      expect(vehicle.roof_open?).to be true
    end

    it 'returns false when roof is closed' do
      expect(vehicle.roof_open?).to be false
    end
  end

  describe '#roof_closed?' do
    it 'returns false when roof is open' do
      vehicle = create(:vehicle, :roof_open, owner: character, current_room: room)
      expect(vehicle.roof_closed?).to be false
    end

    it 'returns true when roof is closed' do
      expect(vehicle.roof_closed?).to be true
    end
  end

  describe '#open_roof!' do
    it 'opens roof for convertible' do
      vehicle = create(:vehicle, :convertible, owner: character, current_room: room)
      expect(vehicle.open_roof!).to be true
      expect(vehicle.reload.opentop).to be true
    end

    it 'returns false for non-convertible' do
      expect(vehicle.open_roof!).to be false
    end

    it 'returns false if already open' do
      vehicle = create(:vehicle, :roof_open, owner: character, current_room: room)
      expect(vehicle.open_roof!).to be false
    end
  end

  describe '#close_roof!' do
    it 'closes roof for convertible' do
      vehicle = create(:vehicle, :roof_open, owner: character, current_room: room)
      expect(vehicle.close_roof!).to be true
      expect(vehicle.reload.opentop).to be false
    end

    it 'returns false for non-convertible' do
      expect(vehicle.close_roof!).to be false
    end

    it 'returns false if already closed' do
      vehicle = create(:vehicle, :convertible, owner: character, current_room: room)
      expect(vehicle.close_roof!).to be false
    end
  end

  describe '#occupants' do
    it 'returns empty array for empty vehicle' do
      expect(vehicle.occupants).to eq([])
    end
  end

  describe '.for_owner' do
    let!(:my_vehicle) { create(:vehicle, owner: character, current_room: room) }
    let(:other_owner) { create(:character) }
    let!(:other_vehicle) { create(:vehicle, owner: other_owner, current_room: room) }

    it 'returns vehicles for the owner' do
      results = described_class.for_owner(character).all
      expect(results).to include(my_vehicle)
      expect(results).not_to include(other_vehicle)
    end
  end

  describe '.in_room' do
    let!(:my_vehicle) { vehicle }
    let(:other_room) { create(:room, location: location) }
    let!(:other_vehicle) { create(:vehicle, owner: character, current_room: other_room) }

    it 'returns vehicles in the specified room' do
      results = described_class.in_room(room).all
      expect(results).to include(my_vehicle)
      expect(results).not_to include(other_vehicle)
    end
  end

  describe '#occupants_visible?' do
    context 'with always_open vehicle type' do
      let(:motorcycle_type) { VehicleType.create(name: 'Motorcycle', category: 'ground', always_open: true) }

      it 'returns true regardless of roof state' do
        test_vehicle = Vehicle.create(name: 'Red Bike', char_id: character.id, vtype: motorcycle_type.name)
        expect(test_vehicle.occupants_visible?).to be true
      end
    end

    context 'with convertible vehicle' do
      it 'returns true when roof is open' do
        test_vehicle = create(:vehicle, :roof_open, owner: character, current_room: room)
        expect(test_vehicle.occupants_visible?).to be true
      end

      it 'returns false when roof is closed' do
        test_vehicle = create(:vehicle, :convertible, owner: character, current_room: room)
        expect(test_vehicle.occupants_visible?).to be false
      end
    end

    context 'with standard enclosed vehicle' do
      it 'returns false' do
        test_vehicle = create(:vehicle, owner: character, current_room: room, convertible: false)
        expect(test_vehicle.occupants_visible?).to be false
      end
    end
  end
end
