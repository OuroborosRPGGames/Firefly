# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PolygonClippingService do
  describe '.sutherland_hodgman_clip' do
    context 'with non-overlapping polygons' do
      it 'returns empty array when polygons do not intersect' do
        square = [
          { x: 0, y: 0 },
          { x: 10, y: 0 },
          { x: 10, y: 10 },
          { x: 0, y: 10 }
        ]
        distant_square = [
          { x: 100, y: 100 },
          { x: 110, y: 100 },
          { x: 110, y: 110 },
          { x: 100, y: 110 }
        ]

        result = described_class.sutherland_hodgman_clip(square, distant_square)
        expect(result).to be_empty
      end
    end

    context 'with fully overlapping polygons' do
      it 'returns the subject when it is inside the clip polygon' do
        small_square = [
          { x: 2, y: 2 },
          { x: 8, y: 2 },
          { x: 8, y: 8 },
          { x: 2, y: 8 }
        ]
        large_square = [
          { x: 0, y: 0 },
          { x: 10, y: 0 },
          { x: 10, y: 10 },
          { x: 0, y: 10 }
        ]

        result = described_class.sutherland_hodgman_clip(small_square, large_square)

        expect(result.length).to eq(4)
        expect(described_class.polygon_area(result)).to be_within(0.1).of(36.0) # 6x6 = 36
      end
    end

    context 'with partially overlapping polygons' do
      it 'returns the intersection polygon' do
        square1 = [
          { x: 0, y: 0 },
          { x: 10, y: 0 },
          { x: 10, y: 10 },
          { x: 0, y: 10 }
        ]
        square2 = [
          { x: 5, y: 5 },
          { x: 15, y: 5 },
          { x: 15, y: 15 },
          { x: 5, y: 15 }
        ]

        result = described_class.sutherland_hodgman_clip(square1, square2)

        # Intersection should be a 5x5 square from (5,5) to (10,10)
        expect(result).not_to be_empty
        expect(described_class.polygon_area(result)).to be_within(0.1).of(25.0)
      end
    end

    context 'with triangle clipping a square' do
      it 'returns a triangular or trapezoidal intersection' do
        square = [
          { x: 0, y: 0 },
          { x: 100, y: 0 },
          { x: 100, y: 100 },
          { x: 0, y: 100 }
        ]
        triangle = [
          { x: 0, y: 0 },
          { x: 100, y: 0 },
          { x: 50, y: 100 }
        ]

        result = described_class.sutherland_hodgman_clip(square, triangle)

        expect(result).not_to be_empty
        # Triangle area = 0.5 * 100 * 100 = 5000
        expect(described_class.polygon_area(result)).to be_within(1.0).of(5000.0)
      end
    end

    context 'with string keys in polygon' do
      it 'handles string keys correctly' do
        square = [
          { 'x' => 0, 'y' => 0 },
          { 'x' => 10, 'y' => 0 },
          { 'x' => 10, 'y' => 10 },
          { 'x' => 0, 'y' => 10 }
        ]
        clip = [
          { 'x' => 0, 'y' => 0 },
          { 'x' => 20, 'y' => 0 },
          { 'x' => 20, 'y' => 20 },
          { 'x' => 0, 'y' => 20 }
        ]

        result = described_class.sutherland_hodgman_clip(square, clip)

        expect(result.length).to eq(4)
        expect(described_class.polygon_area(result)).to be_within(0.1).of(100.0)
      end
    end

    context 'with empty polygons' do
      it 'returns empty when subject is empty' do
        result = described_class.sutherland_hodgman_clip([], [{ x: 0, y: 0 }])
        expect(result).to be_empty
      end

      it 'returns empty when clip is empty' do
        result = described_class.sutherland_hodgman_clip([{ x: 0, y: 0 }], [])
        expect(result).to be_empty
      end
    end
  end

  describe '.polygon_area' do
    it 'calculates area of a square correctly' do
      square = [
        { x: 0, y: 0 },
        { x: 10, y: 0 },
        { x: 10, y: 10 },
        { x: 0, y: 10 }
      ]

      expect(described_class.polygon_area(square)).to eq(100.0)
    end

    it 'calculates area of a triangle correctly' do
      triangle = [
        { x: 0, y: 0 },
        { x: 10, y: 0 },
        { x: 5, y: 10 }
      ]

      expect(described_class.polygon_area(triangle)).to eq(50.0)
    end

    it 'calculates area of an irregular polygon' do
      # L-shaped polygon
      l_shape = [
        { x: 0, y: 0 },
        { x: 10, y: 0 },
        { x: 10, y: 5 },
        { x: 5, y: 5 },
        { x: 5, y: 10 },
        { x: 0, y: 10 }
      ]

      # L-shape = 10*10 - 5*5 = 75
      expect(described_class.polygon_area(l_shape)).to eq(75.0)
    end

    it 'returns 0 for nil or empty polygon' do
      expect(described_class.polygon_area(nil)).to eq(0.0)
      expect(described_class.polygon_area([])).to eq(0.0)
    end

    it 'returns 0 for polygon with fewer than 3 points' do
      expect(described_class.polygon_area([{ x: 0, y: 0 }])).to eq(0.0)
      expect(described_class.polygon_area([{ x: 0, y: 0 }, { x: 1, y: 1 }])).to eq(0.0)
    end
  end

  describe '.point_in_polygon?' do
    let(:square) do
      [
        { x: 0, y: 0 },
        { x: 10, y: 0 },
        { x: 10, y: 10 },
        { x: 0, y: 10 }
      ]
    end

    it 'returns true for point inside polygon' do
      expect(described_class.point_in_polygon?(5, 5, square)).to be true
    end

    it 'returns false for point outside polygon' do
      expect(described_class.point_in_polygon?(15, 15, square)).to be false
    end

    it 'returns false for nil or empty polygon' do
      expect(described_class.point_in_polygon?(5, 5, nil)).to be false
      expect(described_class.point_in_polygon?(5, 5, [])).to be false
    end

    context 'with a triangle' do
      let(:triangle) do
        [
          { x: 0, y: 0 },
          { x: 10, y: 0 },
          { x: 5, y: 10 }
        ]
      end

      it 'returns true for point inside triangle' do
        expect(described_class.point_in_polygon?(5, 3, triangle)).to be true
      end

      it 'returns false for point outside triangle' do
        expect(described_class.point_in_polygon?(1, 9, triangle)).to be false
      end
    end
  end

  describe '.room_to_polygon' do
    let(:universe) { create(:universe) }
    let(:world) { create(:world, universe: universe) }
    let(:zone) { create(:zone, world: world) }
    let(:location) { create(:location, zone: zone, world_id: world.id) }
    let(:room) { create(:room, location: location, min_x: 10, max_x: 50, min_y: 20, max_y: 80) }

    it 'converts room bounds to polygon array' do
      polygon = described_class.room_to_polygon(room)

      expect(polygon.length).to eq(4)
      expect(polygon).to include(hash_including(x: 10.0, y: 20.0))
      expect(polygon).to include(hash_including(x: 50.0, y: 20.0))
      expect(polygon).to include(hash_including(x: 50.0, y: 80.0))
      expect(polygon).to include(hash_including(x: 10.0, y: 80.0))
    end
  end

  describe '.point_in_effective_area?' do
    let(:universe) { create(:universe) }
    let(:world) { create(:world, universe: universe) }
    let(:zone) { create(:zone, world: world) }
    let(:location) { create(:location, zone: zone, world_id: world.id) }
    let(:room) { create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100) }

    context 'when room has no effective polygon' do
      it 'returns true for point inside room bounds' do
        expect(described_class.point_in_effective_area?(room, 50, 50)).to be true
      end

      it 'returns false for point outside room bounds' do
        expect(described_class.point_in_effective_area?(room, 150, 150)).to be false
      end

      it 'returns true for point on room boundary' do
        expect(described_class.point_in_effective_area?(room, 0, 50)).to be true
        expect(described_class.point_in_effective_area?(room, 100, 50)).to be true
      end
    end

    context 'when room has effective polygon' do
      before do
        # Set a triangular effective polygon
        room.update(effective_polygon: Sequel.pg_jsonb_wrap([
          { x: 0, y: 0 },
          { x: 100, y: 0 },
          { x: 50, y: 100 }
        ]))
      end

      it 'returns true for point inside effective polygon' do
        expect(described_class.point_in_effective_area?(room, 50, 30)).to be true
      end

      it 'returns false for point outside effective polygon but inside room bounds' do
        # Point (10, 90) is inside room bounds but outside the triangle
        expect(described_class.point_in_effective_area?(room, 10, 90)).to be false
      end
    end
  end

  describe '.nearest_valid_position' do
    let(:universe) { create(:universe) }
    let(:world) { create(:world, universe: universe) }
    let(:zone) { create(:zone, world: world) }
    let(:location) { create(:location, zone: zone, world_id: world.id) }
    let(:room) { create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100) }

    context 'when position is already valid' do
      it 'returns the same position' do
        result = described_class.nearest_valid_position(room, 50, 50)

        expect(result[:x]).to eq(50)
        expect(result[:y]).to eq(50)
      end
    end

    context 'when position is outside room bounds' do
      it 'returns nearest point on room boundary' do
        result = described_class.nearest_valid_position(room, 150, 50)

        expect(result[:x]).to eq(100)
        expect(result[:y]).to eq(50)
      end

      it 'handles corner cases' do
        result = described_class.nearest_valid_position(room, 150, 150)

        expect(result[:x]).to eq(100)
        expect(result[:y]).to eq(100)
      end
    end

    context 'when room has effective polygon' do
      before do
        # Set a triangular effective polygon
        room.update(effective_polygon: Sequel.pg_jsonb_wrap([
          { x: 0, y: 0 },
          { x: 100, y: 0 },
          { x: 50, y: 100 }
        ]))
      end

      it 'returns nearest point on effective polygon boundary' do
        # Point (10, 90) is outside the triangle
        result = described_class.nearest_valid_position(room, 10, 90)

        # Should snap to nearest point on triangle edge
        expect(result[:x]).to be_between(0, 50)
        expect(result[:y]).to be_between(0, 100)
      end
    end
  end

  describe '.clip_room_to_zone' do
    let(:universe) { create(:universe) }
    let(:world) { create(:world, universe: universe) }
    let(:zone) { create(:zone, world: world, polygon_points: nil) }
    let(:location) { create(:location, zone: zone, world_id: world.id, globe_hex_id: 1, latitude: 10.0, longitude: 10.0) }
    let(:room) { create(:room, location: location, min_x: 0, max_x: 100, min_y: 0, max_y: 100) }

    context 'when zone has no polygon' do
      it 'returns full room result' do
        result = described_class.clip_room_to_zone(room)

        expect(result[:polygon]).to be_nil
        expect(result[:percentage]).to eq(1.0)
        expect(result[:area]).to eq(10_000.0) # 100 x 100
      end
    end

    context 'when room is fully inside zone polygon' do
      before do
        # Create a very large zone polygon that fully contains the room
        # Zone is in world hex coords, location is at (10, 10)
        zone.update(polygon_points: [
          { 'x' => 9.0, 'y' => 9.0 },
          { 'x' => 11.0, 'y' => 9.0 },
          { 'x' => 11.0, 'y' => 11.0 },
          { 'x' => 9.0, 'y' => 11.0 }
        ])
      end

      it 'returns full room result with nil polygon' do
        result = described_class.clip_room_to_zone(room)

        expect(result[:percentage]).to eq(1.0)
        expect(result[:polygon]).to be_nil # nil means use full bounds
      end
    end

    context 'when room is fully outside zone polygon' do
      before do
        # Create a zone polygon far away from the room
        zone.update(polygon_points: [
          { 'x' => 100.0, 'y' => 100.0 },
          { 'x' => 101.0, 'y' => 100.0 },
          { 'x' => 101.0, 'y' => 101.0 },
          { 'x' => 100.0, 'y' => 101.0 }
        ])
      end

      it 'returns nil' do
        result = described_class.clip_room_to_zone(room)
        expect(result).to be_nil
      end
    end
  end
end
