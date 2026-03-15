# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BuildingNavigationService do
  let(:location) { create(:location) }

  # Create a street room - positioned at y: 0-100
  let(:street) { create(:room, location: location, room_type: 'street', name: 'Main Street', is_outdoor: true, min_x: 0, max_x: 100, min_y: 0, max_y: 100) }

  # Create a building adjacent to the street (south of street, y: 100-200)
  # They share an edge at y=100, making them spatially adjacent
  let(:building) { create(:room, location: location, room_type: 'building', name: 'Tower Block', min_x: 0, max_x: 100, min_y: 100, max_y: 200) }
  # Nested rooms must have bounds within their parent
  let(:lobby) { create(:room, location: location, room_type: 'hallway', name: 'Lobby', inside_room_id: building.id, min_x: 10, max_x: 90, min_y: 110, max_y: 150) }
  let(:apartment) { create(:room, location: location, room_type: 'apartment', name: 'Unit 1A', inside_room_id: lobby.id, min_x: 20, max_x: 80, min_y: 120, max_y: 140) }

  # Ensure building and street are created (spatial adjacency replaces room_exit)
  before do
    street
    building
  end

  # outdoor_room? and indoor_room? have been removed from BuildingNavigationService.
  # Outdoor detection is now handled by Room#outdoor_room? (see spec/models/room_spec.rb).

  describe '.find_outer_building' do
    it 'returns nil for outdoor rooms' do
      expect(described_class.find_outer_building(street)).to be_nil
    end

    it 'returns nil for nil room' do
      expect(described_class.find_outer_building(nil)).to be_nil
    end

    it 'returns the building itself when room is top-level building' do
      expect(described_class.find_outer_building(building)).to eq(building)
    end

    it 'returns outer building for nested room' do
      expect(described_class.find_outer_building(lobby)).to eq(building)
    end

    it 'returns outermost building for deeply nested room' do
      expect(described_class.find_outer_building(apartment)).to eq(building)
    end
  end

  describe '.find_building_exit' do
    it 'returns the room itself for outdoor rooms' do
      expect(described_class.find_building_exit(street)).to eq(street)
    end

    it 'returns the room with exit to outdoor' do
      expect(described_class.find_building_exit(building)).to eq(building)
    end

    it 'finds exit from nested room' do
      # With spatial adjacency, the lobby is inside the building (via inside_room)
      # and the building is adjacent to the street, so we can find the exit path
      result = described_class.find_building_exit(lobby)
      # Should find either lobby or building (which leads to street via spatial adjacency)
      expect([lobby, building]).to include(result)
    end
  end

  describe '.find_nearest_street' do
    it 'returns the room itself for outdoor rooms' do
      expect(described_class.find_nearest_street(street)).to eq(street)
    end

    it 'returns nil when no street is connected' do
      isolated = create(:room, room_type: 'apartment', name: 'Isolated Room')
      expect(described_class.find_nearest_street(isolated)).to be_nil
    end

    it 'finds street from connected building' do
      expect(described_class.find_nearest_street(building)).to eq(street)
    end
  end

  describe '.path_to_street' do
    it 'returns empty array for outdoor rooms' do
      expect(described_class.path_to_street(street)).to eq([])
    end

    it 'returns empty array for nil room' do
      expect(described_class.path_to_street(nil)).to eq([])
    end

    it 'returns path of exits to reach street' do
      path = described_class.path_to_street(building)
      expect(path).to be_an(Array)
      expect(path.length).to eq(1)
      # With spatial adjacency, path returns hashes with :room key
      expect(path.first[:room]).to eq(street)
    end
  end

  describe '.same_building?' do
    it 'returns false for nil rooms' do
      expect(described_class.same_building?(nil, building)).to be false
      expect(described_class.same_building?(building, nil)).to be false
    end

    it 'returns true for two outdoor rooms' do
      plaza = create(:room, room_type: 'plaza', name: 'Plaza')
      expect(described_class.same_building?(street, plaza)).to be true
    end

    it 'returns true for rooms in same building' do
      expect(described_class.same_building?(building, lobby)).to be true
      expect(described_class.same_building?(lobby, apartment)).to be true
    end

    it 'returns false for rooms in different buildings' do
      other_building = create(:room, room_type: 'building', name: 'Other Tower')
      expect(described_class.same_building?(building, other_building)).to be false
    end
  end

  describe '.building_name' do
    it 'returns nil for outdoor rooms' do
      expect(described_class.building_name(street)).to be_nil
    end

    it 'returns nil for nil room' do
      expect(described_class.building_name(nil)).to be_nil
    end

    it 'returns building name for top-level building' do
      expect(described_class.building_name(building)).to eq('Tower Block')
    end

    it 'returns outer building name for nested room' do
      expect(described_class.building_name(apartment)).to eq('Tower Block')
    end
  end

  describe '.find_path_to_condition' do
    it 'returns empty for nil room' do
      expect(described_class.find_path_to_condition(nil) { true }).to eq([])
    end

    it 'returns empty when no block given' do
      expect(described_class.find_path_to_condition(building)).to eq([])
    end

    it 'finds path to room matching condition' do
      path = described_class.find_path_to_condition(building) { |room| room.room_type == 'street' }
      expect(path.length).to eq(1)
      # With spatial adjacency, path returns hashes with :room key
      expect(path.first[:room]).to eq(street)
    end

    it 'respects max_depth limit' do
      # Create a long chain
      path = described_class.find_path_to_condition(building, max_depth: 0) { |_| true }
      expect(path).to eq([])
    end
  end

  describe '.path_into_building' do
    it 'returns empty for nil rooms' do
      expect(described_class.path_into_building(nil, building)).to eq([])
      expect(described_class.path_into_building(street, nil)).to eq([])
    end

    it 'returns empty for same room' do
      expect(described_class.path_into_building(street, street)).to eq([])
    end

    it 'delegates to PathfindingService' do
      # This method delegates to PathfindingService, so we just verify it doesn't crash
      result = described_class.path_into_building(street, building)
      expect(result).to be_an(Array)
    end
  end
end
