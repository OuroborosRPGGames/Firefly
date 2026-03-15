# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Generators::CityGeneratorService do
  describe 'constants' do
    it 'defines CITY_SIZES with expected sizes' do
      expect(described_class::CITY_SIZES.keys).to include(:village, :town, :small_city, :medium, :large_city, :metropolis)
    end

    it 'defines village size parameters' do
      village = described_class::CITY_SIZES[:village]
      expect(village[:streets]).to eq(3)
      expect(village[:avenues]).to eq(3)
      expect(village[:places]).to eq(5..10)
      expect(village[:max_height]).to eq(40)
    end

    it 'defines metropolis size parameters' do
      metropolis = described_class::CITY_SIZES[:metropolis]
      expect(metropolis[:streets]).to eq(20)
      expect(metropolis[:avenues]).to eq(20)
      expect(metropolis[:places]).to eq(150..250)
      expect(metropolis[:max_height]).to eq(300)
    end

    it 'defines PLACE_DISTRIBUTION for all city sizes' do
      expect(described_class::PLACE_DISTRIBUTION.keys).to match_array(described_class::CITY_SIZES.keys)
    end

    it 'includes essential place types in village distribution' do
      village_dist = described_class::PLACE_DISTRIBUTION[:village]
      expect(village_dist[:tavern]).to eq(1)
      expect(village_dist[:general_store]).to eq(1)
    end

    it 'includes luxury place types in metropolis distribution' do
      metro_dist = described_class::PLACE_DISTRIBUTION[:metropolis]
      expect(metro_dist[:mansion]).to eq(6..12)
      expect(metro_dist[:library]).to eq(2..4)
    end
  end

  describe '.generate_name' do
    before do
      # Mock NameGeneratorService to return predictable options
      allow(NameGeneratorService).to receive(:city_options).and_return([
        double('CityName', name: 'Ironhold'),
        double('CityName', name: 'Silverdale'),
        double('CityName', name: 'Stormhaven')
      ])

      # Mock GenerationPipelineService for LLM selection
      allow(GenerationPipelineService).to receive(:select_best_name).and_return({
        selected: 'Stormhaven',
        reasoning: 'Evokes strength and safety'
      })
    end

    it 'returns success with generated name' do
      result = described_class.generate_name(setting: :fantasy, seed_terms: ['ancient', 'prosperous'])

      expect(result[:success]).to be true
      expect(result[:name]).to eq('Stormhaven')
    end

    it 'includes alternative names' do
      result = described_class.generate_name(setting: :fantasy)

      expect(result[:alternatives]).to include('Ironhold', 'Silverdale', 'Stormhaven')
    end

    it 'includes LLM reasoning' do
      result = described_class.generate_name(setting: :fantasy)

      expect(result[:reasoning]).to eq('Evokes strength and safety')
    end

    it 'falls back to first option if LLM returns nil' do
      allow(GenerationPipelineService).to receive(:select_best_name).and_return({ selected: nil })

      result = described_class.generate_name(setting: :fantasy)

      expect(result[:name]).to eq('Ironhold')
    end

    context 'when NameGeneratorService returns empty' do
      before do
        allow(NameGeneratorService).to receive(:city_options).and_return([])
      end

      it 'returns failure' do
        result = described_class.generate_name(setting: :fantasy)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('No city name options generated')
      end
    end

    context 'when an error occurs' do
      before do
        allow(NameGeneratorService).to receive(:city_options).and_raise(StandardError, 'API error')
      end

      it 'returns failure with error message' do
        result = described_class.generate_name(setting: :fantasy)

        expect(result[:success]).to be false
        expect(result[:error]).to include('City name generation failed')
        expect(result[:error]).to include('API error')
      end
    end
  end

  describe '.generate_street_names' do
    before do
      allow(NameGeneratorService).to receive(:street_options).and_return([
        double('StreetName', name: 'Main Street'),
        double('StreetName', name: 'Oak Avenue'),
        double('StreetName', name: 'Market Lane'),
        double('StreetName', name: 'Church Road'),
        double('StreetName', name: 'Kings Way')
      ])
    end

    it 'generates requested number of street names' do
      result = described_class.generate_street_names(count: 5, setting: :fantasy)

      expect(result[:names].length).to eq(5)
      expect(result[:error]).to be_nil
    end

    it 'includes expected street names' do
      result = described_class.generate_street_names(count: 3, setting: :fantasy)

      expect(result[:names]).to include('Main Street', 'Oak Avenue', 'Market Lane')
    end

    it 'generates in batches for larger counts' do
      # Request 12 names - should call street_options 3 times (ceil of 12/5)
      expect(NameGeneratorService).to receive(:street_options).exactly(3).times.and_return([
        double('StreetName', name: 'Test Street')
      ])

      described_class.generate_street_names(count: 12, setting: :fantasy)
    end

    context 'when an error occurs' do
      before do
        allow(NameGeneratorService).to receive(:street_options).and_raise(StandardError, 'Network error')
      end

      it 'returns empty names with error' do
        result = described_class.generate_street_names(count: 5, setting: :fantasy)

        expect(result[:names]).to be_empty
        expect(result[:error]).to include('Street name generation failed')
        expect(result[:error]).to include('Network error')
      end
    end
  end

  describe '.plan_places' do
    it 'returns array of planned places' do
      result = described_class.plan_places(size: :village, setting: :fantasy)

      expect(result).to be_an(Array)
      expect(result.all? { |p| p.key?(:place_type) && p.key?(:tier) && p.key?(:priority) }).to be true
    end

    it 'plans tavern for village' do
      result = described_class.plan_places(size: :village)

      taverns = result.select { |p| p[:place_type] == :tavern }
      expect(taverns.length).to eq(1)  # village has exactly 1 tavern
    end

    it 'plans general_store for village' do
      result = described_class.plan_places(size: :village)

      stores = result.select { |p| p[:place_type] == :general_store }
      expect(stores.length).to eq(1)
    end

    it 'uses medium distribution for unknown size' do
      result = described_class.plan_places(size: :unknown_size)

      # Medium has 4..6 taverns
      taverns = result.select { |p| p[:place_type] == :tavern }
      expect(taverns.length).to be_between(4, 6)
    end

    it 'sorts places by priority (essential first)' do
      result = described_class.plan_places(size: :village)

      # Tavern (priority 100) should come before townhouse (priority 30)
      tavern_idx = result.find_index { |p| p[:place_type] == :tavern }
      townhouse_idx = result.find_index { |p| p[:place_type] == :townhouse }

      expect(tavern_idx).to be < townhouse_idx if tavern_idx && townhouse_idx
    end

    it 'assigns tiers to places' do
      result = described_class.plan_places(size: :village)

      tiers = result.map { |p| p[:tier] }
      valid_tiers = [:common, :fine, :luxury]
      expect(tiers).to all(satisfy { |t| valid_tiers.include?(t) })
    end
  end

  describe '.generate_city_places' do
    let(:location) { double('Location', id: 1, horizontal_streets: 5, max_building_height: 100) }
    let(:places_plan) do
      [
        { place_type: :tavern, tier: :common, priority: 100 },
        { place_type: :general_store, tier: :common, priority: 90 }
      ]
    end
    let(:intersection_room) { double('Room', id: 10, grid_x: 0, grid_y: 0) }

    before do
      allow(Generators::PlaceGeneratorService).to receive(:generate).and_return({
        success: true,
        name: 'The Dragon Inn',
        layout: [{ name: 'Common Room' }, { name: 'Kitchen' }]
      })
    end

    it 'generates all planned places' do
      result = described_class.generate_city_places(
        location: location,
        places_plan: places_plan,
        setting: :fantasy,
        generate_rooms: false,
        generate_npcs: false
      )

      expect(result[:places].length).to eq(2)
      expect(result[:errors]).to be_empty
    end

    it 'returns place info with type and name' do
      result = described_class.generate_city_places(
        location: location,
        places_plan: places_plan,
        setting: :fantasy,
        generate_rooms: false,
        generate_npcs: false
      )

      place = result[:places].first
      expect(place[:type]).to eq(:tavern)
      expect(place[:name]).to eq('The Dragon Inn')
      expect(place[:rooms]).to eq(2)
    end

    it 'calls Generators::PlaceGeneratorService with correct params' do
      expect(Generators::PlaceGeneratorService).to receive(:generate).with(
        hash_including(
          location: location,
          place_type: :tavern,
          setting: :fantasy,
          generate_rooms: true,
          generate_npcs: true
        )
      )

      described_class.generate_city_places(
        location: location,
        places_plan: [places_plan.first],
        setting: :fantasy,
        generate_rooms: true,
        generate_npcs: true
      )
    end

    context 'with create_buildings option' do
      let(:building) { double('Room', id: 100) }
      let(:rooms) { [double('Room', id: 101), double('Room', id: 102)] }

      before do
        allow(Generators::PlaceGeneratorService).to receive(:generate).and_return({
          success: true,
          name: 'The Dragon Inn',
          layout: [{ name: 'Common Room' }],
          building: building,
          rooms: rooms
        })
        # Stub BlockLotService for block-lot-aware generation
        allow(BlockLotService).to receive(:plan_blocks).and_return([
          { block_type: :quarters, buildings: [:bar, :shop] }
        ])
        allow(BlockLotService).to receive(:create_alleys).and_return([])
        allow(BlockLotService).to receive(:lot_bounds).and_return({
          nw: { min_x: 25, max_x: 95, min_y: 105, max_y: 175, min_z: 0, max_z: 100, width: 70, height: 70 },
          ne: { min_x: 105, max_x: 175, min_y: 105, max_y: 175, min_z: 0, max_z: 100, width: 70, height: 70 },
          sw: { min_x: 25, max_x: 95, min_y: 25, max_y: 95, min_z: 0, max_z: 100, width: 70, height: 70 },
          se: { min_x: 105, max_x: 175, min_y: 25, max_y: 95, min_z: 0, max_z: 100, width: 70, height: 70 }
        })
      end

      it 'uses intersection rooms for building placement' do
        expect(Generators::PlaceGeneratorService).to receive(:generate).with(
          hash_including(
            parent_room: intersection_room,
            create_building: true
          )
        ).at_least(:once)

        described_class.generate_city_places(
          location: location,
          places_plan: [places_plan.first],
          intersection_rooms: [intersection_room],
          setting: :fantasy,
          generate_rooms: false,
          create_buildings: true,
          generate_npcs: false
        )
      end

      it 'includes building info in results' do
        result = described_class.generate_city_places(
          location: location,
          places_plan: [places_plan.first],
          intersection_rooms: [intersection_room],
          setting: :fantasy,
          generate_rooms: false,
          create_buildings: true,
          generate_npcs: false
        )

        place = result[:places].first
        expect(place[:building_id]).to eq(100)
        expect(place[:room_ids]).to eq([101, 102])
      end

      it 'tracks used intersections to avoid duplicates' do
        # With block-lot planning and 1 intersection, both buildings in same block
        # share the intersection. But they both get the same parent_room.
        # Stub plan_blocks to return 2 separate blocks to test tracking.
        allow(BlockLotService).to receive(:plan_blocks).and_return([
          { block_type: :full, buildings: [:bar] },
          { block_type: :full, buildings: [:shop] }
        ])
        allow(BlockLotService).to receive(:lot_bounds).and_return({
          full: { min_x: 25, max_x: 175, min_y: 25, max_y: 175, min_z: 0, max_z: 100, width: 150, height: 150 }
        })

        # First building gets the intersection, second has no intersection available
        expect(Generators::PlaceGeneratorService).to receive(:generate).with(
          hash_including(parent_room: intersection_room)
        ).once
        expect(Generators::PlaceGeneratorService).to receive(:generate).with(
          hash_including(parent_room: nil)
        ).once

        described_class.generate_city_places(
          location: location,
          places_plan: places_plan,
          intersection_rooms: [intersection_room],
          setting: :fantasy,
          generate_rooms: false,
          create_buildings: true,
          generate_npcs: false
        )
      end
    end

    context 'when place generation fails' do
      before do
        allow(Generators::PlaceGeneratorService).to receive(:generate).and_return({
          success: false,
          errors: ['LLM timeout']
        })
      end

      it 'records errors' do
        result = described_class.generate_city_places(
          location: location,
          places_plan: places_plan,
          setting: :fantasy,
          generate_rooms: false,
          generate_npcs: false
        )

        expect(result[:errors].length).to eq(2)
        expect(result[:errors]).to all(include('LLM timeout'))
      end
    end

    context 'with job progress tracking' do
      let(:job) { double('GenerationJob') }

      before do
        allow(ProgressTrackerService).to receive(:update_progress)
      end

      it 'updates progress for each place' do
        expect(ProgressTrackerService).to receive(:update_progress).twice

        described_class.generate_city_places(
          location: location,
          places_plan: places_plan,
          setting: :fantasy,
          generate_rooms: false,
          generate_npcs: false,
          job: job
        )
      end
    end
  end

  describe '.generate' do
    let(:location) { double('Location', id: 1) }

    before do
      # Mock all dependencies
      allow(SeedTermService).to receive(:for_generation).and_return(['ancient', 'prosperous'])

      allow(described_class).to receive(:generate_name).and_return({
        success: true,
        name: 'Stormhaven'
      })

      allow(described_class).to receive(:generate_street_names).and_return({
        names: ['Main Street', 'Oak Avenue'],
        error: nil
      })

      allow(CityBuilderService).to receive(:build_city).and_return({
        success: true,
        streets: [1, 2, 3],
        avenues: [4, 5],
        intersections: [10, 11, 12, 13],
        street_names: ['Main Street', 'Oak Avenue'],
        avenue_names: ['River Avenue', 'Hill Avenue']
      })

      allow(described_class).to receive(:plan_places).and_return([
        { place_type: :tavern, tier: :common, priority: 100 }
      ])

      allow(described_class).to receive(:generate_city_places).and_return({
        places: [{ type: :tavern, name: 'The Dragon Inn', rooms: 2 }],
        errors: []
      })

      allow(Room).to receive(:where).and_return(double(all: []))
      allow(ProgressTrackerService).to receive(:update_progress)
    end

    it 'returns success with complete city data' do
      result = described_class.generate(location: location, setting: :fantasy, size: :village)

      expect(result[:success]).to be true
      expect(result[:city_name]).to eq('Stormhaven')
      expect(result[:street_names]).to eq(['Main Street', 'Oak Avenue'])
      expect(result[:avenue_names]).to eq(['River Avenue', 'Hill Avenue'])
      expect(result[:streets]).to eq(5)  # 3 streets + 2 avenues
      expect(result[:intersections]).to eq(4)
      expect(result[:seed_terms]).to eq(['ancient', 'prosperous'])
    end

    it 'generates places by default' do
      result = described_class.generate(location: location, setting: :fantasy)

      expect(result[:places]).not_to be_empty
      expect(result[:places].first[:name]).to eq('The Dragon Inn')
    end

    it 'skips place generation when generate_places is false' do
      expect(described_class).not_to receive(:generate_city_places)

      result = described_class.generate(
        location: location,
        setting: :fantasy,
        generate_places: false
      )

      expect(result[:places]).to be_nil
    end

    it 'uses medium size config by default' do
      # Medium has 10 streets and 10 avenues
      expect(CityBuilderService).to receive(:build_city).with(
        hash_including(
          params: hash_including(
            horizontal_streets: 10,
            vertical_streets: 10
          )
        )
      )

      described_class.generate(location: location, setting: :fantasy)
    end

    it 'uses specified size config' do
      # Village has 3 streets and 3 avenues
      expect(CityBuilderService).to receive(:build_city).with(
        hash_including(
          params: hash_including(
            horizontal_streets: 3,
            vertical_streets: 3
          )
        )
      )

      described_class.generate(location: location, setting: :fantasy, size: :village)
    end

    it 'passes generated names into city build params' do
      expect(CityBuilderService).to receive(:build_city).with(
        hash_including(
          params: hash_including(
            street_names: an_instance_of(Array),
            avenue_names: an_instance_of(Array)
          )
        )
      ).and_return({
        success: true,
        streets: [1],
        avenues: [2],
        intersections: [3],
        street_names: ['Main Street'],
        avenue_names: ['River Avenue']
      })

      described_class.generate(location: location, setting: :fantasy, size: :village)
    end

    context 'when name generation fails' do
      before do
        allow(described_class).to receive(:generate_name).and_return({
          success: false,
          error: 'Name API down'
        })
      end

      it 'returns failure' do
        result = described_class.generate(location: location)

        expect(result[:success]).to be false
        expect(result[:errors]).to include('Name API down')
      end
    end

    context 'when grid building fails' do
      before do
        allow(CityBuilderService).to receive(:build_city).and_return({
          success: false,
          error: 'Invalid grid parameters'
        })
      end

      it 'returns failure' do
        result = described_class.generate(location: location)

        expect(result[:success]).to be false
        expect(result[:errors]).to include('Invalid grid parameters')
      end
    end

    context 'with coordinate-based location creation' do
      before do
        allow(LocationResolverService).to receive(:resolve).and_return({
          success: true,
          location: location,
          created: true
        })
      end

      it 'creates location from coordinates' do
        result = described_class.generate(
          longitude: -122.4,
          latitude: 37.8,
          setting: :fantasy
        )

        expect(result[:location_created]).to be true
        expect(result[:location_id]).to eq(1)
      end

      it 'uses generated city name for location' do
        expect(LocationResolverService).to receive(:resolve).with(
          hash_including(
            name: 'Stormhaven',
            location_type: 'building'
          )
        )

        described_class.generate(longitude: -122.4, latitude: 37.8)
      end

      it 'fails if location resolution fails' do
        allow(LocationResolverService).to receive(:resolve).and_return({
          success: false,
          error: 'Invalid coordinates'
        })

        result = described_class.generate(longitude: 0, latitude: 0)

        expect(result[:success]).to be false
        expect(result[:errors].first).to include('Failed to create location')
      end
    end

    context 'without location or coordinates' do
      it 'returns error' do
        result = described_class.generate(setting: :fantasy)

        expect(result[:success]).to be false
        expect(result[:errors]).to include('Either location or coordinates (longitude, latitude) must be provided')
      end
    end

    context 'with custom seed terms' do
      it 'uses provided seed terms' do
        result = described_class.generate(
          location: location,
          options: { seed_terms: ['mystical', 'ancient'] }
        )

        expect(result[:seed_terms]).to eq(['mystical', 'ancient'])
      end
    end

    context 'with job progress tracking' do
      let(:job) { double('GenerationJob') }

      it 'updates progress at each step' do
        # 6 progress updates when location is provided (step 2 is skipped)
        # Steps: 1-name, 3-streets, 4-grid, 5-plan, 6-places, 7-complete
        expect(ProgressTrackerService).to receive(:update_progress).at_least(6).times

        described_class.generate(location: location, job: job)
      end
    end
  end

  describe 'private methods' do
    describe '#plan_building_manifest' do
      before do
        allow(GamePrompts).to receive(:get_safe).and_return('Return JSON only')
      end

      it 'calls LLM client with keyword args and parses manifest' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '[{"name":"The Silver Tankard","place_type":"tavern","character":"cozy"}]'
        })

        result = described_class.send(
          :plan_building_manifest,
          city_name: 'Stormhaven',
          city_size: :village,
          setting: :fantasy,
          slot_count: 1,
          seed_terms: ['cozy']
        )

        expect(LLM::Client).to have_received(:generate).with(
          prompt: 'Return JSON only',
          options: { max_tokens: 4000 }
        )
        expect(result).to be_an(Array)
        expect(result.first[:place_type]).to eq(:tavern)
      end

      it 'normalizes cafe alias to supported restaurant type' do
        allow(LLM::Client).to receive(:generate).and_return({
          success: true,
          text: '[{"name":"Bean & Hearth","place_type":"cafe","character":"cozy"}]'
        })

        result = described_class.send(
          :plan_building_manifest,
          city_name: 'Stormhaven',
          city_size: :village,
          setting: :fantasy,
          slot_count: 1,
          seed_terms: ['cozy']
        )

        expect(result).to be_an(Array)
        expect(result.first[:place_type]).to eq(:restaurant)
      end
    end

    describe '#select_tier' do
      it 'returns a valid tier' do
        tier = described_class.send(:select_tier, :tavern)
        valid_tiers = [:common, :fine, :luxury]

        expect(valid_tiers).to include(tier)
      end

      it 'returns mostly common tiers (5/9 chance)' do
        # Run multiple times to verify distribution
        tiers = 100.times.map { described_class.send(:select_tier, :tavern) }

        common_count = tiers.count(:common)
        # Common should be roughly 55% (5/9)
        expect(common_count).to be > 35  # At least 35% should be common
      end
    end

    describe '#place_priority' do
      it 'assigns highest priority to tavern' do
        expect(described_class.send(:place_priority, :tavern)).to eq(100)
      end

      it 'assigns highest priority to inn' do
        expect(described_class.send(:place_priority, :inn)).to eq(100)
      end

      it 'assigns high priority to essential services' do
        expect(described_class.send(:place_priority, :general_store)).to eq(90)
        expect(described_class.send(:place_priority, :blacksmith)).to eq(90)
      end

      it 'assigns lower priority to residential' do
        expect(described_class.send(:place_priority, :townhouse)).to eq(30)
        expect(described_class.send(:place_priority, :mansion)).to eq(20)
      end

      it 'assigns minimum priority to unknown types' do
        expect(described_class.send(:place_priority, :unknown_type)).to eq(10)
      end
    end
  end
end
