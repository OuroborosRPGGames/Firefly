# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WeatherGrid::PersistenceService do
  let(:world) { create(:world) }

  before do
    WeatherGrid::GridService.clear(world)
    WeatherGrid::TerrainService.clear(world)
    WeatherWorldState.where(world_id: world.id).delete
  end

  after do
    WeatherGrid::GridService.clear(world)
    WeatherGrid::TerrainService.clear(world)
    WeatherWorldState.where(world_id: world.id).delete
  end

  describe '.load_to_redis' do
    context 'with no existing DB state' do
      it 'initializes a new world with default data' do
        expect(WeatherGrid::GridService.exists?(world)).to be false

        result = described_class.load_to_redis(world)

        expect(result).to be true
        expect(WeatherGrid::GridService.exists?(world)).to be true
      end

      it 'creates a WeatherWorldState record' do
        described_class.load_to_redis(world)

        state = WeatherWorldState.find(world_id: world.id)
        expect(state).not_to be_nil
      end
    end

    context 'with existing DB state' do
      before do
        # Create a DB state with custom data
        state = WeatherWorldState.create(world_id: world.id)
        state.grid_hash = {
          'cells' => [{ 'temperature' => 42.5 }],
          'meta' => { 'tick_count' => 100 }
        }
        state.storms = [{ 'id' => 'storm_123', 'type' => 'thunderstorm' }]
        state.meta = { 'season' => 'winter' }
        state.save
      end

      it 'loads grid data from DB to Redis' do
        result = described_class.load_to_redis(world)

        expect(result).to be true
        grid = WeatherGrid::GridService.load(world)
        expect(grid[:cells].first['temperature']).to eq(42.5)
      end

      it 'loads storms from DB' do
        described_class.load_to_redis(world)

        grid = WeatherGrid::GridService.load(world)
        expect(grid[:meta]['storms']).to include(hash_including('id' => 'storm_123'))
      end
    end
  end

  describe '.persist_to_db' do
    before do
      # Initialize Redis data
      WeatherGrid::GridService.initialize_world(world)
      WeatherGrid::GridService.update_meta(world, {
        'tick_count' => 50,
        'storms' => [{ 'id' => 'storm_abc' }]
      })
    end

    it 'saves grid data from Redis to DB' do
      result = described_class.persist_to_db(world)

      expect(result).to be true
      state = WeatherWorldState.find(world_id: world.id)
      expect(state).not_to be_nil
      expect(state.grid_hash['cells'].length).to eq(64 * 64)
    end

    it 'saves meta data to DB' do
      described_class.persist_to_db(world)

      state = WeatherWorldState.find(world_id: world.id)
      expect(state.meta['tick_count']).to eq(50)
    end

    it 'saves storms to DB' do
      described_class.persist_to_db(world)

      state = WeatherWorldState.find(world_id: world.id)
      expect(state.storms).to include(hash_including('id' => 'storm_abc'))
    end

    it 'returns false when no Redis data exists' do
      WeatherGrid::GridService.clear(world)

      result = described_class.persist_to_db(world)
      expect(result).to be false
    end
  end

  describe '.needs_sync?' do
    context 'with no sync history' do
      before do
        WeatherGrid::GridService.initialize_world(world)
      end

      it 'returns true' do
        expect(described_class.needs_sync?(world)).to be true
      end
    end

    context 'with recent sync' do
      before do
        WeatherGrid::GridService.initialize_world(world)
        WeatherGrid::GridService.update_meta(world, {
          'last_persisted_at' => Time.now.iso8601
        })
      end

      it 'returns false' do
        expect(described_class.needs_sync?(world)).to be false
      end
    end

    context 'with old sync' do
      before do
        WeatherGrid::GridService.initialize_world(world)
        WeatherGrid::GridService.update_meta(world, {
          'last_persisted_at' => (Time.now - 600).iso8601 # 10 minutes ago
        })
      end

      it 'returns true' do
        expect(described_class.needs_sync?(world)).to be true
      end
    end
  end

  describe '.sync_if_needed' do
    before do
      WeatherGrid::GridService.initialize_world(world)
    end

    it 'syncs when needed and updates last_persisted_at' do
      result = described_class.sync_if_needed(world)

      expect(result).to be true

      grid = WeatherGrid::GridService.load(world)
      expect(grid[:meta]['last_persisted_at']).not_to be_nil
    end

    it 'skips sync when not needed' do
      WeatherGrid::GridService.update_meta(world, {
        'last_persisted_at' => Time.now.iso8601
      })

      result = described_class.sync_if_needed(world)
      expect(result).to be false
    end
  end

  describe '.delete_world' do
    before do
      WeatherGrid::GridService.initialize_world(world)
      described_class.persist_to_db(world)
    end

    it 'removes Redis data' do
      described_class.delete_world(world)

      expect(WeatherGrid::GridService.exists?(world)).to be false
    end

    it 'removes DB record' do
      described_class.delete_world(world)

      state = WeatherWorldState.find(world_id: world.id)
      expect(state).to be_nil
    end
  end

  describe '.read_from_db_fallback' do
    before do
      state = WeatherWorldState.create(world_id: world.id)
      state.grid_hash = { 'cells' => [{ 'temp' => 20 }], 'meta' => {} }
      state.terrain_hash = { 'cells' => [{ 'altitude' => 100 }] }
      state.storms = [{ 'id' => 'storm_xyz' }]
      state.meta = { 'season' => 'summer' }
      state.save
    end

    it 'reads weather data directly from DB' do
      result = described_class.read_from_db_fallback(world)

      expect(result).not_to be_nil
      expect(result[:grid]['cells'].first['temp']).to eq(20)
      expect(result[:storms]).to include(hash_including('id' => 'storm_xyz'))
    end

    it 'returns nil for non-existent world' do
      other_world = World.new
      other_world.id = 999_999

      result = described_class.read_from_db_fallback(other_world)
      expect(result).to be_nil
    end
  end

  describe '.last_sync_time' do
    it 'returns nil when no sync has occurred' do
      WeatherGrid::GridService.initialize_world(world)

      expect(described_class.last_sync_time(world)).to be_nil
    end

    it 'returns the last sync time' do
      WeatherGrid::GridService.initialize_world(world)
      sync_time = Time.now
      WeatherGrid::GridService.update_meta(world, {
        'last_persisted_at' => sync_time.iso8601
      })

      result = described_class.last_sync_time(world)
      expect(result).to be_within(1).of(sync_time)
    end
  end
end
