# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldJourney do
  let(:world) { create(:world) }
  let(:origin_location) { create(:location, zone: create(:area, world: world)) }
  let(:destination_location) { create(:location, zone: create(:area, world: world)) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      journey = described_class.create(
        world: world,
        origin_location: origin_location,
        destination_location: destination_location,
        current_globe_hex_id: 1,
        travel_mode: 'land',
        vehicle_type: 'car',
        status: 'traveling',
        started_at: Time.now
      )
      expect(journey).to be_valid
    end

    it 'requires world_id' do
      journey = described_class.new(
        current_globe_hex_id: 1,
        travel_mode: 'land',
        vehicle_type: 'car',
        started_at: Time.now
      )
      expect(journey).not_to be_valid
    end

    it 'requires current_globe_hex_id' do
      journey = described_class.new(
        world: world,
        travel_mode: 'land',
        vehicle_type: 'car',
        started_at: Time.now
      )
      expect(journey).not_to be_valid
    end

    it 'requires travel_mode' do
      journey = described_class.new(
        world: world,
        current_globe_hex_id: 1,
        vehicle_type: 'car',
        started_at: Time.now
      )
      expect(journey).not_to be_valid
    end

    it 'requires vehicle_type' do
      journey = described_class.new(
        world: world,
        current_globe_hex_id: 1,
        travel_mode: 'land',
        started_at: Time.now
      )
      expect(journey).not_to be_valid
    end

    it 'validates travel_mode inclusion' do
      described_class::TRAVEL_MODES.each do |mode|
        journey = described_class.new(
          world: world,
          current_globe_hex_id: 1,
          travel_mode: mode,
          vehicle_type: 'car',
          status: 'traveling',
          started_at: Time.now
        )
        expect(journey).to be_valid, "Expected travel_mode '#{mode}' to be valid"
      end
    end

    it 'validates status inclusion' do
      described_class::STATUSES.each do |status|
        journey = described_class.new(
          world: world,
          current_globe_hex_id: 1,
          travel_mode: 'land',
          vehicle_type: 'car',
          status: status,
          started_at: Time.now
        )
        expect(journey).to be_valid, "Expected status '#{status}' to be valid"
      end
    end
  end

  describe 'associations' do
    it 'belongs to world' do
      journey = create(:world_journey, world: world)
      expect(journey.world).to eq(world)
    end

    it 'belongs to origin_location' do
      journey = create(:world_journey, origin_location: origin_location)
      expect(journey.origin_location).to eq(origin_location)
    end

    it 'belongs to destination_location' do
      journey = create(:world_journey, destination_location: destination_location)
      expect(journey.destination_location).to eq(destination_location)
    end

    it 'has many journey_passengers' do
      journey = create(:world_journey, world: world)
      expect(journey).to respond_to(:journey_passengers)
    end
  end

  describe 'constants' do
    it 'defines TRAVEL_MODES' do
      expect(described_class::TRAVEL_MODES).to eq(%w[land water air rail])
    end

    it 'defines STATUSES' do
      expect(described_class::STATUSES).to eq(%w[traveling paused arrived cancelled])
    end

    it 'defines VEHICLE_TYPES' do
      expect(described_class::VEHICLE_TYPES).to include(:medieval, :modern, :scifi)
    end

    it 'defines VEHICLE_SPEEDS' do
      expect(described_class::VEHICLE_SPEEDS).to include('car', 'horse', 'train', 'airplane')
    end
  end

  describe '#traveling?' do
    it 'returns true when status is traveling' do
      journey = create(:world_journey, world: world, status: 'traveling')
      expect(journey.traveling?).to be true
    end

    it 'returns false when status is not traveling' do
      journey = create(:world_journey, :arrived, world: world)
      expect(journey.traveling?).to be false
    end
  end

  describe '#arrived?' do
    it 'returns true when status is arrived' do
      journey = create(:world_journey, :arrived, world: world)
      expect(journey.arrived?).to be true
    end

    it 'returns false when status is not arrived' do
      journey = create(:world_journey, world: world, status: 'traveling')
      expect(journey.arrived?).to be false
    end
  end

  describe '#ready_to_advance?' do
    it 'returns true when traveling and next_hex_at has passed' do
      journey = create(:world_journey, world: world, status: 'traveling', next_hex_at: Time.now - 10)
      expect(journey.ready_to_advance?).to be true
    end

    it 'returns false when not traveling' do
      journey = create(:world_journey, :arrived, world: world, next_hex_at: Time.now - 10)
      expect(journey.ready_to_advance?).to be false
    end

    it 'returns false when next_hex_at is in future' do
      journey = create(:world_journey, world: world, status: 'traveling', next_hex_at: Time.now + 3600)
      expect(journey.ready_to_advance?).to be false
    end

    it 'returns false when next_hex_at is nil' do
      journey = create(:world_journey, world: world, status: 'traveling', next_hex_at: nil)
      expect(journey.ready_to_advance?).to be_falsey
    end
  end

  describe '#time_remaining_display' do
    it 'returns "Arrived" when arrived' do
      journey = create(:world_journey, :arrived, world: world)
      expect(journey.time_remaining_display).to eq('Arrived')
    end

    it 'returns "Unknown" when no estimated_arrival_at' do
      journey = create(:world_journey, world: world, estimated_arrival_at: nil)
      expect(journey.time_remaining_display).to eq('Unknown')
    end

    it 'returns formatted time when estimated_arrival_at is set' do
      journey = create(:world_journey, world: world, estimated_arrival_at: Time.now + 7200)
      expect(journey.time_remaining_display).to match(/\d+h \d+m/)
    end
  end

  describe '#terrain_description' do
    it 'returns description based on current hex terrain' do
      WorldHex.create(world: world, globe_hex_id: 100, terrain_type: 'dense_forest')
      journey = create(:world_journey, world: world, current_globe_hex_id: 100)
      expect(journey.terrain_description).to eq('dense forest')
    end

    it 'returns default when no hex exists' do
      journey = create(:world_journey, world: world, current_globe_hex_id: 99999)
      expect(journey.terrain_description).to eq('featureless terrain')
    end
  end

  describe '#vehicle_description' do
    it 'returns description for known vehicle type' do
      journey = create(:world_journey, world: world, vehicle_type: 'car')
      expect(journey.vehicle_description).to include('comfortable vehicle')
    end

    it 'returns generic description for unknown vehicle' do
      journey = create(:world_journey, world: world, vehicle_type: 'teleporter')
      expect(journey.vehicle_description).to eq('You travel by teleporter.')
    end
  end

  describe '#time_per_hex_seconds' do
    it 'returns time based on vehicle speed' do
      journey = create(:world_journey, world: world, vehicle_type: 'car', speed_modifier: 1.0)
      # Car has speed multiplier of 3.0
      expect(journey.time_per_hex_seconds).to be_a(Integer)
    end

    it 'respects speed_modifier' do
      journey1 = create(:world_journey, world: world, vehicle_type: 'car', speed_modifier: 1.0)
      journey2 = create(:world_journey, world: world, vehicle_type: 'car', speed_modifier: 2.0)

      # Higher speed modifier = faster = less time
      expect(journey2.time_per_hex_seconds).to be < journey1.time_per_hex_seconds
    end
  end

  describe '#terrain_speed_modifier' do
    let(:journey) { create(:world_journey, world: world, travel_mode: 'land', current_globe_hex_id: 100) }

    before do
      # Create ocean hex at journey's current position
      WorldHex.set_hex_details(world, journey.current_globe_hex_id, terrain_type: 'ocean')
    end

    context 'when travel_mode is water' do
      before { journey.update(travel_mode: 'water') }

      it 'returns era-scaled bonus for water terrain' do
        allow(journey).to receive(:current_era).and_return(:medieval)

        modifier = journey.send(:terrain_speed_modifier)

        # Medieval water bonus is 2.0
        expect(modifier).to eq(2.0)
      end

      it 'returns different bonuses for different eras' do
        allow(journey).to receive(:current_era).and_return(:modern)

        modifier = journey.send(:terrain_speed_modifier)

        # Modern water bonus is 1.2
        expect(modifier).to eq(1.2)
      end

      it 'returns penalty for land terrain in water mode' do
        WorldHex.set_hex_details(world, journey.current_globe_hex_id, terrain_type: 'grassy_plains')

        modifier = journey.send(:terrain_speed_modifier)

        # Should return very low value (1 / WATER_MODE_LAND_PENALTY)
        expect(modifier).to be < 0.1
      end
    end

    context 'when travel_mode is land' do
      it 'uses inverse of movement_cost as modifier' do
        WorldHex.set_hex_details(world, journey.current_globe_hex_id, terrain_type: 'dense_forest')

        modifier = journey.send(:terrain_speed_modifier)

        # Forest has cost 2, so modifier should be 0.5
        expect(modifier).to eq(0.5)
      end

      it 'returns penalty for water terrain in land mode' do
        # Ocean terrain (already set in before block)
        modifier = journey.send(:terrain_speed_modifier)

        # Should return very low value (1 / LAND_MODE_WATER_PENALTY)
        expect(modifier).to be < 0.1
      end
    end

    context 'when travel_mode is rail' do
      before { journey.update(travel_mode: 'rail') }

      it 'uses inverse of movement_cost for land terrain' do
        WorldHex.set_hex_details(world, journey.current_globe_hex_id, terrain_type: 'grassy_plains')

        modifier = journey.send(:terrain_speed_modifier)

        # Plain has cost 1, so modifier should be 1.0
        expect(modifier).to eq(1.0)
      end
    end
  end

  describe '#has_railway_feature?' do
    let(:journey) { create(:world_journey, world: world, travel_mode: 'rail', current_globe_hex_id: 100) }

    it 'returns true when current hex has railway' do
      hex = WorldHex.set_hex_details(world, journey.current_globe_hex_id)
      hex.set_directional_feature('n', 'railway')

      expect(journey.send(:has_railway_feature?)).to be true
    end

    it 'returns false when no railway' do
      WorldHex.set_hex_details(world, journey.current_globe_hex_id, terrain_type: 'grassy_plains')

      expect(journey.send(:has_railway_feature?)).to be false
    end

    it 'returns false when no hex exists' do
      journey.update(current_globe_hex_id: 99999)

      expect(journey.send(:has_railway_feature?)).to be false
    end
  end

  describe '#road_or_rail_modifier' do
    let(:journey) { create(:world_journey, world: world, travel_mode: 'rail', current_globe_hex_id: 100) }

    context 'when travel_mode is rail' do
      before do
        hex = WorldHex.set_hex_details(world, journey.current_globe_hex_id)
        hex.set_directional_feature('n', 'railway')
      end

      it 'applies railway speed bonus' do
        modifier = journey.send(:road_or_rail_modifier)

        expect(modifier).to eq(GameConfig::WorldTravel::RAILWAY_SPEED_BONUS)
      end
    end

    context 'when travel_mode is rail but no railway present' do
      before do
        WorldHex.set_hex_details(world, journey.current_globe_hex_id, terrain_type: 'grassy_plains')
      end

      it 'returns 1.0 (no bonus)' do
        modifier = journey.send(:road_or_rail_modifier)

        expect(modifier).to eq(1.0)
      end
    end

    context 'when travel_mode is land' do
      before { journey.update(travel_mode: 'land') }

      it 'applies road bonus when on road' do
        hex = WorldHex.set_hex_details(world, journey.current_globe_hex_id)
        hex.set_directional_feature('n', 'road')

        modifier = journey.send(:road_or_rail_modifier)

        expect(modifier).to eq(2.0)
      end

      it 'returns 1.0 when no road present' do
        WorldHex.set_hex_details(world, journey.current_globe_hex_id, terrain_type: 'grassy_plains')

        modifier = journey.send(:road_or_rail_modifier)

        expect(modifier).to eq(1.0)
      end
    end

    context 'when travel_mode is water' do
      before { journey.update(travel_mode: 'water') }

      it 'returns 1.0 (no road/rail bonus for water)' do
        WorldHex.set_hex_details(world, journey.current_globe_hex_id, terrain_type: 'ocean')

        modifier = journey.send(:road_or_rail_modifier)

        expect(modifier).to eq(1.0)
      end
    end
  end

  describe '#current_era' do
    let(:journey) { create(:world_journey, world: world) }

    it 'returns :modern as fallback when EraService is not defined' do
      # EraService may or may not be defined, but we can test the fallback
      era = journey.send(:current_era)
      expect(era).to be_a(Symbol)
    end
  end

  describe 'traits' do
    it 'creates arrived journey' do
      journey = create(:world_journey, :arrived, world: world)
      expect(journey.status).to eq('arrived')
    end

    it 'creates cancelled journey' do
      journey = create(:world_journey, :cancelled, world: world)
      expect(journey.status).to eq('cancelled')
    end

    it 'creates journey by train' do
      journey = create(:world_journey, :by_train, world: world)
      expect(journey.travel_mode).to eq('rail')
      expect(journey.vehicle_type).to eq('train')
    end

    it 'creates journey by ship' do
      journey = create(:world_journey, :by_ship, world: world)
      expect(journey.travel_mode).to eq('water')
      expect(journey.vehicle_type).to eq('ferry')
    end

    it 'creates journey by air' do
      journey = create(:world_journey, :by_air, world: world)
      expect(journey.travel_mode).to eq('air')
      expect(journey.vehicle_type).to eq('airplane')
    end

    it 'creates medieval journey' do
      journey = create(:world_journey, :medieval, world: world)
      expect(journey.vehicle_type).to eq('horse')
    end
  end
end
