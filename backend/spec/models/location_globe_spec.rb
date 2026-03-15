# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Location do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:zone, world: world) }

  describe '#has_globe_hex?' do
    context 'when globe_hex_id is nil' do
      let(:location) { create(:location, zone: area, globe_hex_id: nil) }

      it 'returns false' do
        expect(location.has_globe_hex?).to be false
      end
    end

    context 'when globe_hex_id is set' do
      let(:location) { create(:location, zone: area, globe_hex_id: 12345, world_id: world.id) }

      it 'returns true' do
        expect(location.has_globe_hex?).to be true
      end
    end
  end

  describe '#world_hex' do
    let(:location) { create(:location, zone: area, globe_hex_id: 99999, world_id: world.id) }

    context 'when no corresponding WorldHex exists' do
      it 'returns nil' do
        expect(location.world_hex).to be_nil
      end
    end

    context 'when corresponding WorldHex exists' do
      let!(:world_hex) { create(:world_hex, world: world, globe_hex_id: 99999) }

      it 'returns the associated WorldHex' do
        expect(location.world_hex).to eq(world_hex)
      end
    end

    context 'when globe_hex_id is nil' do
      let(:location_no_hex) { create(:location, zone: area, globe_hex_id: nil) }

      it 'returns nil' do
        expect(location_no_hex.world_hex).to be_nil
      end
    end

    context 'when world_id is nil' do
      # Build (not create) since validation would fail with globe_hex_id but no world_id
      let(:location_no_world) { build(:location, zone: area, globe_hex_id: 12345, world_id: nil) }

      it 'returns nil' do
        expect(location_no_world.world_hex).to be_nil
      end
    end
  end

  describe '#has_hex_coords? (backward compatibility alias)' do
    context 'when globe_hex_id is nil' do
      let(:location) { create(:location, zone: area, globe_hex_id: nil) }

      it 'returns false (alias for has_globe_hex?)' do
        expect(location.has_hex_coords?).to be false
        expect(location.has_hex_coords?).to eq(location.has_globe_hex?)
      end
    end

    context 'when globe_hex_id is set' do
      let(:location) { create(:location, zone: area, globe_hex_id: 12345, world_id: world.id) }

      it 'returns true (alias for has_globe_hex?)' do
        expect(location.has_hex_coords?).to be true
        expect(location.has_hex_coords?).to eq(location.has_globe_hex?)
      end
    end
  end

  describe 'validation' do
    it 'requires world_id when globe_hex_id is present' do
      loc = build(:location, zone: area, globe_hex_id: 12345, world_id: nil)
      expect(loc).not_to be_valid
      expect(loc.errors[:world_id]).not_to be_empty
    end

    it 'is valid with globe_hex_id and world_id' do
      loc = build(:location, zone: area, globe_hex_id: 12345, world_id: world.id)
      expect(loc).to be_valid
    end

    it 'is valid without globe_hex_id' do
      loc = build(:location, zone: area, globe_hex_id: nil)
      expect(loc).to be_valid
    end
  end
end
