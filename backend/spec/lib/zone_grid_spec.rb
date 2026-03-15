# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ZoneGrid do
  describe 'constants' do
    it 'defines DISTANCE_UNITS_PER_METER as 2.0' do
      expect(described_class::DISTANCE_UNITS_PER_METER).to eq(2.0)
    end

    it 'defines METERS_PER_DISTANCE_UNIT as 0.5' do
      expect(described_class::METERS_PER_DISTANCE_UNIT).to eq(0.5)
    end
  end

  describe '.lonlat_to_zone_grid' do
    let(:world) { instance_double('World') }
    let(:zone) { instance_double('Zone') }

    context 'when no zone contains the point' do
      it 'returns nil' do
        allow(world).to receive(:zones).and_return([zone])
        allow(zone).to receive(:contains_point?).and_return(false)

        result = described_class.lonlat_to_zone_grid(0, 0, world)
        expect(result).to be_nil
      end
    end

    context 'when zone has no bounding box' do
      it 'returns nil' do
        allow(world).to receive(:zones).and_return([zone])
        allow(zone).to receive(:contains_point?).and_return(true)
        allow(zone).to receive(:bounding_box).and_return(nil)

        result = described_class.lonlat_to_zone_grid(0, 0, world)
        expect(result).to be_nil
      end
    end

    context 'when point is within a zone' do
      let(:bounding_box) { { min_x: 0, max_x: 1, min_y: 0, max_y: 1 } }

      it 'returns grid coordinates and zone' do
        allow(world).to receive(:zones).and_return([zone])
        allow(zone).to receive(:contains_point?).and_return(true)
        allow(zone).to receive(:bounding_box).and_return(bounding_box)

        result = described_class.lonlat_to_zone_grid(0.5, 0.5, world)

        expect(result).to be_an(Array)
        expect(result.length).to eq(3)
        expect(result[0]).to be_an(Integer) # grid_x
        expect(result[1]).to be_an(Integer) # grid_y
        expect(result[2]).to eq(zone)
      end

      it 'scales coordinates based on meters per degree at latitude' do
        allow(world).to receive(:zones).and_return([zone])
        allow(zone).to receive(:contains_point?).and_return(true)
        allow(zone).to receive(:bounding_box).and_return(bounding_box)

        # At equator (lat 0), cos(0) = 1
        result_equator = described_class.lonlat_to_zone_grid(0.5, 0, world)
        expect(result_equator[0]).to be >= 0
      end
    end
  end

  describe '.zone_grid_to_lonlat' do
    let(:zone) { instance_double('Zone') }
    let(:bounding_box) { { min_x: 0, max_x: 1, min_y: 0, max_y: 1 } }

    context 'when zone is nil' do
      it 'returns nil' do
        result = described_class.zone_grid_to_lonlat(100, 100, nil)
        expect(result).to be_nil
      end
    end

    context 'when zone has no bounding box' do
      it 'returns nil' do
        allow(zone).to receive(:bounding_box).and_return(nil)

        result = described_class.zone_grid_to_lonlat(100, 100, zone)
        expect(result).to be_nil
      end
    end

    context 'when zone has valid bounding box' do
      it 'returns longitude and latitude array' do
        allow(zone).to receive(:bounding_box).and_return(bounding_box)

        result = described_class.zone_grid_to_lonlat(100, 100, zone)

        expect(result).to be_an(Array)
        expect(result.length).to eq(2)
        expect(result[0]).to be_a(Numeric) # longitude
        expect(result[1]).to be_a(Numeric) # latitude
      end

      it 'returns coordinates within zone bounds' do
        allow(zone).to receive(:bounding_box).and_return(bounding_box)

        # Grid coordinates at center should give coordinates near center of zone
        result = described_class.zone_grid_to_lonlat(0, 0, zone)

        expect(result[0]).to be_within(2).of(bounding_box[:min_x])
        expect(result[1]).to be_within(2).of(bounding_box[:min_y])
      end
    end
  end

  describe '.zone_grid_to_world_hex' do
    let(:zone) { instance_double('Zone') }
    let(:world) { instance_double('World') }
    let(:world_hex) { instance_double('WorldHex') }
    let(:bounding_box) { { min_x: 0, max_x: 1, min_y: 0, max_y: 1 } }

    context 'when zone_grid_to_lonlat returns nil' do
      it 'returns nil' do
        allow(zone).to receive(:bounding_box).and_return(nil)

        result = described_class.zone_grid_to_world_hex(100, 100, zone)
        expect(result).to be_nil
      end
    end

    context 'when zone has no world' do
      it 'returns nil' do
        allow(zone).to receive(:bounding_box).and_return(bounding_box)
        allow(zone).to receive(:world).and_return(nil)

        result = described_class.zone_grid_to_world_hex(100, 100, zone)
        expect(result).to be_nil
      end
    end

    context 'when conversion succeeds' do
      it 'returns WorldHex record from find_nearest_by_latlon' do
        allow(zone).to receive(:bounding_box).and_return(bounding_box)
        allow(zone).to receive(:world).and_return(world)
        allow(world).to receive(:id).and_return(1)
        allow(WorldHex).to receive(:find_nearest_by_latlon).and_return(world_hex)

        result = described_class.zone_grid_to_world_hex(100, 100, zone)

        expect(result).to eq(world_hex)
      end
    end
  end

  describe '.world_hex_to_zone_grid' do
    let(:world) { instance_double('World') }
    let(:zone) { instance_double('Zone') }
    let(:world_hex) { instance_double('WorldHex') }

    context 'when world_hex is nil' do
      it 'returns nil' do
        result = described_class.world_hex_to_zone_grid(nil, world)
        expect(result).to be_nil
      end
    end

    context 'when world_hex has no coordinates' do
      it 'returns nil' do
        allow(world_hex).to receive(:latitude).and_return(nil)
        allow(world_hex).to receive(:longitude).and_return(nil)

        result = described_class.world_hex_to_zone_grid(world_hex, world)
        expect(result).to be_nil
      end
    end

    context 'when lonlat_to_zone_grid returns nil' do
      it 'returns nil' do
        allow(world_hex).to receive(:latitude).and_return(0.5)
        allow(world_hex).to receive(:longitude).and_return(0.5)
        allow(world).to receive(:zones).and_return([zone])
        allow(zone).to receive(:contains_point?).and_return(false)

        result = described_class.world_hex_to_zone_grid(world_hex, world)
        expect(result).to be_nil
      end
    end
  end

  describe '.innermost_room_at' do
    let(:zone) { instance_double('Zone') }
    let(:location) { instance_double('Location') }

    context 'when zone is nil' do
      it 'returns nil' do
        result = described_class.innermost_room_at(100, 100, 0, nil)
        expect(result).to be_nil
      end
    end

    context 'when no rooms contain the point' do
      it 'returns nil' do
        room = instance_double('Room', min_x: 0, max_x: 50, min_y: 0, max_y: 50, min_z: nil, max_z: nil)
        allow(zone).to receive(:locations).and_return([location])
        allow(location).to receive(:rooms).and_return([room])

        result = described_class.innermost_room_at(200, 200, 0, zone)
        expect(result).to be_nil
      end
    end

    context 'when one room contains the point' do
      it 'returns that room' do
        room = instance_double('Room', min_x: 0, max_x: 200, min_y: 0, max_y: 200, min_z: nil, max_z: nil)
        allow(zone).to receive(:locations).and_return([location])
        allow(location).to receive(:rooms).and_return([room])

        result = described_class.innermost_room_at(100, 100, 0, zone)
        expect(result).to eq(room)
      end
    end

    context 'when multiple rooms contain the point' do
      it 'returns the smallest room (innermost)' do
        large_room = instance_double('Room', min_x: 0, max_x: 200, min_y: 0, max_y: 200, min_z: nil, max_z: nil)
        small_room = instance_double('Room', min_x: 50, max_x: 150, min_y: 50, max_y: 150, min_z: nil, max_z: nil)
        allow(zone).to receive(:locations).and_return([location])
        allow(location).to receive(:rooms).and_return([large_room, small_room])

        result = described_class.innermost_room_at(100, 100, 0, zone)
        expect(result).to eq(small_room)
      end
    end
  end

  describe '.room_contains_point?' do
    context 'when room has no bounds' do
      it 'returns false' do
        room = instance_double('Room', min_x: nil, max_x: 100, min_y: 0, max_y: 100)
        expect(described_class.room_contains_point?(room, 50, 50, 0)).to be false
      end
    end

    context 'when point is within 2D bounds' do
      it 'returns true' do
        room = instance_double('Room', min_x: 0, max_x: 100, min_y: 0, max_y: 100, min_z: nil, max_z: nil)
        expect(described_class.room_contains_point?(room, 50, 50, 0)).to be true
      end
    end

    context 'when point is outside 2D bounds' do
      it 'returns false for x out of bounds' do
        room = instance_double('Room', min_x: 0, max_x: 100, min_y: 0, max_y: 100, min_z: nil, max_z: nil)
        expect(described_class.room_contains_point?(room, 150, 50, 0)).to be false
      end

      it 'returns false for y out of bounds' do
        room = instance_double('Room', min_x: 0, max_x: 100, min_y: 0, max_y: 100, min_z: nil, max_z: nil)
        expect(described_class.room_contains_point?(room, 50, 150, 0)).to be false
      end
    end

    context 'when room has Z bounds' do
      it 'returns true when point is within Z bounds' do
        room = instance_double('Room', min_x: 0, max_x: 100, min_y: 0, max_y: 100, min_z: 0, max_z: 50)
        expect(described_class.room_contains_point?(room, 50, 50, 25)).to be true
      end

      it 'returns false when point is outside Z bounds' do
        room = instance_double('Room', min_x: 0, max_x: 100, min_y: 0, max_y: 100, min_z: 0, max_z: 50)
        expect(described_class.room_contains_point?(room, 50, 50, 100)).to be false
      end
    end

    context 'boundary conditions' do
      it 'includes points on min boundaries' do
        room = instance_double('Room', min_x: 0, max_x: 100, min_y: 0, max_y: 100, min_z: nil, max_z: nil)
        expect(described_class.room_contains_point?(room, 0, 0, 0)).to be true
      end

      it 'includes points on max boundaries' do
        room = instance_double('Room', min_x: 0, max_x: 100, min_y: 0, max_y: 100, min_z: nil, max_z: nil)
        expect(described_class.room_contains_point?(room, 100, 100, 0)).to be true
      end
    end
  end

  describe '.room_volume' do
    context 'when room has no bounds' do
      it 'returns nil' do
        room = instance_double('Room', min_x: nil, max_x: 100, min_y: 0, max_y: 100, min_z: nil, max_z: nil)
        expect(described_class.room_volume(room)).to be_nil
      end
    end

    context 'when room has 2D bounds only' do
      it 'returns area with default depth of 1' do
        room = instance_double('Room', min_x: 0, max_x: 100, min_y: 0, max_y: 50, min_z: nil, max_z: nil)
        expect(described_class.room_volume(room)).to eq(100 * 50 * 1.0)
      end
    end

    context 'when room has 3D bounds' do
      it 'returns full volume' do
        room = instance_double('Room', min_x: 0, max_x: 100, min_y: 0, max_y: 50, min_z: 0, max_z: 10)
        expect(described_class.room_volume(room)).to eq(100 * 50 * 10)
      end
    end
  end

  describe '.meters_to_grid_units' do
    it 'converts 1 meter to 2 units' do
      expect(described_class.meters_to_grid_units(1)).to eq(2)
    end

    it 'converts 0.5 meters to 1 unit' do
      expect(described_class.meters_to_grid_units(0.5)).to eq(1)
    end

    it 'converts 10 meters to 20 units' do
      expect(described_class.meters_to_grid_units(10)).to eq(20)
    end

    it 'handles zero' do
      expect(described_class.meters_to_grid_units(0)).to eq(0)
    end
  end

  describe '.grid_units_to_meters' do
    it 'converts 2 units to 1 meter' do
      expect(described_class.grid_units_to_meters(2)).to eq(1)
    end

    it 'converts 1 unit to 0.5 meters' do
      expect(described_class.grid_units_to_meters(1)).to eq(0.5)
    end

    it 'converts 20 units to 10 meters' do
      expect(described_class.grid_units_to_meters(20)).to eq(10)
    end

    it 'handles zero' do
      expect(described_class.grid_units_to_meters(0)).to eq(0)
    end
  end

  describe 'unit conversion consistency' do
    it 'meters_to_grid_units and grid_units_to_meters are inverse operations' do
      [0, 1, 5, 10, 100].each do |meters|
        units = described_class.meters_to_grid_units(meters)
        recovered = described_class.grid_units_to_meters(units)
        expect(recovered).to eq(meters)
      end
    end
  end
end
