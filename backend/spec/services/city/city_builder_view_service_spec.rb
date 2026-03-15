# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CityBuilderViewService do
  let(:world) { create(:world) }
  let(:location) { create(:location, world: world, horizontal_streets: 5, vertical_streets: 5) }

  describe '.city_data' do
    it 'returns location metadata' do
      result = described_class.city_data(location)
      expect(result[:location_id]).to eq(location.id)
      expect(result[:world_id]).to eq(world.id)
    end

    it 'returns grid info' do
      result = described_class.city_data(location)
      expect(result[:grid]).to be_a(Hash)
      expect(result[:grid][:horizontal_streets]).to eq(5)
      expect(result[:grid][:vertical_streets]).to eq(5)
    end

    it 'includes cell size and street width' do
      result = described_class.city_data(location)
      expect(result[:grid][:cell_size]).to eq(GridCalculationService::GRID_CELL_SIZE)
      expect(result[:grid][:street_width]).to eq(GridCalculationService::STREET_WIDTH)
    end

    it 'returns empty arrays for no streets/avenues/intersections' do
      result = described_class.city_data(location)
      expect(result[:streets]).to eq([])
      expect(result[:avenues]).to eq([])
      expect(result[:intersections]).to eq([])
    end

    it 'returns buildings array' do
      result = described_class.city_data(location)
      expect(result[:buildings]).to eq([])
    end

    context 'with city rooms' do
      let!(:street) { create(:room, location: location, city_role: 'street', name: 'Main St') }
      let!(:avenue) { create(:room, location: location, city_role: 'avenue', name: 'First Ave') }
      let!(:intersection) { create(:room, location: location, city_role: 'intersection', grid_x: 0, grid_y: 0) }

      it 'includes streets' do
        result = described_class.city_data(location)
        expect(result[:streets].length).to eq(1)
        expect(result[:streets].first[:name]).to eq('Main St')
      end

      it 'includes avenues' do
        result = described_class.city_data(location)
        expect(result[:avenues].length).to eq(1)
        expect(result[:avenues].first[:name]).to eq('First Ave')
      end

      it 'includes intersections' do
        result = described_class.city_data(location)
        expect(result[:intersections].length).to eq(1)
      end
    end

    context 'with buildings' do
      let!(:building) { create(:room, location: location, city_role: 'building', room_type: 'building', grid_x: 0, grid_y: 0, building_type: 'house') }

      it 'includes buildings' do
        result = described_class.city_data(location)
        expect(result[:buildings].length).to eq(1)
        expect(result[:buildings].first[:building_type]).to eq('house')
      end

      it 'includes room count' do
        create(:room, location: location, inside_room_id: building.id)
        create(:room, location: location, inside_room_id: building.id)
        result = described_class.city_data(location)
        expect(result[:buildings].first[:room_count]).to eq(2)
      end
    end

    it 'returns blocks data' do
      result = described_class.city_data(location)
      expect(result[:blocks]).to be_an(Array)
      # For 5x5 grid, there are 4x4 = 16 blocks
      expect(result[:blocks].length).to eq(16)
    end

    it 'marks blocks with buildings' do
      create(:room, location: location, city_role: 'building', grid_x: 1, grid_y: 1)
      result = described_class.city_data(location)
      block = result[:blocks].find { |b| b[:grid_x] == 1 && b[:grid_y] == 1 }
      expect(block[:has_building]).to be true
    end
  end

  describe '.create_building' do
    let!(:intersection) { create(:room, location: location, city_role: 'intersection', grid_x: 1, grid_y: 1) }

    # The mock creates the building when called, not during setup
    # This prevents the "already exists" check from finding it prematurely
    before do
      allow(BlockBuilderService).to receive(:build_block) do |**_args|
        [create(:room, location: location, city_role: 'building', grid_x: 1, grid_y: 1)]
      end
    end

    it 'returns success with building data' do
      result = described_class.create_building(location, { 'grid_x' => 1, 'grid_y' => 1, 'building_type' => 'house' })
      expect(result[:success]).to be true
      expect(result[:building]).to be_a(Hash)
    end

    it 'returns total room count' do
      result = described_class.create_building(location, { 'grid_x' => 1, 'grid_y' => 1 })
      expect(result[:total_rooms]).to eq(1)
    end

    context 'when intersection not found' do
      it 'returns error' do
        result = described_class.create_building(location, { 'grid_x' => 99, 'grid_y' => 99 })
        expect(result[:success]).to be false
        expect(result[:error]).to include('no intersection')
      end
    end

    context 'when building already exists' do
      before do
        create(:room, location: location, city_role: 'building', grid_x: 1, grid_y: 1)
      end

      it 'returns error' do
        result = described_class.create_building(location, { 'grid_x' => 1, 'grid_y' => 1 })
        expect(result[:success]).to be false
        expect(result[:error]).to include('already exists')
      end
    end

    context 'when BlockBuilderService returns empty' do
      let!(:intersection2) { create(:room, location: location, city_role: 'intersection', grid_x: 2, grid_y: 2) }

      before do
        allow(BlockBuilderService).to receive(:build_block).and_return([])
      end

      it 'returns error' do
        result = described_class.create_building(location, { 'grid_x' => 2, 'grid_y' => 2 })
        expect(result[:success]).to be false
        expect(result[:error]).to include('Failed')
      end
    end

    context 'when exception occurs' do
      let!(:intersection3) { create(:room, location: location, city_role: 'intersection', grid_x: 3, grid_y: 3) }

      before do
        allow(BlockBuilderService).to receive(:build_block).and_raise(StandardError.new('Test error'))
      end

      it 'returns error' do
        result = described_class.create_building(location, { 'grid_x' => 3, 'grid_y' => 3 })
        expect(result[:success]).to be false
        expect(result[:error]).to eq('Test error')
      end
    end
  end

  describe '.delete_building' do
    let!(:building) { create(:room, location: location, city_role: 'building') }

    it 'deletes the building' do
      result = described_class.delete_building(building.id)
      expect(result[:success]).to be true
      expect(Room[building.id]).to be_nil
    end

    it 'deletes interior rooms' do
      interior1 = create(:room, location: location, inside_room_id: building.id)
      interior2 = create(:room, location: location, inside_room_id: building.id)

      result = described_class.delete_building(building.id)
      expect(result[:success]).to be true
      expect(result[:deleted_rooms]).to eq(3) # 2 interior + 1 building
      expect(Room[interior1.id]).to be_nil
      expect(Room[interior2.id]).to be_nil
    end

    context 'when building not found' do
      it 'returns error' do
        result = described_class.delete_building(999999)
        expect(result[:success]).to be false
        expect(result[:error]).to include('not found')
      end
    end

    context 'when room is not a building' do
      let!(:street) { create(:room, location: location, city_role: 'street') }

      it 'returns error' do
        result = described_class.delete_building(street.id)
        expect(result[:success]).to be false
        expect(result[:error]).to include('Not a building')
      end
    end

    context 'when building belongs to a different city' do
      let!(:other_location) { create(:location) }
      let!(:other_building) { create(:room, location: other_location, city_role: 'building') }

      it 'returns not found in this city' do
        result = described_class.delete_building(other_building.id, location: location)
        expect(result[:success]).to be false
        expect(result[:error]).to include('not found in this city')
      end
    end
  end

  describe '.building_types_by_category' do
    before do
      allow(GridCalculationService).to receive(:all_building_types).and_return({
        house: { category: :residential, floors: 2, height: 20, per_block: 4 },
        apartment_tower: { category: :residential, floors: 20, height: 200, per_block: 1 },
        shop: { category: :commercial, floors: 1, height: 15, per_block: 4 }
      })
    end

    it 'returns building types grouped by category' do
      result = described_class.building_types_by_category
      expect(result.keys).to include(:residential, :commercial)
    end

    it 'includes building details' do
      result = described_class.building_types_by_category
      house = result[:residential].find { |b| b[:name] == :house }
      expect(house[:floors]).to eq(2)
      expect(house[:height]).to eq(20)
    end

    it 'formats display name' do
      result = described_class.building_types_by_category
      apt = result[:residential].find { |b| b[:name] == :apartment_tower }
      expect(apt[:display_name]).to eq('Apartment Tower')
    end
  end
end
