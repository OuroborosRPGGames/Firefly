# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldJourney, 'globe hex conversion' do
  let(:world) { create(:world) }

  describe 'validations' do
    it 'requires current_globe_hex_id' do
      journey = WorldJourney.new(
        world: world,
        travel_mode: 'land',
        vehicle_type: 'car',
        started_at: Time.now,
        status: 'traveling'
      )
      expect(journey.valid?).to be false
      expect(journey.errors[:current_globe_hex_id]).not_to be_empty
    end
  end

  describe '#current_hex' do
    it 'looks up hex by globe_hex_id' do
      hex = WorldHex.create(world: world, globe_hex_id: 42, terrain_type: 'grassy_plains', latitude: 0, longitude: 0)
      journey = WorldJourney.create(
        world: world,
        current_globe_hex_id: 42,
        travel_mode: 'land',
        vehicle_type: 'car',
        started_at: Time.now,
        status: 'traveling',
        path_remaining: []
      )

      expect(journey.current_hex).to eq(hex)
    end
  end

  describe '#advance_to_next_hex!' do
    it 'updates current_globe_hex_id from path_remaining' do
      WorldHex.create(world: world, globe_hex_id: 1, terrain_type: 'grassy_plains', latitude: 0, longitude: 0)
      WorldHex.create(world: world, globe_hex_id: 2, terrain_type: 'grassy_plains', latitude: 0.5, longitude: 0)
      WorldHex.create(world: world, globe_hex_id: 3, terrain_type: 'grassy_plains', latitude: 1.0, longitude: 0)

      journey = WorldJourney.create(
        world: world,
        current_globe_hex_id: 1,
        path_remaining: [2, 3],
        travel_mode: 'land',
        vehicle_type: 'car',
        started_at: Time.now,
        status: 'traveling'
      )

      journey.advance_to_next_hex!
      journey.reload

      expect(journey.current_globe_hex_id).to eq(2)
      expect(journey.path_remaining).to eq([3])
    end

    it 'returns false when path_remaining is empty' do
      WorldHex.create(world: world, globe_hex_id: 1, terrain_type: 'grassy_plains', latitude: 0, longitude: 0)

      journey = WorldJourney.create(
        world: world,
        current_globe_hex_id: 1,
        path_remaining: [],
        travel_mode: 'land',
        vehicle_type: 'car',
        started_at: Time.now,
        status: 'traveling'
      )

      result = journey.advance_to_next_hex!

      expect(result).to be false
      expect(journey.current_globe_hex_id).to eq(1)
    end

    it 'returns false when path_remaining is nil' do
      WorldHex.create(world: world, globe_hex_id: 1, terrain_type: 'grassy_plains', latitude: 0, longitude: 0)

      journey = WorldJourney.create(
        world: world,
        current_globe_hex_id: 1,
        path_remaining: nil,
        travel_mode: 'land',
        vehicle_type: 'car',
        started_at: Time.now,
        status: 'traveling'
      )

      result = journey.advance_to_next_hex!

      expect(result).to be false
    end

    it 'clears next_hex_at when path is exhausted' do
      WorldHex.create(world: world, globe_hex_id: 1, terrain_type: 'grassy_plains', latitude: 0, longitude: 0)
      WorldHex.create(world: world, globe_hex_id: 2, terrain_type: 'grassy_plains', latitude: 0.5, longitude: 0)

      journey = WorldJourney.create(
        world: world,
        current_globe_hex_id: 1,
        path_remaining: [2],
        travel_mode: 'land',
        vehicle_type: 'car',
        started_at: Time.now,
        status: 'traveling',
        next_hex_at: Time.now + 60
      )

      journey.advance_to_next_hex!
      journey.reload

      expect(journey.current_globe_hex_id).to eq(2)
      expect(journey.path_remaining).to eq([])
      expect(journey.next_hex_at).to be_nil
    end
  end
end
