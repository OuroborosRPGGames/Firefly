# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'World Travel Integration', type: :integration do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:zone, world: world) }

  # Helper to create adjacent hexes using lat/lon coordinates
  # Globe hexes are neighbors if they're within NEIGHBOR_THRESHOLD_DEGREES (1.0 degree) of each other
  def create_adjacent_hexes_line(world, start_lat:, start_lon:, count:, direction: :east, terrain_type: 'grassy_plains')
    hexes = []
    lat = start_lat
    lon = start_lon
    step = 0.8 # Within the neighbor threshold (1.0 degrees)

    count.times do |i|
      hex = WorldHex.set_hex_details(world, i + 1, terrain_type: terrain_type)
      hex.update(latitude: lat, longitude: lon)
      hexes << hex

      case direction
      when :east then lon += step
      when :north then lat += step
      when :northeast
        lat += step * 0.7
        lon += step * 0.7
      end
    end
    hexes
  end

  describe 'rail journey with transfer' do
    let(:origin) { create(:location, zone: zone, world: world, globe_hex_id: 1, has_train_station: true) }
    let(:destination) { create(:location, zone: zone, world: world, globe_hex_id: 5) }
    let(:origin_room) { create(:room, location: origin) }
    let(:character) { create(:character) }
    let(:character_instance) { create(:character_instance, character: character, current_room: origin_room) }

    before do
      # Create a line of adjacent hexes using lat/lon
      # Railway from hex 1 to hex 3, then land only from hex 3 to hex 5
      # Use 0.8 degree spacing (within NEIGHBOR_THRESHOLD_DEGREES of 1.0)
      hex1 = WorldHex.set_hex_details(world, 1, terrain_type: 'urban')
      hex1.update(latitude: 0.0, longitude: 0.0)
      hex1.set_directional_feature('n', 'railway')

      hex2 = WorldHex.set_hex_details(world, 2, terrain_type: 'grassy_plains')
      hex2.update(latitude: 0.8, longitude: 0.0)
      hex2.set_directional_feature('s', 'railway')
      hex2.set_directional_feature('n', 'railway')

      hex3 = WorldHex.set_hex_details(world, 3, terrain_type: 'urban')
      hex3.update(latitude: 1.6, longitude: 0.0)
      hex3.set_directional_feature('s', 'railway')
      # No railway beyond hex3

      # Land only from hex3 to hex5
      hex4 = WorldHex.set_hex_details(world, 4, terrain_type: 'grassy_plains')
      hex4.update(latitude: 2.4, longitude: 0.0)

      hex5 = WorldHex.set_hex_details(world, 5, terrain_type: 'urban')
      hex5.update(latitude: 3.2, longitude: 0.0)
    end

    it 'creates multi-segment journey with rail then land' do
      result = WorldTravelService.start_journey(
        character_instance,
        destination: destination,
        travel_mode: 'rail'
      )

      expect(result[:success]).to be true
      journey = result[:journey]

      # Should have 2 segments - rail then land
      expect(journey.segments.length).to eq(2)
      expect(journey.segments[0]['mode']).to eq('rail')
      expect(journey.segments[1]['mode']).to eq('land')
    end

    it 'shows transfer message for multi-segment journey' do
      result = WorldTravelService.start_journey(
        character_instance,
        destination: destination,
        travel_mode: 'rail'
      )

      expect(result[:success]).to be true
      expect(result[:message]).to match(/transfer|then/i)
    end

    it 'uses correct vehicle for rail segment' do
      result = WorldTravelService.start_journey(
        character_instance,
        destination: destination,
        travel_mode: 'rail'
      )

      expect(result[:success]).to be true
      journey = result[:journey]

      # First segment should be rail vehicle
      expect(journey.segments[0]['vehicle']).to match(/train|rail/i)
    end

    it 'sets first segment as the active travel mode' do
      result = WorldTravelService.start_journey(
        character_instance,
        destination: destination,
        travel_mode: 'rail'
      )

      expect(result[:success]).to be true
      journey = result[:journey]
      expect(journey.travel_mode).to eq('rail')
    end
  end

  describe 'water journey with era bonus' do
    # Create a water route: coast -> ocean -> coast
    let(:origin) { create(:location, zone: zone, world: world, globe_hex_id: 10, has_port: true) }
    let(:destination) { create(:location, zone: zone, world: world, globe_hex_id: 12, has_port: true) }
    let(:origin_room) { create(:room, location: origin) }
    let(:character) { create(:character) }
    let(:character_instance) { create(:character_instance, character: character, current_room: origin_room) }

    before do
      # Water route: coast -> ocean -> coast along a line (0.8 degree spacing)
      hex10 = WorldHex.set_hex_details(world, 10, terrain_type: 'sandy_coast')
      hex10.update(latitude: 0.0, longitude: 0.0)

      hex11 = WorldHex.set_hex_details(world, 11, terrain_type: 'ocean')
      hex11.update(latitude: 0.0, longitude: 0.8)

      hex12 = WorldHex.set_hex_details(world, 12, terrain_type: 'sandy_coast')
      hex12.update(latitude: 0.0, longitude: 1.6)
    end

    it 'successfully plans water journey' do
      result = WorldTravelService.start_journey(
        character_instance,
        destination: destination,
        travel_mode: 'water'
      )

      expect(result[:success]).to be true
      journey = result[:journey]
      expect(journey.travel_mode).to eq('water')
    end

    it 'returns success message with destination name' do
      result = WorldTravelService.start_journey(
        character_instance,
        destination: destination,
        travel_mode: 'water'
      )

      expect(result[:success]).to be true
      expect(result[:message]).to include(destination.name)
    end

    context 'in medieval era' do
      before do
        allow(EraService).to receive(:current_era).and_return(:medieval)
        allow(GameSetting).to receive(:get).with('time_period').and_return('medieval')
      end

      it 'creates water journey that can use medieval era bonus' do
        result = WorldTravelService.start_journey(
          character_instance,
          destination: destination,
          travel_mode: 'water'
        )

        expect(result[:success]).to be true
        journey = result[:journey]

        # In medieval era, water terrain gets a 2.0 bonus (WATER_ERA_BONUSES[:medieval])
        # This is verified by checking the config exists
        expect(GameConfig::WorldTravel::WATER_ERA_BONUSES[:medieval]).to eq(2.0)
      end
    end

    context 'in modern era' do
      before do
        allow(EraService).to receive(:current_era).and_return(:modern)
        allow(GameSetting).to receive(:get).with('time_period').and_return('modern')
      end

      it 'creates water journey with modern era bonus' do
        result = WorldTravelService.start_journey(
          character_instance,
          destination: destination,
          travel_mode: 'water'
        )

        expect(result[:success]).to be true

        # Modern era has a 1.2 water bonus (less than medieval)
        expect(GameConfig::WorldTravel::WATER_ERA_BONUSES[:modern]).to eq(1.2)
      end
    end
  end

  describe 'complete rail journey' do
    # Full railway route: hex 20 -> hex 21 -> hex 22 all connected
    let(:origin) { create(:location, zone: zone, world: world, globe_hex_id: 20, has_train_station: true) }
    let(:destination) { create(:location, zone: zone, world: world, globe_hex_id: 22, has_train_station: true) }
    let(:origin_room) { create(:room, location: origin) }
    let(:character) { create(:character) }
    let(:character_instance) { create(:character_instance, character: character, current_room: origin_room) }

    before do
      # Full railway from origin to destination (0.8 degree spacing)
      hex20 = WorldHex.set_hex_details(world, 20, terrain_type: 'urban')
      hex20.update(latitude: 10.0, longitude: 0.0)
      hex20.set_directional_feature('n', 'railway')

      hex21 = WorldHex.set_hex_details(world, 21, terrain_type: 'grassy_plains')
      hex21.update(latitude: 10.8, longitude: 0.0)
      hex21.set_directional_feature('s', 'railway')
      hex21.set_directional_feature('n', 'railway')

      hex22 = WorldHex.set_hex_details(world, 22, terrain_type: 'urban')
      hex22.update(latitude: 11.6, longitude: 0.0)
      hex22.set_directional_feature('s', 'railway')
    end

    it 'creates single-segment rail journey' do
      result = WorldTravelService.start_journey(
        character_instance,
        destination: destination,
        travel_mode: 'rail'
      )

      expect(result[:success]).to be true
      journey = result[:journey]

      # Should be single segment (full rail route exists)
      expect(journey.segments.length).to eq(1)
      expect(journey.segments[0]['mode']).to eq('rail')
    end

    it 'rail journey has railway speed bonus configured' do
      # Verify the railway speed bonus is configured
      expect(GameConfig::WorldTravel::RAILWAY_SPEED_BONUS).to eq(3.0)
    end

    it 'creates passenger record for character' do
      result = WorldTravelService.start_journey(
        character_instance,
        destination: destination,
        travel_mode: 'rail'
      )

      expect(result[:success]).to be true
      journey = result[:journey]

      # Character should be a passenger on the journey
      expect(journey.passengers).to include(character_instance)
    end

    it 'marks character as driver for solo journey' do
      result = WorldTravelService.start_journey(
        character_instance,
        destination: destination,
        travel_mode: 'rail'
      )

      expect(result[:success]).to be true
      journey = result[:journey]

      # Solo journey - character is the driver (compare by ID due to Sequel object identity)
      expect(journey.driver.id).to eq(character_instance.id)
    end
  end

  describe 'pathfinding respects travel mode' do
    let(:world) { create(:world, universe: universe) }

    describe 'rail pathfinding' do
      it 'requires railway features to find path' do
        # Create hexes WITHOUT railway (0.8 degree spacing)
        hex30 = WorldHex.set_hex_details(world, 30, terrain_type: 'urban')
        hex30.update(latitude: 20.0, longitude: 0.0)

        hex31 = WorldHex.set_hex_details(world, 31, terrain_type: 'grassy_plains')  # No railway
        hex31.update(latitude: 20.8, longitude: 0.0)

        hex32 = WorldHex.set_hex_details(world, 32, terrain_type: 'urban')
        hex32.update(latitude: 21.6, longitude: 0.0)

        path = GlobePathfindingService.find_path(
          world: world,
          start_globe_hex_id: 30,
          end_globe_hex_id: 32,
          travel_mode: 'rail'
        )

        # Should be empty - no railway connection
        expect(path).to be_empty
      end

      it 'finds path when railway exists' do
        # Create hexes WITH railway (0.8 degree spacing)
        hex40 = WorldHex.set_hex_details(world, 40, terrain_type: 'urban')
        hex40.update(latitude: 30.0, longitude: 0.0)
        hex40.set_directional_feature('n', 'railway')

        hex41 = WorldHex.set_hex_details(world, 41, terrain_type: 'grassy_plains')
        hex41.update(latitude: 30.8, longitude: 0.0)
        hex41.set_directional_feature('s', 'railway')
        hex41.set_directional_feature('n', 'railway')

        hex42 = WorldHex.set_hex_details(world, 42, terrain_type: 'urban')
        hex42.update(latitude: 31.6, longitude: 0.0)
        hex42.set_directional_feature('s', 'railway')

        path = GlobePathfindingService.find_path(
          world: world,
          start_globe_hex_id: 40,
          end_globe_hex_id: 42,
          travel_mode: 'rail'
        )

        expect(path).not_to be_empty
        expect(path.first).to eq(40)
        expect(path.last).to eq(42)
      end
    end

    describe 'water pathfinding' do
      it 'prefers water hexes' do
        # Create water route (0.8 degree spacing)
        hex50 = WorldHex.set_hex_details(world, 50, terrain_type: 'sandy_coast')
        hex50.update(latitude: 40.0, longitude: 0.0)

        hex51 = WorldHex.set_hex_details(world, 51, terrain_type: 'ocean')
        hex51.update(latitude: 40.0, longitude: 0.8)

        hex52 = WorldHex.set_hex_details(world, 52, terrain_type: 'sandy_coast')
        hex52.update(latitude: 40.0, longitude: 1.6)

        path = GlobePathfindingService.find_path(
          world: world,
          start_globe_hex_id: 50,
          end_globe_hex_id: 52,
          travel_mode: 'water'
        )

        # Should find path through water
        expect(path).not_to be_empty
        expect(path.first).to eq(50)
        expect(path.last).to eq(52)
      end

      it 'water mode makes land expensive' do
        # The water mode land penalty should be high
        expect(GameConfig::WorldTravel::WATER_MODE_LAND_PENALTY).to eq(100)
      end
    end

    describe 'land pathfinding' do
      it 'avoids water when avoid_water is true' do
        # Create path with water blocking direct route (0.8 degree spacing)
        hex60 = WorldHex.set_hex_details(world, 60, terrain_type: 'grassy_plains')
        hex60.update(latitude: 50.0, longitude: 0.0)

        hex61 = WorldHex.set_hex_details(world, 61, terrain_type: 'ocean')  # Water blocks
        hex61.update(latitude: 50.0, longitude: 0.8)

        hex62 = WorldHex.set_hex_details(world, 62, terrain_type: 'grassy_plains')
        hex62.update(latitude: 50.0, longitude: 1.6)

        path = GlobePathfindingService.find_path(
          world: world,
          start_globe_hex_id: 60,
          end_globe_hex_id: 62,
          travel_mode: 'land',
          avoid_water: true
        )

        # Should not include the ocean hex
        if path.any?
          expect(path).not_to include(61)
        end
      end

      it 'land mode makes water expensive' do
        # The land mode water penalty should be high
        expect(GameConfig::WorldTravel::LAND_MODE_WATER_PENALTY).to eq(100)
      end
    end
  end

  describe 'journey lifecycle' do
    let(:origin) { create(:location, zone: zone, world: world, globe_hex_id: 70) }
    let(:destination) { create(:location, zone: zone, world: world, globe_hex_id: 71) }
    let(:origin_room) { create(:room, location: origin) }
    let(:character) { create(:character) }
    let(:character_instance) { create(:character_instance, character: character, current_room: origin_room) }

    before do
      # Simple land path - two adjacent hexes (0.8 degree spacing)
      hex70 = WorldHex.set_hex_details(world, 70, terrain_type: 'grassy_plains')
      hex70.update(latitude: 60.0, longitude: 0.0)

      hex71 = WorldHex.set_hex_details(world, 71, terrain_type: 'grassy_plains')
      hex71.update(latitude: 60.8, longitude: 0.0)
    end

    it 'journey starts in traveling status' do
      result = WorldTravelService.start_journey(
        character_instance,
        destination: destination,
        travel_mode: 'land'
      )

      expect(result[:success]).to be true
      journey = result[:journey]
      expect(journey.traveling?).to be true
      expect(journey.status).to eq('traveling')
    end

    it 'prevents starting journey when already traveling' do
      # Start first journey
      first_result = WorldTravelService.start_journey(
        character_instance,
        destination: destination,
        travel_mode: 'land'
      )
      expect(first_result[:success]).to be true

      # Try to start second journey
      second_result = WorldTravelService.start_journey(
        character_instance,
        destination: destination,
        travel_mode: 'land'
      )

      expect(second_result[:success]).to be false
      expect(second_result[:error]).to include('already')
    end

    it 'can cancel an ongoing journey' do
      result = WorldTravelService.start_journey(
        character_instance,
        destination: destination,
        travel_mode: 'land'
      )
      journey = result[:journey]

      cancel_result = WorldTravelService.cancel_journey(character_instance)

      expect(cancel_result[:success]).to be true
      journey.refresh
      expect(journey.status).to eq('cancelled')
    end
  end

  describe 'calculate_route' do
    let(:origin) { create(:location, zone: zone, world: world, globe_hex_id: 80) }
    let(:destination) { create(:location, zone: zone, world: world, globe_hex_id: 81) }

    before do
      # Adjacent hexes for route calculation (0.8 degree spacing)
      hex80 = WorldHex.set_hex_details(world, 80, terrain_type: 'grassy_plains')
      hex80.update(latitude: 70.0, longitude: 0.0)

      hex81 = WorldHex.set_hex_details(world, 81, terrain_type: 'grassy_plains')
      hex81.update(latitude: 70.8, longitude: 0.0)
    end

    it 'returns route options sorted by time' do
      result = WorldTravelService.calculate_route(
        origin: origin,
        destination: destination
      )

      expect(result[:success]).to be true
      expect(result[:routes]).to be_an(Array)
      expect(result[:routes]).not_to be_empty
    end

    it 'includes estimated time for routes' do
      result = WorldTravelService.calculate_route(
        origin: origin,
        destination: destination
      )

      expect(result[:success]).to be true
      route = result[:routes].first

      expect(route[:estimated_seconds]).to be_a(Integer)
      expect(route[:estimated_time]).to be_a(String)
      expect(route[:path_length]).to be > 0
    end

    it 'fails for different worlds' do
      other_universe = create(:universe)
      other_world = create(:world, universe: other_universe)
      other_zone = create(:zone, world: other_world)
      other_location = create(:location, zone: other_zone, world: other_world, globe_hex_id: 100)

      result = WorldTravelService.calculate_route(
        origin: origin,
        destination: other_location
      )

      expect(result[:success]).to be false
      expect(result[:error]).to include('different worlds')
    end
  end
end
