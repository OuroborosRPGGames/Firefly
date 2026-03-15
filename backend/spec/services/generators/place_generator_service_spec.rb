# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Generators::PlaceGeneratorService do
  let(:location) { double('Location', id: 1, name: 'Test City', max_building_height: 100) }
  let(:seed_terms) { %w[cozy rustic warm] }

  before do
    allow(SeedTermService).to receive(:for_generation).and_return(seed_terms)
  end

  describe '.generate' do
    before do
      allow(described_class).to receive(:generate_name).and_return({
        success: true,
        name: 'The Rusty Anchor',
        alternatives: ['The Golden Mug', 'The Wayward Traveler'],
        reasoning: 'Evokes maritime theme'
      })
      allow(described_class).to receive(:generate_room_descriptions).and_return({
        descriptions: { 'common_room' => 'A bustling room', 'kitchen' => 'A hot kitchen' },
        errors: []
      })
      allow(described_class).to receive(:generate_place_npcs).and_return({
        npcs: [],
        errors: []
      })
    end

    it 'generates a complete place' do
      result = described_class.generate(
        location: location,
        place_type: :tavern,
        setting: :fantasy
      )

      expect(result[:success]).to eq(true)
      expect(result[:name]).to eq('The Rusty Anchor')
      expect(result[:layout]).to be_an(Array)
    end

    it 'includes seed terms in results' do
      result = described_class.generate(
        location: location,
        place_type: :blacksmith
      )

      expect(result[:seed_terms]).to eq(seed_terms)
    end

    context 'with unknown place type' do
      it 'returns error' do
        result = described_class.generate(
          location: location,
          place_type: :unknown_type
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown place type')
      end
    end

    context 'when name generation fails' do
      before do
        allow(described_class).to receive(:generate_name).and_return({
          success: false,
          error: 'Name service unavailable'
        })
      end

      it 'returns error' do
        result = described_class.generate(
          location: location,
          place_type: :tavern
        )

        expect(result[:success]).to be false
        expect(result[:errors]).to include('Name service unavailable')
      end
    end

    context 'with coordinates instead of location' do
      before do
        allow(LocationResolverService).to receive(:resolve).and_return({
          success: true,
          location: location,
          created: true
        })
      end

      it 'resolves location from coordinates' do
        result = described_class.generate(
          longitude: -122.4194,
          latitude: 37.7749,
          place_type: :tavern
        )

        expect(result[:success]).to eq(true)
        expect(result[:location_created]).to be true
      end
    end

    context 'with pre-assigned name' do
      it 'uses provided name without relying on generated name data' do
        result = described_class.generate(
          location: location,
          place_type: :tavern,
          name: 'The Preassigned Inn'
        )

        expect(result[:success]).to eq(true)
        expect(result[:name]).to eq('The Preassigned Inn')
      end
    end

    context 'without location or coordinates' do
      it 'returns error' do
        result = described_class.generate(place_type: :tavern)

        expect(result[:success]).to be false
        expect(result[:errors]).to include('Either location or coordinates (longitude, latitude) must be provided')
      end
    end

    context 'with generate_rooms: true' do
      it 'generates room descriptions' do
        expect(described_class).to receive(:generate_room_descriptions)

        described_class.generate(
          location: location,
          place_type: :inn,
          generate_rooms: true
        )
      end
    end

    context 'with create_building: true' do
      before do
        allow(described_class).to receive(:create_building_rooms).and_return({
          building: double('Room', id: 1),
          rooms: [],
          errors: []
        })
      end

      it 'creates building rooms' do
        expect(described_class).to receive(:create_building_rooms)

        described_class.generate(
          location: location,
          place_type: :tavern,
          create_building: true
        )
      end
    end

    context 'with lot_bounds option' do
      let(:intersection) do
        double('Room', id: 10, grid_x: 2, grid_y: 3, street_name: 'Main Street')
      end

      before do
        building_room = double('Room', id: 100, min_x: 25, max_x: 95)
        allow(described_class).to receive(:create_building_rooms).and_wrap_original do |method, **args|
          # Verify lot_bounds flows through to create_building_rooms
          if args[:options] && args[:options][:lot_bounds]
            lot = args[:options][:lot_bounds]
            building = double('Room', id: 100, min_x: lot[:min_x], max_x: lot[:max_x])
            { building: building, rooms: [], errors: [] }
          else
            { building: double('Room', id: 100), rooms: [], errors: [] }
          end
        end
      end

      it 'passes lot_bounds through to building creation' do
        lot = { min_x: 25, max_x: 95, min_y: 25, max_y: 95, min_z: 0, max_z: 30 }
        result = described_class.generate(
          location: location,
          place_type: :blacksmith,
          parent_room: intersection,
          setting: :fantasy,
          create_building: true,
          options: { lot_bounds: lot }
        )

        expect(result[:success]).to be_truthy
        if result[:building]
          expect(result[:building].min_x).to eq(25)
          expect(result[:building].max_x).to eq(95)
        end
      end

      it 'uses lot_bounds dimensions for building footprint' do
        lot = { min_x: 50, max_x: 120, min_y: 50, max_y: 120, min_z: 0, max_z: 60 }

        expect(described_class).to receive(:create_building_rooms).with(
          hash_including(
            options: hash_including(lot_bounds: lot)
          )
        ).and_return({ building: double('Room', id: 101), rooms: [], errors: [] })

        described_class.generate(
          location: location,
          place_type: :tavern,
          parent_room: intersection,
          setting: :fantasy,
          create_building: true,
          options: { lot_bounds: lot }
        )
      end
    end

    context 'with generate_npcs: true' do
      before do
        allow(described_class).to receive(:generate_place_npcs).and_return({
          npcs: [{ role: 'innkeeper', name: 'Bob Smith' }],
          errors: []
        })
      end

      it 'generates NPCs' do
        result = described_class.generate(
          location: location,
          place_type: :tavern,
          generate_npcs: true
        )

        expect(result[:npcs]).to be_an(Array)
        expect(result[:npcs].first[:role]).to eq('innkeeper')
      end
    end

    context 'with generate_inventory: true for shop' do
      before do
        allow(described_class).to receive(:generate_shop_inventory).and_return({
          items: [{ category: :weapon, name: 'Iron Sword' }],
          error: nil
        })
      end

      it 'generates inventory for shop types' do
        result = described_class.generate(
          location: location,
          place_type: :blacksmith,
          generate_inventory: true
        )

        expect(result[:inventory]).to be_an(Array)
      end

      it 'does not generate inventory for non-shop types' do
        expect(described_class).not_to receive(:generate_shop_inventory)

        described_class.generate(
          location: location,
          place_type: :guild_hall,
          generate_inventory: true
        )
      end
    end
  end

  describe '.generate_name' do
    let(:name_options) do
      [
        double('ShopName', name: 'The Golden Goblet'),
        double('ShopName', name: 'The Rusty Anchor'),
        double('ShopName', name: 'The Wayward Inn')
      ]
    end

    before do
      allow(NameGeneratorService).to receive(:shop_options).and_return(name_options)
      allow(GenerationPipelineService).to receive(:select_best_name).and_return({
        selected: 'The Rusty Anchor',
        reasoning: 'Memorable and thematic'
      })
    end

    it 'returns selected name with alternatives' do
      result = described_class.generate_name(
        place_type: :tavern,
        setting: :fantasy,
        seed_terms: seed_terms
      )

      expect(result[:success]).to be true
      expect(result[:name]).to eq('The Rusty Anchor')
      expect(result[:alternatives]).to include('The Golden Goblet')
    end

    it 'includes LLM reasoning' do
      result = described_class.generate_name(place_type: :inn)

      expect(result[:reasoning]).to eq('Memorable and thematic')
    end

    context 'with no name options' do
      before do
        allow(NameGeneratorService).to receive(:shop_options).and_return([])
      end

      it 'returns error' do
        result = described_class.generate_name(place_type: :tavern)

        expect(result[:success]).to be false
        expect(result[:error]).to eq('No name options generated')
      end
    end

    context 'when name generation raises error' do
      before do
        allow(NameGeneratorService).to receive(:shop_options).and_raise(StandardError.new('Service error'))
      end

      it 'returns error' do
        result = described_class.generate_name(place_type: :blacksmith)

        expect(result[:success]).to be false
        expect(result[:error]).to include('Name generation failed')
      end
    end

    context 'when LLM selection fails' do
      before do
        allow(GenerationPipelineService).to receive(:select_best_name).and_return({
          selected: nil,
          reasoning: nil
        })
      end

      it 'falls back to first option' do
        result = described_class.generate_name(place_type: :tavern)

        expect(result[:success]).to be true
        expect(result[:name]).to eq('The Golden Goblet')
      end
    end
  end

  describe '.plan_layout' do
    let(:tavern_config) { described_class::PLACE_TYPES[:tavern] }

    it 'includes all required rooms' do
      layout = described_class.plan_layout(
        place_type: :tavern,
        config: tavern_config,
        size: :standard
      )

      room_types = layout.map { |r| r[:room_type] }
      expect(room_types).to include(*tavern_config[:rooms])
    end

    context 'with small size' do
      it 'includes no optional rooms' do
        layout = described_class.plan_layout(
          place_type: :tavern,
          config: tavern_config,
          size: :small
        )

        room_types = layout.map { |r| r[:room_type] }
        optional = tavern_config[:optional_rooms]

        expect(room_types & optional).to be_empty
      end
    end

    context 'with large size' do
      it 'includes all optional rooms' do
        layout = described_class.plan_layout(
          place_type: :tavern,
          config: tavern_config,
          size: :large
        )

        room_types = layout.map { |r| r[:room_type] }
        optional = tavern_config[:optional_rooms]

        expect(room_types).to include(*optional)
      end
    end

    it 'marks main rooms correctly' do
      layout = described_class.plan_layout(
        place_type: :tavern,
        config: tavern_config,
        size: :standard
      )

      main_room = layout.find { |r| r[:room_type] == 'common_room' }
      expect(main_room[:main_room]).to be true
    end

    it 'assigns floor numbers' do
      layout = described_class.plan_layout(
        place_type: :tavern,
        config: tavern_config,
        size: :large
      )

      cellar = layout.find { |r| r[:room_type] == 'cellar' }
      expect(cellar[:floor]).to eq(-1) if cellar

      guest_room = layout.find { |r| r[:room_type] == 'guest_room' }
      expect(guest_room[:floor]).to be >= 1 if guest_room
    end
  end

  describe '.generate_room_descriptions' do
    before do
      allow(Generators::RoomGeneratorService).to receive(:generate_description_for_type).and_return({
        success: true,
        content: 'A well-lit room with wooden furnishings.'
      })
    end

    it 'generates descriptions for each room in layout' do
      layout = [
        { room_type: 'common_room', floor: 0 },
        { room_type: 'kitchen', floor: 0 }
      ]

      result = described_class.generate_room_descriptions(
        place_name: 'The Rusty Anchor',
        place_type: :tavern,
        layout: layout,
        setting: :fantasy,
        seed_terms: seed_terms
      )

      expect(result[:descriptions]).to have_key('common_room')
      expect(result[:descriptions]).to have_key('kitchen')
    end

    context 'when description generation fails for a room' do
      before do
        allow(Generators::RoomGeneratorService).to receive(:generate_description_for_type).and_return({
          success: false,
          error: 'LLM unavailable'
        })
      end

      it 'collects errors' do
        layout = [{ room_type: 'common_room', floor: 0 }]

        result = described_class.generate_room_descriptions(
          place_name: 'Test',
          place_type: :tavern,
          layout: layout
        )

        expect(result[:errors]).not_to be_empty
      end
    end

    it 'records timeout errors when room generation threads do not finish in time' do
      stub_const('Generators::PlaceGeneratorService::ROOM_DESC_THREAD_TIMEOUT', 0.01)
      allow(Generators::RoomGeneratorService).to receive(:generate_description_for_type) do
        sleep 0.05
        { success: true, content: 'Late description' }
      end

      layout = [{ room_type: 'common_room', floor: 0 }]

      result = described_class.generate_room_descriptions(
        place_name: 'Slow Room',
        place_type: :tavern,
        layout: layout,
        setting: :fantasy
      )

      expect(result[:descriptions]).to be_empty
      expect(result[:errors].join).to include('timed out')
    end
  end

  describe '.generate_place_npcs' do
    before do
      allow(Generators::NPCGeneratorService).to receive(:generate).and_return({
        success: true,
        name: { full_name: 'Bob Smith' },
        appearance: 'A friendly face',
        personality: 'Warm and welcoming',
        schedule: []
      })
    end

    it 'generates NPCs for each role' do
      result = described_class.generate_place_npcs(
        place_name: 'The Rusty Anchor',
        place_type: :tavern,
        npc_roles: %w[innkeeper barkeep],
        location: location,
        setting: :fantasy
      )

      expect(result[:npcs].length).to eq(2)
      expect(result[:npcs].first[:role]).to eq('innkeeper')
    end

    context 'when NPC generation fails' do
      before do
        allow(Generators::NPCGeneratorService).to receive(:generate).and_return({
          success: false,
          errors: ['Generation failed']
        })
      end

      it 'collects errors' do
        result = described_class.generate_place_npcs(
          place_name: 'Test',
          place_type: :tavern,
          npc_roles: %w[innkeeper],
          location: location
        )

        expect(result[:errors]).not_to be_empty
      end
    end
  end

  describe '.generate_shop_inventory' do
    let!(:weapon_type) { create(:unified_object_type, name: 'Sword', category: 'Sword') }
    let!(:consumable_type) { create(:unified_object_type, name: 'Consumable', category: 'consumable') }
    let!(:weapon_pattern) do
      create(:pattern,
             description: 'A sturdy iron sword',
             unified_object_type: weapon_type,
             price: 50)
    end
    let!(:consumable_pattern) do
      create(:pattern,
             description: 'A healing potion',
             unified_object_type: consumable_type,
             price: 10)
    end

    it 'generates items for blacksmith shop from weapon patterns' do
      result = described_class.generate_shop_inventory(
        shop_type: :blacksmith,
        place_name: 'Smithy',
        setting: :fantasy,
        persist: false
      )

      expect(result[:items]).to be_an(Array)
      expect(result[:items]).not_to be_empty
      expect(result[:items].first[:pattern_id]).to eq(weapon_pattern.id)
    end

    it 'generates items for apothecary shop from consumable patterns' do
      result = described_class.generate_shop_inventory(
        shop_type: :apothecary,
        place_name: 'Potion Shop',
        setting: :fantasy,
        persist: false
      )

      expect(result[:items]).to be_an(Array)
      expect(result[:items]).not_to be_empty
      expect(result[:items].first[:pattern_id]).to eq(consumable_pattern.id)
    end

    context 'when no patterns exist for shop type' do
      it 'returns an error' do
        # Delete all weapon patterns (those with Sword/Knife/Firearm categories)
        weapon_categories = %w[Sword Knife Firearm]
        weapon_type_ids = UnifiedObjectType.where(category: weapon_categories).select(:id)
        Pattern.where(unified_object_type_id: weapon_type_ids).delete

        result = described_class.generate_shop_inventory(
          shop_type: :blacksmith,
          place_name: 'Test',
          persist: false
        )

        expect(result[:errors]).to include(/No patterns found/)
      end
    end

    context 'when persisting to database' do
      let(:zone) { create(:zone) }
      let(:location) { create(:location, zone: zone) }
      let(:room) { create(:room, location: location) }

      it 'creates Shop and ShopItem records' do
        result = described_class.generate_shop_inventory(
          shop_type: :blacksmith,
          place_name: 'Iron Works',
          room: room,
          persist: true
        )

        expect(result[:shop]).to be_a(Shop)
        expect(result[:shop].name).to eq('Iron Works')
        expect(result[:shop].room_id).to eq(room.id)
        expect(ShopItem.where(shop_id: result[:shop].id).count).to be > 0
      end

      it 'does not duplicate shop if one exists' do
        existing_shop = Shop.create(room_id: room.id, name: 'Existing Shop', is_open: true)

        result = described_class.generate_shop_inventory(
          shop_type: :blacksmith,
          place_name: 'New Name',
          room: room,
          persist: true
        )

        expect(result[:shop].id).to eq(existing_shop.id)
        expect(Shop.where(room_id: room.id).count).to eq(1)
      end
    end
  end

  describe '.create_building_rooms' do
    let(:parent_room) do
      double('Room',
             id: 1,
             grid_x: 5,
             grid_y: 10,
             street_name: 'Main Street')
    end
    let(:building_room) { double('Room', id: 100) }
    let(:interior_room) { double('Room', id: 101) }

    before do
      allow(BlockBuilderService).to receive(:create_building).and_return(building_room)
      allow(building_room).to receive(:update)
      allow(Room).to receive(:create).and_return(interior_room)
    end

    it 'creates building via BlockBuilderService' do
      layout = [{ room_type: 'common_room', floor: 0, position: 0 }]

      result = described_class.create_building_rooms(
        location: location,
        parent_room: parent_room,
        place_name: 'The Rusty Anchor',
        place_type: :tavern,
        layout: layout,
        room_descriptions: {},
        setting: :fantasy,
        options: {}
      )

      expect(result[:building]).to eq(building_room)
    end

    it 'creates interior rooms (including hallway from FloorPlanService)' do
      layout = [
        { room_type: 'common_room', floor: 0, position: 0 },
        { room_type: 'kitchen', floor: 0, position: 1 }
      ]

      result = described_class.create_building_rooms(
        location: location,
        parent_room: parent_room,
        place_name: 'Test',
        place_type: :tavern,
        layout: layout,
        room_descriptions: {},
        setting: :fantasy,
        options: {}
      )

      # FloorPlanService BSP layout generates a corridor + 2 rooms = 3 total
      expect(result[:rooms].length).to eq(3)
    end

    context 'without parent room' do
      it 'uses simple bounds' do
        layout = [{ room_type: 'common_room', floor: 0, position: 0 }]

        result = described_class.create_building_rooms(
          location: location,
          parent_room: nil,
          place_name: 'Test',
          place_type: :tavern,
          layout: layout,
          room_descriptions: {},
          setting: :fantasy,
          options: {}
        )

        expect(result[:building]).to eq(building_room)
      end
    end

    context 'when building creation fails' do
      before do
        allow(BlockBuilderService).to receive(:create_building).and_raise(StandardError.new('DB error'))
      end

      it 'returns error' do
        layout = [{ room_type: 'common_room', floor: 0, position: 0 }]

        result = described_class.create_building_rooms(
          location: location,
          parent_room: parent_room,
          place_name: 'Test',
          place_type: :tavern,
          layout: layout,
          room_descriptions: {},
          setting: :fantasy,
          options: {}
        )

        expect(result[:errors]).to include('Building creation failed: DB error')
      end
    end

    it 'uses generated descriptions when available' do
      layout = [{ room_type: 'common_room', floor: 0, position: 0 }]
      descriptions = { 'common_room' => 'A bustling tavern room' }

      expect(Room).to receive(:create).with(
        hash_including(long_description: 'A bustling tavern room')
      )

      described_class.create_building_rooms(
        location: location,
        parent_room: parent_room,
        place_name: 'Test',
        place_type: :tavern,
        layout: layout,
        room_descriptions: descriptions,
        setting: :fantasy,
        options: {}
      )
    end
  end

  describe 'PLACE_TYPES constant' do
    it 'has tavern configuration' do
      expect(described_class::PLACE_TYPES[:tavern]).to be_a(Hash)
      expect(described_class::PLACE_TYPES[:tavern][:rooms]).to include('common_room')
    end

    it 'has shop types with shop_type set' do
      expect(described_class::PLACE_TYPES[:blacksmith][:shop_type]).to eq(:blacksmith)
      expect(described_class::PLACE_TYPES[:jeweler][:shop_type]).to eq(:jeweler)
    end

    it 'has civic buildings without shop_type' do
      expect(described_class::PLACE_TYPES[:guild_hall][:shop_type]).to be_nil
      expect(described_class::PLACE_TYPES[:temple][:shop_type]).to be_nil
    end

    it 'has npc_roles for all place types' do
      described_class::PLACE_TYPES.each do |type, config|
        expect(config[:npc_roles]).to be_an(Array), "#{type} missing npc_roles"
      end
    end
  end

  describe 'BUILDING_TYPE_MAP constant' do
    it 'maps all place types to building types' do
      described_class::PLACE_TYPES.keys.each do |place_type|
        expect(described_class::BUILDING_TYPE_MAP).to have_key(place_type)
      end
    end

    it 'maps tavern to bar' do
      expect(described_class::BUILDING_TYPE_MAP[:tavern]).to eq(:bar)
    end

    it 'maps shops to shop' do
      expect(described_class::BUILDING_TYPE_MAP[:blacksmith]).to eq(:shop)
      expect(described_class::BUILDING_TYPE_MAP[:clothier]).to eq(:shop)
    end
  end

  describe 'private methods' do
    describe '.calculate_floor' do
      it 'puts cellar underground' do
        floor = described_class.send(:calculate_floor, 'cellar', 0, 5)
        expect(floor).to eq(-1)
      end

      it 'puts basement underground' do
        floor = described_class.send(:calculate_floor, 'basement', 0, 5)
        expect(floor).to eq(-1)
      end

      it 'puts guest_room upstairs' do
        floor = described_class.send(:calculate_floor, 'guest_room', 0, 5)
        expect(floor).to be >= 1
      end

      it 'puts common_room on ground floor' do
        floor = described_class.send(:calculate_floor, 'common_room', 0, 5)
        expect(floor).to eq(0)
      end
    end

    describe '.map_to_room_type' do
      it 'maps common_room to bar' do
        expect(described_class.send(:map_to_room_type, 'common_room')).to eq('bar')
      end

      it 'maps forge to factory' do
        expect(described_class.send(:map_to_room_type, 'forge')).to eq('factory')
      end

      it 'returns standard for unknown types' do
        expect(described_class.send(:map_to_room_type, 'unknown_room')).to eq('standard')
      end
    end

    describe '.shop_inventory_categories' do
      it 'returns weapon and misc for blacksmith' do
        categories = described_class.send(:shop_inventory_categories, :blacksmith)
        expect(categories).to eq(%i[weapon misc])
      end

      it 'returns consumable and misc for apothecary' do
        categories = described_class.send(:shop_inventory_categories, :apothecary)
        expect(categories).to eq(%i[consumable misc])
      end

      it 'returns misc for unknown types' do
        categories = described_class.send(:shop_inventory_categories, :unknown)
        expect(categories).to eq(%i[misc])
      end
    end

    describe '.generate_simple_room_description' do
      it 'generates common_room description' do
        desc = described_class.send(:generate_simple_room_description,
                                    room_type: 'common_room',
                                    place_type: :tavern,
                                    setting: :fantasy)
        expect(desc).to include('bustling')
      end

      it 'generates kitchen description' do
        desc = described_class.send(:generate_simple_room_description,
                                    room_type: 'kitchen',
                                    place_type: :tavern,
                                    setting: :fantasy)
        expect(desc).to include('kitchen')
      end

      it 'generates forge description' do
        desc = described_class.send(:generate_simple_room_description,
                                    room_type: 'forge',
                                    place_type: :blacksmith,
                                    setting: :fantasy)
        expect(desc).to include('forge')
      end

      it 'generates fallback for unknown room types' do
        desc = described_class.send(:generate_simple_room_description,
                                    room_type: 'strange_room',
                                    place_type: :tavern,
                                    setting: :fantasy)
        expect(desc).to include('strange room')
      end
    end
  end
end
