# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldTerrainRaster do
  let(:world) { create(:world) }

  describe 'validations' do
    it 'requires world_id' do
      raster = build(:world_terrain_raster, world: nil)
      expect(raster.valid?).to be false
    end

    it 'requires resolution_x' do
      raster = build(:world_terrain_raster, world: world, resolution_x: nil)
      expect(raster.valid?).to be false
    end

    it 'requires resolution_y' do
      raster = build(:world_terrain_raster, world: world, resolution_y: nil)
      expect(raster.valid?).to be false
    end

    it 'allows valid raster' do
      raster = build(:world_terrain_raster, world: world)
      expect(raster.valid?).to be true
    end
  end

  describe 'associations' do
    it 'belongs to a world' do
      raster = create(:world_terrain_raster, world: world)
      expect(raster.world).to eq(world)
    end
  end

  describe '#valid_cache?' do
    let(:raster) { create(:world_terrain_raster, world: world) }

    context 'when png_data is nil' do
      it 'returns false' do
        raster.update(png_data: nil)
        expect(raster.valid_cache?).to be false
      end
    end

    context 'when generated_at is nil' do
      it 'returns false' do
        raster.update(png_data: Sequel.blob('data'), generated_at: nil)
        expect(raster.valid_cache?).to be false
      end
    end

    context 'when world was modified after generation' do
      it 'returns false' do
        raster.update(
          png_data: Sequel.blob('data'),
          generated_at: Time.now,
          world_modified_at: Time.now - 3600
        )
        world.update(updated_at: Time.now)
        expect(raster.valid_cache?).to be false
      end
    end

    context 'when cache is valid' do
      it 'returns true' do
        frozen_time = Time.now
        # Set world updated_at to before the cache was generated
        world.this.update(updated_at: frozen_time - 100)
        raster.update(
          png_data: Sequel.blob('data'),
          generated_at: frozen_time,
          world_modified_at: frozen_time
        )
        # Refresh to pick up changes
        raster.refresh
        expect(raster.valid_cache?).to be true
      end
    end
  end

  describe '.terrain_texture' do
    before do
      allow(TerrainTextureService).to receive_message_chain(:new, :generate).and_return('png_binary_data')
    end

    it 'creates a raster record if none exists' do
      expect {
        described_class.terrain_texture(world)
      }.to change { described_class.where(world_id: world.id).count }.by(1)
    end

    it 'returns cached texture when valid' do
      frozen_time = Time.now
      # Set world updated_at to before the cache was generated
      world.this.update(updated_at: frozen_time - 100)
      create(:world_terrain_raster,
             world: world,
             png_data: Sequel.blob('cached_data'),
             generated_at: frozen_time,
             world_modified_at: frozen_time)

      result = described_class.terrain_texture(world)
      expect(result).to eq('cached_data')
    end

    it 'regenerates texture when force is true' do
      now = Time.now
      world.update(updated_at: now - 100)
      create(:world_terrain_raster,
             world: world,
             png_data: Sequel.blob('old_data'),
             generated_at: now,
             world_modified_at: now)

      result = described_class.terrain_texture(world, force: true)
      expect(result).to eq('png_binary_data')
    end

    it 'regenerates texture when cache is invalid' do
      create(:world_terrain_raster,
             world: world,
             png_data: nil,
             generated_at: nil)

      result = described_class.terrain_texture(world)
      expect(result).to eq('png_binary_data')
    end

    it 'returns nil when generation fails' do
      allow(TerrainTextureService).to receive_message_chain(:new, :generate).and_return(nil)

      result = described_class.terrain_texture(world)
      expect(result).to be_nil
    end

    it 'handles exceptions gracefully' do
      allow(TerrainTextureService).to receive(:new).and_raise(StandardError, 'Test error')

      result = described_class.terrain_texture(world)
      expect(result).to be_nil
    end
  end

  describe '.cache_texture' do
    it 'creates a raster record with texture data' do
      result = described_class.cache_texture(world, 'png_data')

      expect(result).to be_a(described_class)
      expect(result.png_data).to eq('png_data')
    end

    it 'updates existing raster record' do
      raster = create(:world_terrain_raster, world: world)

      described_class.cache_texture(world, 'new_png_data')

      raster.refresh
      expect(raster.png_data).to eq('new_png_data')
    end

    it 'sets generated_at timestamp' do
      result = described_class.cache_texture(world, 'png_data')
      expect(result.generated_at).not_to be_nil
    end

    it 'handles exceptions gracefully' do
      allow(described_class).to receive(:find_or_create).and_raise(StandardError, 'Test error')

      result = described_class.cache_texture(world, 'png_data')
      expect(result).to be_nil
    end
  end

  describe '.invalidate' do
    it 'clears png_data for all rasters of a world' do
      raster = create(:world_terrain_raster,
                      world: world,
                      png_data: Sequel.blob('data'),
                      generated_at: Time.now)

      described_class.invalidate(world)

      raster.refresh
      expect(raster.png_data).to be_nil
      expect(raster.generated_at).to be_nil
    end
  end

  describe '#to_api_hash' do
    it 'returns hash with expected keys' do
      raster = create(:world_terrain_raster,
                      world: world,
                      png_data: Sequel.blob('test_data'),
                      hex_count: 1000,
                      source_type: 'hexes')

      hash = raster.to_api_hash

      expect(hash[:id]).to eq(raster.id)
      expect(hash[:world_id]).to eq(world.id)
      expect(hash[:resolution]).to eq('4096x2048')
      expect(hash[:hex_count]).to eq(1000)
      expect(hash[:source_type]).to eq('hexes')
      expect(hash[:has_texture]).to be true
      expect(hash[:texture_size]).to eq(9) # 'test_data'.bytesize
    end

    it 'handles nil png_data' do
      raster = create(:world_terrain_raster, world: world, png_data: nil)

      hash = raster.to_api_hash

      expect(hash[:has_texture]).to be false
      expect(hash[:texture_size]).to be_nil
    end
  end
end
