# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Globe Hex Integration', type: :integration do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:zone, world: world) }

  describe 'complete globe hex workflow' do
    context 'world generation' do
      it 'generates hexes with globe_hex_id, latitude, and longitude' do
        # Create a GlobeHexGrid with minimal subdivisions for fast test
        grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 1)

        # Should generate 80 hexes (20 * 4^1)
        expect(grid.hex_count).to eq(80)

        # Convert to db records and verify structure
        records = grid.to_db_records

        records.each do |record|
          # Each record must have globe_hex_id
          expect(record).to have_key(:globe_hex_id)
          expect(record[:globe_hex_id]).to be_an(Integer)
          expect(record[:globe_hex_id]).to be >= 0

          # Each record must have latitude/longitude
          expect(record).to have_key(:latitude)
          expect(record).to have_key(:longitude)

          # Latitude must be within valid range (-90 to 90)
          expect(record[:latitude]).to be >= -90
          expect(record[:latitude]).to be <= 90

          # Longitude must be within valid range (-180 to 180)
          expect(record[:longitude]).to be >= -180
          expect(record[:longitude]).to be <= 180

          # Terrain type should have a default
          expect(record[:terrain_type]).to be_a(String)
          expect(record[:terrain_type]).not_to be_empty
        end
      end

      it 'generates unique globe_hex_ids within the world' do
        grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 1)
        records = grid.to_db_records

        globe_hex_ids = records.map { |r| r[:globe_hex_id] }

        # All IDs should be unique
        expect(globe_hex_ids.uniq.count).to eq(globe_hex_ids.count)
      end

      it 'can persist generated hexes to database' do
        grid = WorldGeneration::GlobeHexGrid.new(world, subdivisions: 0)

        # Should generate 20 hexes (icosahedron faces)
        expect(grid.hex_count).to eq(20)

        records = grid.to_db_records

        # Insert all records
        WorldHex.multi_insert(records)

        # Verify they were saved
        saved_hexes = WorldHex.where(world_id: world.id).all
        expect(saved_hexes.count).to eq(20)

        # Each saved hex should have valid globe coordinates
        saved_hexes.each do |hex|
          expect(hex.globe_hex_id).not_to be_nil
          expect(hex.latitude).not_to be_nil
          expect(hex.longitude).not_to be_nil
          expect(hex.globe_hex?).to be true
        end
      end
    end

    context 'location creation' do
      let!(:hex1) do
        WorldHex.create(
          world: world,
          globe_hex_id: 1000,
          terrain_type: 'urban',
          latitude: 40.7128,
          longitude: -74.0060
        )
      end

      it 'creates locations with globe_hex_id' do
        location = create(:location, zone: zone, world: world, globe_hex_id: 1000)

        expect(location.globe_hex_id).to eq(1000)
        expect(location.has_globe_hex?).to be true
      end

      it 'looks up world_hex via globe_hex_id' do
        location = create(:location, zone: zone, world: world, globe_hex_id: 1000)

        # Location.world_hex should return the associated WorldHex
        retrieved_hex = location.world_hex

        expect(retrieved_hex).not_to be_nil
        expect(retrieved_hex.id).to eq(hex1.id)
        expect(retrieved_hex.globe_hex_id).to eq(1000)
        expect(retrieved_hex.latitude).to be_within(0.01).of(40.7128)
        expect(retrieved_hex.longitude).to be_within(0.01).of(-74.0060)
      end

      it 'returns nil for world_hex when globe_hex_id is not set' do
        location = create(:location, zone: zone, world: world, globe_hex_id: nil)

        expect(location.has_globe_hex?).to be false
        expect(location.world_hex).to be_nil
      end

      it 'returns nil for world_hex when hex does not exist' do
        location = create(:location, zone: zone, world: world, globe_hex_id: 99999)

        expect(location.has_globe_hex?).to be true
        expect(location.world_hex).to be_nil
      end
    end

    context 'pathfinding' do
      before do
        # Create a line of adjacent hexes using lat/lon coordinates
        # Hexes are neighbors if within NEIGHBOR_THRESHOLD_DEGREES (1.0 degree)
        @hex_a = WorldHex.create(
          world: world,
          globe_hex_id: 100,
          terrain_type: 'urban',
          latitude: 0.0,
          longitude: 0.0
        )

        @hex_b = WorldHex.create(
          world: world,
          globe_hex_id: 101,
          terrain_type: 'grassy_plains',
          latitude: 0.8,
          longitude: 0.0
        )

        @hex_c = WorldHex.create(
          world: world,
          globe_hex_id: 102,
          terrain_type: 'urban',
          latitude: 1.6,
          longitude: 0.0
        )
      end

      it 'finds paths between globe hexes using great circle distance' do
        path = GlobePathfindingService.find_path(
          world: world,
          start_globe_hex_id: 100,
          end_globe_hex_id: 102
        )

        # Path should be an array of globe_hex_ids (integers)
        expect(path).to be_an(Array)
        expect(path).not_to be_empty

        # First element is start
        expect(path.first).to eq(100)

        # Last element is destination
        expect(path.last).to eq(102)

        # All elements should be integers (globe_hex_ids)
        path.each do |hex_id|
          expect(hex_id).to be_an(Integer)
        end
      end

      it 'returns array with single element when start equals destination' do
        path = GlobePathfindingService.find_path(
          world: world,
          start_globe_hex_id: 100,
          end_globe_hex_id: 100
        )

        expect(path).to eq([100])
      end

      it 'returns empty array when no path exists' do
        # Create an isolated hex far away
        WorldHex.create(
          world: world,
          globe_hex_id: 999,
          terrain_type: 'grassy_plains',
          latitude: 80.0,  # Very far from other hexes
          longitude: 80.0
        )

        path = GlobePathfindingService.find_path(
          world: world,
          start_globe_hex_id: 100,
          end_globe_hex_id: 999
        )

        expect(path).to eq([])
      end

      it 'calculates great circle distance between hexes' do
        distance = GlobePathfindingService.distance(@hex_a, @hex_c)

        # Distance should be a positive float (in radians)
        expect(distance).to be > 0
        expect(distance).to be_a(Float)
        expect(distance).to be < Float::INFINITY
      end
    end

    context 'travel' do
      let(:origin) { create(:location, zone: zone, world: world, globe_hex_id: 200) }
      let(:destination) { create(:location, zone: zone, world: world, globe_hex_id: 202) }
      let(:origin_room) { create(:room, location: origin) }
      let(:character) { create(:character) }
      let(:character_instance) { create(:character_instance, character: character, current_room: origin_room) }

      before do
        # Create adjacent hexes for travel route (0.8 degree spacing)
        WorldHex.create(
          world: world,
          globe_hex_id: 200,
          terrain_type: 'urban',
          latitude: 0.0,
          longitude: 0.0
        )

        WorldHex.create(
          world: world,
          globe_hex_id: 201,
          terrain_type: 'grassy_plains',
          latitude: 0.8,
          longitude: 0.0
        )

        WorldHex.create(
          world: world,
          globe_hex_id: 202,
          terrain_type: 'urban',
          latitude: 1.6,
          longitude: 0.0
        )
      end

      it 'creates journeys with globe_hex_ids' do
        result = WorldTravelService.start_journey(
          character_instance,
          destination: destination,
          travel_mode: 'land'
        )

        expect(result[:success]).to be true
        journey = result[:journey]

        # current_globe_hex_id should be an integer
        expect(journey.current_globe_hex_id).to be_an(Integer)
        expect(journey.current_globe_hex_id).to eq(200)

        # path_remaining should be array-like (JSONB array) of integers
        expect(journey.path_remaining).to respond_to(:each)
        expect(journey.path_remaining).not_to be_empty
        journey.path_remaining.each do |hex_id|
          expect(hex_id).to be_an(Integer)
        end
      end

      it 'advances journeys through globe_hex_id path' do
        result = WorldTravelService.start_journey(
          character_instance,
          destination: destination,
          travel_mode: 'land'
        )

        expect(result[:success]).to be true
        journey = result[:journey]

        initial_hex = journey.current_globe_hex_id
        initial_path_length = journey.path_remaining.length

        # Skip if path is empty (already at destination)
        if journey.path_remaining.any?
          # Advance to next hex
          journey.advance_to_next_hex!

          # Current hex should be updated to next in path
          expect(journey.current_globe_hex_id).not_to eq(initial_hex)
          expect(journey.current_globe_hex_id).to be_an(Integer)

          # Path remaining should be shorter
          expect(journey.path_remaining.length).to eq(initial_path_length - 1)
        end
      end

      it 'journey status uses globe_hex_id for current position' do
        result = WorldTravelService.start_journey(
          character_instance,
          destination: destination,
          travel_mode: 'land'
        )

        journey = result[:journey]
        status = WorldTravelService.journey_status(journey)

        expect(status[:current_globe_hex_id]).to be_an(Integer)
        expect(status[:current_globe_hex_id]).to eq(journey.current_globe_hex_id)
      end
    end

    context 'WorldHex model' do
      it 'validates presence of globe_hex_id' do
        hex = WorldHex.new(world: world, terrain_type: 'grassy_plains')
        expect(hex.valid?).to be false
        expect(hex.errors[:globe_hex_id]).not_to be_nil
      end

      it 'validates uniqueness of globe_hex_id within world' do
        WorldHex.create(
          world: world,
          globe_hex_id: 500,
          terrain_type: 'grassy_plains',
          latitude: 0.0,
          longitude: 0.0
        )

        duplicate = WorldHex.new(
          world: world,
          globe_hex_id: 500,
          terrain_type: 'grassy_plains',
          latitude: 1.0,
          longitude: 1.0
        )

        expect(duplicate.valid?).to be false
      end

      it 'allows same globe_hex_id in different worlds' do
        other_world = create(:world, universe: universe)

        WorldHex.create(
          world: world,
          globe_hex_id: 600,
          terrain_type: 'grassy_plains',
          latitude: 0.0,
          longitude: 0.0
        )

        other_hex = WorldHex.new(
          world: other_world,
          globe_hex_id: 600,
          terrain_type: 'grassy_plains',
          latitude: 0.0,
          longitude: 0.0
        )

        expect(other_hex.valid?).to be true
      end

      it 'can find hex by globe_hex_id' do
        created_hex = WorldHex.create(
          world: world,
          globe_hex_id: 700,
          terrain_type: 'mountain',
          latitude: 45.0,
          longitude: 90.0
        )

        found = WorldHex.find_by_globe_hex(world.id, 700)

        expect(found).not_to be_nil
        expect(found.id).to eq(created_hex.id)
        expect(found.terrain_type).to eq('mountain')
      end

      it 'can find nearest hex by latitude/longitude' do
        WorldHex.create(
          world: world,
          globe_hex_id: 801,
          terrain_type: 'grassy_plains',
          latitude: 10.0,
          longitude: 10.0
        )

        WorldHex.create(
          world: world,
          globe_hex_id: 802,
          terrain_type: 'dense_forest',
          latitude: 20.0,
          longitude: 20.0
        )

        # Find nearest to (11, 11) - should be hex 801
        nearest = WorldHex.find_nearest_by_latlon(world.id, 11.0, 11.0)

        expect(nearest).not_to be_nil
        expect(nearest.globe_hex_id).to eq(801)
      end

      it 'finds neighbors using great circle distance' do
        center_hex = WorldHex.create(
          world: world,
          globe_hex_id: 900,
          terrain_type: 'grassy_plains',
          latitude: 0.0,
          longitude: 0.0
        )

        # Create nearby hex (within threshold)
        nearby_hex = WorldHex.create(
          world: world,
          globe_hex_id: 901,
          terrain_type: 'grassy_plains',
          latitude: 0.5,
          longitude: 0.0
        )

        # Create distant hex (outside threshold)
        WorldHex.create(
          world: world,
          globe_hex_id: 902,
          terrain_type: 'grassy_plains',
          latitude: 45.0,
          longitude: 45.0
        )

        neighbors = WorldHex.neighbors_of(center_hex)

        # Should include nearby hex
        expect(neighbors.map(&:globe_hex_id)).to include(901)

        # Should not include distant hex
        expect(neighbors.map(&:globe_hex_id)).not_to include(902)
      end
    end
  end
end
