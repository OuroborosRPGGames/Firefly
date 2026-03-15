# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldTerrainConfig do
  describe 'TERRAIN_COLORS' do
    it 'defines terrain colors as a frozen hash' do
      expect(described_class::TERRAIN_COLORS).to be_a(Hash)
      expect(described_class::TERRAIN_COLORS).to be_frozen
    end

    it 'includes expected canonical terrain keys' do
      expect(described_class::TERRAIN_COLORS.keys).to include(
        'ocean', 'lake', 'rocky_coast', 'sandy_coast',
        'grassy_plains', 'light_forest', 'dense_forest',
        'mountain', 'desert', 'urban', 'unknown'
      )
    end

    it 'uses valid hex color values for all entries' do
      described_class::TERRAIN_COLORS.each_value do |color|
        expect(color).to match(/\A#[0-9a-fA-F]{6}\z/)
      end
    end

    it 'uses distinct fallback color for unknown terrain' do
      unknown = described_class::TERRAIN_COLORS['unknown']
      expect(unknown).to eq('#4a4a4a')
      expect(described_class::TERRAIN_COLORS.values.count(unknown)).to eq(1)
    end
  end
end
