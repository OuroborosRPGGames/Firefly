# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WeatherWorldState do
  let(:world) { create(:world) }

  describe 'associations' do
    it 'belongs to a world' do
      state = WeatherWorldState.create(world: world)
      expect(state.world).to eq(world)
    end
  end

  describe 'validations' do
    it 'requires a world_id' do
      state = WeatherWorldState.new
      expect(state.valid?).to be false
      expect(state.errors[:world_id]).not_to be_empty
    end

    it 'enforces unique world_id' do
      WeatherWorldState.create(world: world)
      duplicate = WeatherWorldState.new(world: world)
      expect(duplicate.valid?).to be false
    end
  end

  describe '#grid_hash' do
    it 'unpacks grid_data from MessagePack' do
      grid = { 'cells' => [{ 'temp' => 20 }] }
      state = WeatherWorldState.create(world: world)
      state.grid_hash = grid
      state.save

      reloaded = WeatherWorldState[state.id]
      expect(reloaded.grid_hash).to eq(grid)
    end

    it 'returns empty hash when grid_data is nil' do
      state = WeatherWorldState.create(world: world)
      expect(state.grid_hash).to eq({})
    end
  end

  describe '#terrain_hash' do
    it 'unpacks terrain_data from MessagePack' do
      terrain = { 'hexes' => [{ 'type' => 'forest' }] }
      state = WeatherWorldState.create(world: world)
      state.terrain_hash = terrain
      state.save

      reloaded = WeatherWorldState[state.id]
      expect(reloaded.terrain_hash).to eq(terrain)
    end

    it 'returns empty hash when terrain_data is nil' do
      state = WeatherWorldState.create(world: world)
      expect(state.terrain_hash).to eq({})
    end
  end

  describe '#storms' do
    it 'returns storms_data as array' do
      state = WeatherWorldState.create(world: world, storms_data: [{ 'id' => 'storm1' }])
      expect(state.storms).to eq([{ 'id' => 'storm1' }])
    end

    it 'returns empty array when nil' do
      state = WeatherWorldState.create(world: world)
      expect(state.storms).to eq([])
    end
  end

  describe '#storms=' do
    it 'sets storms_data' do
      state = WeatherWorldState.create(world: world)
      state.storms = [{ 'id' => 'storm2' }]
      state.save

      reloaded = WeatherWorldState[state.id]
      expect(reloaded.storms).to eq([{ 'id' => 'storm2' }])
    end
  end

  describe '#meta' do
    it 'returns meta_data as hash' do
      state = WeatherWorldState.create(world: world, meta_data: { 'season' => 'winter' })
      expect(state.meta).to eq({ 'season' => 'winter' })
    end

    it 'returns empty hash when nil' do
      state = WeatherWorldState.create(world: world)
      expect(state.meta).to eq({})
    end
  end

  describe '#meta=' do
    it 'sets meta_data' do
      state = WeatherWorldState.create(world: world)
      state.meta = { 'last_tick' => 12345 }
      state.save

      reloaded = WeatherWorldState[state.id]
      expect(reloaded.meta).to eq({ 'last_tick' => 12345 })
    end
  end
end
