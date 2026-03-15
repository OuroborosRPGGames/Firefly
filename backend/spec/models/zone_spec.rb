# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Zone do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }

  describe 'associations' do
    it 'belongs to world' do
      zone = Zone.create(name: 'Test Zone', world: world, zone_type: 'wilderness', danger_level: 1)
      expect(zone.world).to eq(world)
    end

    it 'has many locations' do
      zone = Zone.create(name: 'Test Zone', world: world, zone_type: 'wilderness', danger_level: 1)
      location = Location.create(name: 'Test Location', zone: zone, location_type: 'outdoor')
      expect(zone.locations).to include(location)
    end
  end

  describe '#polygon_points' do
    it 'returns empty array for nil' do
      zone = Zone.create(name: 'Test Zone', world: world, zone_type: 'wilderness', danger_level: 1)
      zone.update(polygon_points: nil)
      expect(zone.polygon_points).to eq([])
    end

    it 'parses JSON string' do
      zone = Zone.create(name: 'Test Zone', world: world, zone_type: 'wilderness', danger_level: 1)
      zone.update(polygon_points: '[{"x":0,"y":0},{"x":10,"y":10}]')
      expect(zone.polygon_points).to eq([{ 'x' => 0, 'y' => 0 }, { 'x' => 10, 'y' => 10 }])
    end

    it 'accepts array directly' do
      zone = Zone.create(
        name: 'Test Zone',
        world: world,
        zone_type: 'wilderness',
        danger_level: 1,
        polygon_points: [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }, { x: 0, y: 10 }]
      )
      points = zone.polygon_points
      expect(points.length).to eq(4)
    end
  end

  describe '#contains_point?' do
    let(:zone) do
      Zone.create(
        name: 'Square Zone',
        world: world,
        zone_type: 'wilderness',
        danger_level: 1,
        polygon_points: [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }, { x: 0, y: 10 }]
      )
    end

    it 'returns true for point inside polygon' do
      expect(zone.contains_point?(5, 5)).to be true
    end

    it 'returns false for point outside polygon' do
      expect(zone.contains_point?(15, 15)).to be false
    end

    it 'returns false for empty polygon' do
      empty_zone = Zone.create(name: 'Empty Zone', world: world, zone_type: 'wilderness', danger_level: 1, polygon_points: [])
      expect(empty_zone.contains_point?(5, 5)).to be false
    end

    it 'handles point near edge' do
      expect(zone.contains_point?(1, 1)).to be true
      expect(zone.contains_point?(9, 9)).to be true
    end
  end

  describe '#bounding_box' do
    it 'returns correct bounds' do
      zone = Zone.create(
        name: 'Test Zone',
        world: world,
        zone_type: 'wilderness',
        danger_level: 1,
        polygon_points: [{ x: 2, y: 3 }, { x: 8, y: 1 }, { x: 6, y: 9 }]
      )
      bb = zone.bounding_box
      expect(bb[:min_x]).to eq(2)
      expect(bb[:max_x]).to eq(8)
      expect(bb[:min_y]).to eq(1)
      expect(bb[:max_y]).to eq(9)
    end

    it 'returns nil for empty polygon' do
      zone = Zone.create(name: 'Empty Zone', world: world, zone_type: 'wilderness', danger_level: 1, polygon_points: [])
      expect(zone.bounding_box).to be_nil
    end
  end

  describe '#polygon_area' do
    it 'calculates area correctly for square' do
      zone = Zone.create(
        name: 'Square Zone',
        world: world,
        zone_type: 'wilderness',
        danger_level: 1,
        polygon_points: [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }, { x: 0, y: 10 }]
      )
      expect(zone.polygon_area).to eq(100.0)
    end

    it 'returns 0 for fewer than 3 points' do
      zone = Zone.create(
        name: 'Line Zone',
        world: world,
        zone_type: 'wilderness',
        danger_level: 1,
        polygon_points: [{ x: 0, y: 0 }, { x: 10, y: 0 }]
      )
      expect(zone.polygon_area).to eq(0.0)
    end
  end

  describe '#center_point' do
    it 'calculates centroid correctly' do
      zone = Zone.create(
        name: 'Square Zone',
        world: world,
        zone_type: 'wilderness',
        danger_level: 1,
        polygon_points: [{ x: 0, y: 0 }, { x: 10, y: 0 }, { x: 10, y: 10 }, { x: 0, y: 10 }]
      )
      center = zone.center_point
      expect(center[:x]).to eq(5.0)
      expect(center[:y]).to eq(5.0)
    end

    it 'returns nil for empty polygon' do
      zone = Zone.create(name: 'Empty Zone', world: world, zone_type: 'wilderness', danger_level: 1, polygon_points: [])
      expect(zone.center_point).to be_nil
    end
  end

  describe '#contains_hex?' do
    let(:zone) do
      Zone.create(
        name: 'Hex Zone',
        world: world,
        zone_type: 'wilderness',
        danger_level: 1,
        polygon_points: [{ x: 0, y: 0 }, { x: 100, y: 0 }, { x: 100, y: 100 }, { x: 0, y: 100 }]
      )
    end

    it 'returns true for hex inside zone' do
      expect(zone.contains_hex?(50, 50)).to be true
    end

    it 'returns false for hex outside zone' do
      expect(zone.contains_hex?(150, 150)).to be false
    end
  end

  describe '#polygon_scale' do
    it 'defaults to world' do
      zone = Zone.create(name: 'Test Zone', world: world, zone_type: 'wilderness', danger_level: 1)
      expect(zone.polygon_scale).to eq('world')
    end

    it 'returns the stored value' do
      zone = Zone.create(name: 'Test Zone', world: world, zone_type: 'wilderness', danger_level: 1, polygon_scale: 'local')
      expect(zone.polygon_scale).to eq('local')
    end
  end

  describe '#local_scale? and #world_scale?' do
    it 'returns true for local_scale? when polygon_scale is local' do
      zone = Zone.create(name: 'Test Zone', world: world, zone_type: 'wilderness', danger_level: 1, polygon_scale: 'local')
      expect(zone.local_scale?).to be true
      expect(zone.world_scale?).to be false
    end

    it 'returns true for world_scale? when polygon_scale is world' do
      zone = Zone.create(name: 'Test Zone', world: world, zone_type: 'wilderness', danger_level: 1, polygon_scale: 'world')
      expect(zone.local_scale?).to be false
      expect(zone.world_scale?).to be true
    end
  end

  describe '#contains_local_point?' do
    let(:zone) do
      Zone.create(
        name: 'Test Zone',
        world: world,
        zone_type: 'wilderness',
        danger_level: 1,
        polygon_points: [
          { x: 9.9, y: 9.9 },
          { x: 10.1, y: 9.9 },
          { x: 10.1, y: 10.1 },
          { x: 9.9, y: 10.1 }
        ]
      )
    end

    context 'with world scale polygon' do
      it 'transforms local coordinates to world coordinates' do
        # Point at origin (0,0) in feet, anchored at (10,10) in hex should be inside
        expect(zone.contains_local_point?(0, 0, origin_x: 10, origin_y: 10)).to be true
      end

      it 'returns false for far away local points' do
        # Point very far away (1 million feet) from origin
        expect(zone.contains_local_point?(1_000_000, 1_000_000, origin_x: 10, origin_y: 10)).to be false
      end
    end

    context 'with local scale polygon' do
      let(:local_zone) do
        Zone.create(
          name: 'Local Zone',
          world: world,
          zone_type: 'city',
          danger_level: 1,
          polygon_scale: 'local',
          polygon_points: [
            { x: 0, y: 0 },
            { x: 1000, y: 0 },
            { x: 1000, y: 1000 },
            { x: 0, y: 1000 }
          ]
        )
      end

      it 'uses local coordinates directly' do
        expect(local_zone.contains_local_point?(500, 500)).to be true
      end

      it 'returns false for points outside local polygon' do
        expect(local_zone.contains_local_point?(2000, 2000)).to be false
      end
    end

    context 'without polygon' do
      let(:no_polygon_zone) do
        Zone.create(name: 'No Polygon Zone', world: world, zone_type: 'wilderness', danger_level: 1)
      end

      it 'returns true for any point' do
        expect(no_polygon_zone.contains_local_point?(99999, 99999)).to be true
      end
    end
  end

  describe 'backward compatibility' do
    it 'supports Area alias' do
      expect(defined?(Area)).to eq('constant')
      expect(Area).to eq(Zone)
    end
  end
end
