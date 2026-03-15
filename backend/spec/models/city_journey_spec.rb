# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CityJourney do
  let(:room) { create(:room) }
  let(:destination) { create(:room) }
  let(:character_instance) { create(:character_instance, current_room: room) }
  let(:vehicle) { create(:vehicle) }

  describe 'validations' do
    it 'requires a driver' do
      journey = CityJourney.new(destination_room_id: destination.id)
      expect(journey.valid?).to be false
      expect(journey.errors[:driver_id]).not_to be_empty
    end

    it 'requires a destination' do
      journey = CityJourney.new(driver_id: character_instance.id)
      expect(journey.valid?).to be false
      expect(journey.errors[:destination_room_id]).not_to be_empty
    end
  end

  describe '#traveling?' do
    it 'returns true when status is traveling' do
      journey = CityJourney.create(
        driver_id: character_instance.id,
        destination_room_id: destination.id,
        status: 'traveling'
      )
      expect(journey.traveling?).to be true
    end
  end

  describe '#taxi?' do
    it 'returns true when no vehicle' do
      journey = CityJourney.create(
        driver_id: character_instance.id,
        destination_room_id: destination.id
      )
      expect(journey.taxi?).to be true
    end

    it 'returns false when vehicle present' do
      journey = CityJourney.create(
        driver_id: character_instance.id,
        destination_room_id: destination.id,
        vehicle_id: vehicle.id
      )
      expect(journey.taxi?).to be false
    end
  end
end
