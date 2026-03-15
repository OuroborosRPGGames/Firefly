# frozen_string_literal: true

require 'spec_helper'
require_relative '../../../app/services/world_generation/preset_config'

RSpec.describe WorldGeneration::PresetConfig do
  describe 'PRESETS constant' do
    it 'defines 6 planet presets' do
      expect(described_class::PRESETS.keys.count).to eq(6)
    end

    it 'includes all required preset keys' do
      expected_keys = %i[earth_like pangaea archipelago ice_age waterworld arid]
      expect(described_class::PRESETS.keys).to match_array(expected_keys)
    end

    describe 'earth_like preset' do
      subject(:preset) { described_class::PRESETS[:earth_like] }

      it 'has correct name' do
        expect(preset[:name]).to eq('Earth-like')
      end

      it 'has a description' do
        expect(preset[:description]).to include('continent')
      end

      it 'has ~70% ocean coverage' do
        expect(preset[:ocean_coverage]).to eq(0.70)
      end

      it 'has 10-14 plates' do
        expect(preset[:plate_count]).to eq(10..14)
      end

      it 'has 0.4 continental ratio' do
        expect(preset[:continental_ratio]).to eq(0.4)
      end

      it 'has 1.0 mountain intensity' do
        expect(preset[:mountain_intensity]).to eq(1.0)
      end

      it 'has 50-80 river sources' do
        expect(preset[:river_sources]).to eq(50..80)
      end

      it 'has 1.0 temperature variance' do
        expect(preset[:temperature_variance]).to eq(1.0)
      end

      it 'has 0.10 ice cap size' do
        expect(preset[:ice_cap_size]).to eq(0.10)
      end

      it 'has 1.0 moisture modifier' do
        expect(preset[:moisture_modifier]).to eq(1.0)
      end
    end

    describe 'pangaea preset' do
      subject(:preset) { described_class::PRESETS[:pangaea] }

      it 'has lower ocean coverage for supercontinent' do
        expect(preset[:ocean_coverage]).to eq(0.55)
      end

      it 'has fewer plates' do
        expect(preset[:plate_count]).to eq(3..5)
      end

      it 'has high continental ratio' do
        expect(preset[:continental_ratio]).to eq(0.7)
      end
    end

    describe 'archipelago preset' do
      subject(:preset) { described_class::PRESETS[:archipelago] }

      it 'has high ocean coverage' do
        expect(preset[:ocean_coverage]).to eq(0.85)
      end

      it 'has many small plates' do
        expect(preset[:plate_count]).to eq(18..25)
      end

      it 'has low continental ratio' do
        expect(preset[:continental_ratio]).to eq(0.2)
      end
    end

    describe 'ice_age preset' do
      subject(:preset) { described_class::PRESETS[:ice_age] }

      it 'has moderate ocean coverage' do
        expect(preset[:ocean_coverage]).to eq(0.55)
      end

      it 'has large ice caps' do
        expect(preset[:ice_cap_size]).to eq(0.35)
      end

      it 'has high temperature variance' do
        expect(preset[:temperature_variance]).to eq(1.4)
      end
    end

    describe 'waterworld preset' do
      subject(:preset) { described_class::PRESETS[:waterworld] }

      it 'has very high ocean coverage' do
        expect(preset[:ocean_coverage]).to eq(0.92)
      end

      it 'has moderate plate count' do
        expect(preset[:plate_count]).to eq(6..10)
      end

      it 'has high moisture modifier' do
        expect(preset[:moisture_modifier]).to eq(1.5)
      end
    end

    describe 'arid preset' do
      subject(:preset) { described_class::PRESETS[:arid] }

      it 'has low ocean coverage' do
        expect(preset[:ocean_coverage]).to eq(0.45)
      end

      it 'has low moisture modifier' do
        expect(preset[:moisture_modifier]).to eq(0.4)
      end

      it 'has moderate plate count' do
        expect(preset[:plate_count]).to eq(6..9)
      end
    end

    describe 'all presets have required keys' do
      let(:required_keys) do
        %i[name description ocean_coverage plate_count continental_ratio
           mountain_intensity river_sources temperature_variance
           ice_cap_size moisture_modifier]
      end

      described_class::PRESETS.each do |preset_key, preset_data|
        context "#{preset_key} preset" do
          it 'contains all required configuration keys' do
            expect(preset_data.keys).to include(*required_keys)
          end
        end
      end
    end
  end

  describe '.for' do
    it 'returns the preset hash for a valid key' do
      preset = described_class.for(:earth_like)
      expect(preset[:name]).to eq('Earth-like')
    end

    it 'accepts string keys' do
      preset = described_class.for('pangaea')
      expect(preset[:name]).to eq('Pangaea')
    end

    it 'falls back to earth_like for unknown presets' do
      preset = described_class.for(:unknown_planet)
      expect(preset[:name]).to eq('Earth-like')
    end

    it 'falls back to earth_like for nil' do
      preset = described_class.for(nil)
      expect(preset[:name]).to eq('Earth-like')
    end
  end

  describe '.all_presets' do
    it 'returns the full PRESETS hash' do
      expect(described_class.all_presets).to eq(described_class::PRESETS)
    end

    it 'is frozen to prevent modification' do
      expect(described_class.all_presets).to be_frozen
    end
  end

  describe '.preset_options_for_ui' do
    subject(:options) { described_class.preset_options_for_ui }

    it 'returns an array' do
      expect(options).to be_an(Array)
    end

    it 'returns 6 options' do
      expect(options.count).to eq(6)
    end

    it 'each option has id, name, and description' do
      options.each do |option|
        expect(option).to have_key(:id)
        expect(option).to have_key(:name)
        expect(option).to have_key(:description)
      end
    end

    it 'includes earth_like option' do
      earth_like = options.find { |o| o[:id] == :earth_like }
      expect(earth_like).not_to be_nil
      expect(earth_like[:name]).to eq('Earth-like')
    end

    it 'orders earth_like first' do
      expect(options.first[:id]).to eq(:earth_like)
    end
  end

  describe '.valid_preset?' do
    it 'returns true for valid preset symbols' do
      expect(described_class.valid_preset?(:earth_like)).to be(true)
      expect(described_class.valid_preset?(:pangaea)).to be(true)
      expect(described_class.valid_preset?(:archipelago)).to be(true)
    end

    it 'returns true for valid preset strings' do
      expect(described_class.valid_preset?('earth_like')).to be(true)
      expect(described_class.valid_preset?('ice_age')).to be(true)
    end

    it 'returns false for invalid presets' do
      expect(described_class.valid_preset?(:invalid)).to be(false)
      expect(described_class.valid_preset?('unknown')).to be(false)
    end

    it 'returns false for nil' do
      expect(described_class.valid_preset?(nil)).to be(false)
    end
  end
end
