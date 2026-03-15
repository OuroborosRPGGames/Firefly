# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RoomPolygonService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:zone) { create(:zone, world: world, polygon_points: nil) }  # No polygon by default
  let(:location) { create(:location, zone: zone, city_name: 'Test City', globe_hex_id: 1, latitude: 10.0, longitude: 10.0, world_id: world.id) }

  # Don't use let! because we need to control room creation order relative to zone polygon setup
  # Rooms will be created in each test context as needed

  describe '.recalculate_location' do
    context 'when zone has no polygon' do
      it 'returns zeros and does not modify rooms' do
        # Create a room first (no polygon to trigger deletion)
        create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)

        result = described_class.recalculate_location(location)
        expect(result).to eq({ kept: 0, deleted: 0, relocated_characters: 0, relocated_items: 0 })
      end
    end

    context 'when zone has a polygon' do
      # Create rooms AFTER setting up polygon to avoid automatic deletion by Zone.after_save
      let(:room_inside) { create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100) }
      let(:room_outside) { create(:room, location: location, min_x: 50_000, max_x: 50_100, min_y: 50_000, max_y: 50_100) }

      before do
        # Set up polygon FIRST (before creating rooms)
        # Use local-scale polygon in feet coordinates (much simpler)
        # This polygon covers roughly 0-500 feet in each direction
        zone.update(
          polygon_scale: 'local',
          polygon_points: [
            { 'x' => 0, 'y' => 0 },
            { 'x' => 500, 'y' => 0 },
            { 'x' => 500, 'y' => 500 },
            { 'x' => 0, 'y' => 500 }
          ]
        )
        # Refresh location to pick up zone changes (Sequel caches associations)
        location.refresh
      end

      it 'keeps rooms inside polygon' do
        room_inside  # Create room after polygon is set

        result = described_class.recalculate_location(location)

        expect(Room.where(id: room_inside.id).count).to eq(1)
        expect(result[:kept]).to eq(1)
      end

      it 'deletes rooms outside polygon' do
        # Create both rooms after polygon is set
        room_inside
        room_outside

        result = described_class.recalculate_location(location)

        expect(Room.where(id: room_outside.id).count).to eq(0)
        expect(result[:deleted]).to eq(1)
      end

      it 'returns counts of kept and deleted rooms' do
        # Create both rooms after polygon is set
        room_inside
        room_outside

        result = described_class.recalculate_location(location)

        expect(result[:kept]).to eq(1)
        expect(result[:deleted]).to eq(1)
      end
    end
  end

  describe '.mark_rooms_for_location' do
    context 'when zone has no polygon' do
      it 'returns backward-compatible format with zeros' do
        create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)

        result = described_class.mark_rooms_for_location(location)
        expect(result).to eq({ inside: 0, outside: 0 })
      end
    end

    context 'when zone has a polygon' do
      let(:room_inside) { create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100) }
      let(:room_outside) { create(:room, location: location, min_x: 50_000, max_x: 50_100, min_y: 50_000, max_y: 50_100) }

      before do
        zone.update(
          polygon_scale: 'local',
          polygon_points: [
            { 'x' => 0, 'y' => 0 },
            { 'x' => 500, 'y' => 0 },
            { 'x' => 500, 'y' => 500 },
            { 'x' => 0, 'y' => 500 }
          ]
        )
        location.refresh
      end

      it 'returns backward-compatible counts' do
        room_inside
        room_outside

        result = described_class.mark_rooms_for_location(location)

        expect(result[:inside]).to eq(1)
        expect(result[:outside]).to eq(1)
      end
    end
  end

  describe '.recalculate_zone' do
    let(:location2) { create(:location, zone: zone, city_name: 'City 2', globe_hex_id: 2, latitude: 10.0, longitude: 10.0, world_id: world.id) }

    before do
      # Set up polygon first
      zone.update(
        polygon_scale: 'local',
        polygon_points: [
          { 'x' => 0, 'y' => 0 },
          { 'x' => 500, 'y' => 0 },
          { 'x' => 500, 'y' => 500 },
          { 'x' => 0, 'y' => 500 }
        ]
      )
      location.refresh
    end

    it 'processes all city locations in the zone' do
      # Create rooms AFTER polygon is set
      create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      location2  # Trigger location2 creation
      location2.refresh
      create(:room, location: location2, min_x: 0, max_x: 100, min_y: 0, max_y: 100)

      result = described_class.recalculate_zone(zone)

      expect(result[:locations]).to eq(2)
      expect(result[:kept]).to eq(2)
      # Backward-compatible aliases
      expect(result[:inside]).to eq(result[:kept])
      expect(result[:outside]).to eq(result[:deleted])
    end
  end

  describe '.grid_position_accessible?' do
    before do
      # Local-scale polygon covering roughly 0-500 feet
      zone.update(
        polygon_scale: 'local',
        polygon_points: [
          { 'x' => 0, 'y' => 0 },
          { 'x' => 500, 'y' => 0 },
          { 'x' => 500, 'y' => 500 },
          { 'x' => 0, 'y' => 500 }
        ]
      )
      location.refresh
    end

    it 'returns true for positions inside polygon' do
      expect(described_class.grid_position_accessible?(location, 0, 0)).to be true
    end

    it 'returns false for positions outside polygon' do
      # Very far away grid position (grid cell 1000 would be ~175,000 feet)
      expect(described_class.grid_position_accessible?(location, 1000, 1000)).to be false
    end

    it 'returns true when zone has no polygon' do
      zone.update(polygon_points: [])

      expect(described_class.grid_position_accessible?(location, 1000, 1000)).to be true
    end
  end

  describe '.grid_accessibility_stats' do
    before do
      location.update(vertical_streets: 10, horizontal_streets: 10)
      # Local-scale polygon covering just a small corner
      zone.update(
        polygon_scale: 'local',
        polygon_points: [
          { 'x' => 0, 'y' => 0 },
          { 'x' => 500, 'y' => 0 },
          { 'x' => 500, 'y' => 500 },
          { 'x' => 0, 'y' => 500 }
        ]
      )
      location.refresh
    end

    it 'returns statistics about grid accessibility' do
      stats = described_class.grid_accessibility_stats(location)

      expect(stats[:total]).to eq(100)
      expect(stats[:accessible]).to be_between(1, 100)
      expect(stats[:inaccessible]).to eq(stats[:total] - stats[:accessible])
      expect(stats[:percentage]).to be_a(Float)
    end

    it 'returns 100% when no polygon' do
      zone.update(polygon_points: [])

      stats = described_class.grid_accessibility_stats(location)
      expect(stats[:percentage]).to eq(100)
    end
  end

  describe '.can_create_room?' do
    before do
      zone.update(
        polygon_scale: 'local',
        polygon_points: [
          { 'x' => 0, 'y' => 0 },
          { 'x' => 500, 'y' => 0 },
          { 'x' => 500, 'y' => 500 },
          { 'x' => 0, 'y' => 500 }
        ]
      )
      location.refresh
    end

    it 'returns true for room bounds inside polygon' do
      result = described_class.can_create_room?(location, min_x: 0, max_x: 100, min_y: 0, max_y: 100)
      expect(result).to be true
    end

    it 'returns false for room bounds outside polygon' do
      result = described_class.can_create_room?(location, min_x: 100_000, max_x: 100_100, min_y: 100_000, max_y: 100_100)
      expect(result).to be false
    end

    it 'returns true when zone has no polygon' do
      zone.update(polygon_points: [])

      result = described_class.can_create_room?(location, min_x: 100_000, max_x: 100_100, min_y: 100_000, max_y: 100_100)
      expect(result).to be true
    end
  end

  describe '.relocate_room_contents' do
    let(:source_room) do
      create(:room, location: location, min_x: 50_000, max_x: 50_100, min_y: 50_000, max_y: 50_100)
    end
    let(:target_room) do
      create(:room, location: location, min_x: 200, max_x: 300, min_y: 200, max_y: 300, usable_percentage: 1.0)
    end

    let(:user) { create(:user) }
    let(:character) { create(:character, user: user) }

    it 'relocates characters to nearest valid room' do
      # Create target room first (so it's a valid relocation target)
      target_room

      # Create source room and put a character in it
      source_room
      character_instance = create(:character_instance, character: character, current_room: source_room, x: 50_050, y: 50_050)

      result = described_class.relocate_room_contents(source_room, location)

      expect(result[:characters]).to eq(1)
      character_instance.refresh
      expect(character_instance.current_room_id).to eq(target_room.id)
    end

    it 'returns counts of relocated entities' do
      target_room
      source_room
      create(:character_instance, character: character, current_room: source_room, x: 50_050, y: 50_050)

      result = described_class.relocate_room_contents(source_room, location)

      expect(result[:characters]).to be >= 0
      expect(result[:items]).to be >= 0
    end
  end

  describe '.reset_location_polygon_status' do
    let!(:room) do
      create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100,
        effective_polygon: Sequel.pg_jsonb_wrap([{ x: 0, y: 0 }, { x: 50, y: 0 }, { x: 50, y: 50 }]),
        effective_area: 1250.0,
        usable_percentage: 0.5
      )
    end

    it 'clears effective polygon and resets usable percentage' do
      described_class.reset_location_polygon_status(location)

      room.refresh
      expect(room.effective_polygon).to be_nil
      expect(room.effective_area).to be_nil
      expect(room.usable_percentage).to eq(1.0)
    end
  end
end
