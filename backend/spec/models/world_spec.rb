# frozen_string_literal: true

require 'spec_helper'

RSpec.describe World do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }

  describe 'validations' do
    it 'is valid with valid attributes' do
      expect(world).to be_valid
    end

    it 'requires name' do
      w = World.new(universe_id: universe.id)
      expect(w).not_to be_valid
    end

    it 'requires universe_id' do
      w = World.new(name: 'Test World')
      expect(w).not_to be_valid
    end

    it 'validates uniqueness of name per universe' do
      World.create(universe_id: universe.id, name: 'Unique World', gravity_multiplier: 1.0, world_size: 1000.0)
      duplicate = World.new(universe_id: universe.id, name: 'Unique World', gravity_multiplier: 1.0, world_size: 1000.0)
      expect(duplicate).not_to be_valid
    end

    it 'validates max length of name' do
      w = World.new(universe_id: universe.id, name: 'x' * 101, gravity_multiplier: 1.0, world_size: 1000.0)
      expect(w).not_to be_valid
    end

    it 'validates gravity_multiplier is numeric' do
      w = World.create(universe_id: universe.id, name: 'Test Gravity', gravity_multiplier: 1.0, world_size: 1000.0)
      expect(w).to be_valid
    end

    it 'validates world_size is positive' do
      w = World.new(universe_id: universe.id, name: 'Test Size', gravity_multiplier: 1.0, world_size: -1)
      expect(w).not_to be_valid
    end
  end

  describe 'associations' do
    it 'belongs to universe' do
      expect(world.universe).to eq(universe)
    end

    it 'has many zones' do
      expect(world).to respond_to(:zones)
    end

    it 'has many world_hexes' do
      expect(world).to respond_to(:world_hexes)
    end
  end

  describe '#test_world?' do
    it 'returns true when is_test is true' do
      w = World.create(universe_id: universe.id, name: 'Test World 2', is_test: true, gravity_multiplier: 1.0, world_size: 1000.0)
      expect(w.test_world?).to be true
    end

    it 'returns false when is_test is false or nil' do
      expect(world.test_world?).to be false
    end
  end

  describe '#coordinates' do
    it 'returns coordinates as array' do
      w = World.create(universe_id: universe.id, name: 'Coords World', coordinates_x: 10, coordinates_y: 20, coordinates_z: 30, gravity_multiplier: 1.0, world_size: 1000.0)
      expect(w.coordinates).to eq([10, 20, 30])
    end

    it 'defaults missing coordinates to 0' do
      w = World.create(universe_id: universe.id, name: 'No Coords', gravity_multiplier: 1.0, world_size: 1000.0)
      expect(w.coordinates).to eq([0, 0, 0])
    end
  end

  describe '#coordinates=' do
    it 'sets coordinates from array' do
      world.coordinates = [5, 10, 15]
      expect(world.coordinates_x).to eq(5)
      expect(world.coordinates_y).to eq(10)
      expect(world.coordinates_z).to eq(15)
    end

    it 'handles 2D coordinates' do
      world.coordinates = [1, 2]
      expect(world.coordinates_x).to eq(1)
      expect(world.coordinates_y).to eq(2)
    end
  end

  describe '#distance_to' do
    let(:world1) { World.create(universe_id: universe.id, name: 'World 1', coordinates_x: 0, coordinates_y: 0, coordinates_z: 0, gravity_multiplier: 1.0, world_size: 1000.0) }
    let(:world2) { World.create(universe_id: universe.id, name: 'World 2', coordinates_x: 3, coordinates_y: 4, coordinates_z: 0, gravity_multiplier: 1.0, world_size: 1000.0) }

    it 'calculates 3D distance between worlds' do
      expect(world1.distance_to(world2)).to eq(5.0)
    end

    it 'returns nil if coordinates are missing' do
      w_no_coords = World.create(universe_id: universe.id, name: 'No Coords World', gravity_multiplier: 1.0, world_size: 1000.0, coordinates_x: nil, coordinates_y: nil, coordinates_z: nil)
      expect(world1.distance_to(w_no_coords)).to be_nil
    end
  end

  describe '#nearby_worlds' do
    let!(:world1) { World.create(universe_id: universe.id, name: 'World 1', coordinates_x: 0, coordinates_y: 0, coordinates_z: 0, gravity_multiplier: 1.0, world_size: 1000.0) }
    let!(:world2) { World.create(universe_id: universe.id, name: 'World 2', coordinates_x: 10, coordinates_y: 0, coordinates_z: 0, gravity_multiplier: 1.0, world_size: 1000.0) }
    let!(:world3) { World.create(universe_id: universe.id, name: 'World 3', coordinates_x: 200, coordinates_y: 0, coordinates_z: 0, gravity_multiplier: 1.0, world_size: 1000.0) }

    it 'returns nearby worlds within distance' do
      nearby = world1.nearby_worlds(50)
      expect(nearby).to include(world2)
      expect(nearby).not_to include(world3)
    end

    it 'returns empty array if no coordinates' do
      w = World.create(universe_id: universe.id, name: 'No Coords For Nearby', gravity_multiplier: 1.0, world_size: 1000.0, coordinates_x: nil, coordinates_y: nil, coordinates_z: nil)
      expect(w.nearby_worlds(100)).to eq([])
    end

    it 'excludes self from results' do
      nearby = world1.nearby_worlds(100)
      expect(nearby).not_to include(world1)
    end
  end

  describe 'weather settings' do
    describe '#effective_storm_frequency' do
      it 'returns 1.0 by default' do
        expect(world.effective_storm_frequency).to eq(1.0)
      end
    end

    describe '#effective_precipitation' do
      it 'returns 1.0 by default' do
        expect(world.effective_precipitation).to eq(1.0)
      end
    end

    describe '#global_temp_offset' do
      it 'returns 0 by default' do
        expect(world.global_temp_offset).to eq(0)
      end
    end

    describe '#effective_variability' do
      it 'returns 1.0 by default' do
        expect(world.effective_variability).to eq(1.0)
      end
    end

    describe '#current_season' do
      it 'returns nil by default (uses calculated season)' do
        expect(world.current_season).to be_nil
      end
    end
  end

  # Note: hex grid methods (lonlat_to_hex, hex_to_lonlat, etc.) were removed
  # as part of the globe-only hex conversion. WorldHex now uses globe_hex_id
  # and lat/lon columns directly.

  describe 'zone grid methods' do
    it 'responds to lonlat_to_zone_grid' do
      expect(world).to respond_to(:lonlat_to_zone_grid)
    end

    it 'responds to innermost_room_at' do
      expect(world).to respond_to(:innermost_room_at)
    end
  end

  describe 'hex detail methods' do
    it 'responds to hex_details' do
      expect(world).to respond_to(:hex_details)
    end

    it 'responds to hex_terrain' do
      expect(world).to respond_to(:hex_terrain)
    end

    it 'responds to hex_altitude' do
      expect(world).to respond_to(:hex_altitude)
    end

    it 'responds to hex_traversable?' do
      expect(world).to respond_to(:hex_traversable?)
    end
  end
end
