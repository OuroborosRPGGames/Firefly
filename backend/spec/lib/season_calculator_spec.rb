# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/lib/season_calculator'

RSpec.describe SeasonCalculator do
  # ========================================
  # Constants
  # ========================================

  describe 'constants' do
    it 'defines BOUNDARIES with astronomical dates' do
      expect(described_class::BOUNDARIES).to include(
        vernal_equinox: 79,
        summer_solstice: 172,
        autumnal_equinox: 265,
        winter_solstice: 355
      )
    end

    it 'defines LATITUDE_BANDS covering 0-90 degrees' do
      expect(described_class::LATITUDE_BANDS.keys).to contain_exactly(
        :tropical, :subtropical, :temperate, :high_latitude, :polar
      )
    end

    it 'defines TRANSITION_DAYS' do
      expect(described_class::TRANSITION_DAYS).to eq(21)
    end

    it 'defines DEFAULT_LATITUDE in temperate zone' do
      expect(described_class::DEFAULT_LATITUDE).to eq(45.0)
    end
  end

  # ========================================
  # Season System Detection
  # ========================================

  describe '.season_system_for' do
    it 'returns :tropical for equatorial latitudes' do
      expect(described_class.season_system_for(0)).to eq(:tropical)
      expect(described_class.season_system_for(10)).to eq(:tropical)
      expect(described_class.season_system_for(23)).to eq(:tropical)
    end

    it 'returns :subtropical for mid-low latitudes' do
      expect(described_class.season_system_for(24)).to eq(:subtropical)
      expect(described_class.season_system_for(30)).to eq(:subtropical)
      expect(described_class.season_system_for(34)).to eq(:subtropical)
    end

    it 'returns :temperate for mid latitudes' do
      expect(described_class.season_system_for(35)).to eq(:temperate)
      expect(described_class.season_system_for(45)).to eq(:temperate)
      expect(described_class.season_system_for(54)).to eq(:temperate)
    end

    it 'returns :high_latitude for sub-polar latitudes' do
      expect(described_class.season_system_for(55)).to eq(:high_latitude)
      expect(described_class.season_system_for(60)).to eq(:high_latitude)
      expect(described_class.season_system_for(66)).to eq(:high_latitude)
    end

    it 'returns :polar for polar latitudes' do
      expect(described_class.season_system_for(67)).to eq(:polar)
      expect(described_class.season_system_for(80)).to eq(:polar)
      expect(described_class.season_system_for(90)).to eq(:polar)
    end

    it 'handles negative latitudes (Southern Hemisphere) the same' do
      expect(described_class.season_system_for(-10)).to eq(:tropical)
      expect(described_class.season_system_for(-45)).to eq(:temperate)
      expect(described_class.season_system_for(-80)).to eq(:polar)
    end
  end

  # ========================================
  # Hemisphere Detection
  # ========================================

  describe '.southern_hemisphere?' do
    it 'returns false for positive latitudes' do
      expect(described_class.southern_hemisphere?(45)).to be false
      expect(described_class.southern_hemisphere?(0.1)).to be false
    end

    it 'returns true for negative latitudes' do
      expect(described_class.southern_hemisphere?(-45)).to be true
      expect(described_class.southern_hemisphere?(-0.1)).to be true
    end

    it 'returns false for exactly 0' do
      expect(described_class.southern_hemisphere?(0)).to be false
    end
  end

  # ========================================
  # Temperate Season Calculation
  # ========================================

  describe '.season_for temperate regions' do
    let(:temperate_latitude) { 45.0 }

    context 'Northern Hemisphere' do
      it 'returns spring after vernal equinox' do
        result = described_class.season_for(day_of_year: 80, latitude: temperate_latitude)
        expect(result[:season]).to eq(:spring)
        expect(result[:raw_season]).to eq(:spring)
        expect(result[:system]).to eq(:temperate)
      end

      it 'returns summer after summer solstice' do
        result = described_class.season_for(day_of_year: 180, latitude: temperate_latitude)
        expect(result[:season]).to eq(:summer)
        expect(result[:raw_season]).to eq(:summer)
      end

      it 'returns fall after autumnal equinox' do
        result = described_class.season_for(day_of_year: 270, latitude: temperate_latitude)
        expect(result[:season]).to eq(:fall)
        expect(result[:raw_season]).to eq(:fall)
      end

      it 'returns winter after winter solstice' do
        result = described_class.season_for(day_of_year: 360, latitude: temperate_latitude)
        expect(result[:season]).to eq(:winter)
        expect(result[:raw_season]).to eq(:winter)
      end

      it 'returns winter in early January' do
        result = described_class.season_for(day_of_year: 15, latitude: temperate_latitude)
        expect(result[:season]).to eq(:winter)
      end
    end

    context 'Southern Hemisphere (inverted seasons)' do
      let(:southern_latitude) { -45.0 }

      it 'returns fall when Northern is spring' do
        result = described_class.season_for(day_of_year: 100, latitude: southern_latitude)
        expect(result[:season]).to eq(:fall)
        expect(result[:raw_season]).to eq(:fall)
      end

      it 'returns winter when Northern is summer' do
        result = described_class.season_for(day_of_year: 180, latitude: southern_latitude)
        expect(result[:season]).to eq(:winter)
        expect(result[:raw_season]).to eq(:winter)
      end

      it 'returns spring when Northern is fall' do
        result = described_class.season_for(day_of_year: 270, latitude: southern_latitude)
        expect(result[:season]).to eq(:spring)
        expect(result[:raw_season]).to eq(:spring)
      end

      it 'returns summer when Northern is winter' do
        result = described_class.season_for(day_of_year: 360, latitude: southern_latitude)
        expect(result[:season]).to eq(:summer)
        expect(result[:raw_season]).to eq(:summer)
      end
    end
  end

  # ========================================
  # Season Progress
  # ========================================

  describe 'season progress' do
    let(:temperate_latitude) { 45.0 }

    it 'returns 0.0 progress at season start' do
      # Day 79 is vernal equinox (spring start)
      result = described_class.season_for(day_of_year: 79, latitude: temperate_latitude)
      expect(result[:progress]).to eq(0.0)
    end

    it 'returns progress between 0 and 1' do
      # Mid-spring
      result = described_class.season_for(day_of_year: 120, latitude: temperate_latitude)
      expect(result[:progress]).to be_between(0.3, 0.6)
    end

    it 'returns progress approaching 1.0 near season end' do
      # Late spring (day before summer solstice)
      result = described_class.season_for(day_of_year: 171, latitude: temperate_latitude)
      expect(result[:progress]).to be > 0.9
    end
  end

  # ========================================
  # Season Intensity
  # ========================================

  describe 'season intensity' do
    let(:temperate_latitude) { 45.0 }

    it 'returns :early for progress < 0.33' do
      # Early spring
      result = described_class.season_for(day_of_year: 85, latitude: temperate_latitude)
      expect(result[:intensity]).to eq(:early)
    end

    it 'returns :mid for progress between 0.33 and 0.67' do
      # Mid-spring
      result = described_class.season_for(day_of_year: 120, latitude: temperate_latitude)
      expect(result[:intensity]).to eq(:mid)
    end

    it 'returns :late for progress > 0.67' do
      # Late spring
      result = described_class.season_for(day_of_year: 165, latitude: temperate_latitude)
      expect(result[:intensity]).to eq(:late)
    end
  end

  # ========================================
  # Transition Detection
  # ========================================

  describe 'in_transition flag' do
    let(:temperate_latitude) { 45.0 }

    it 'returns true near season boundaries' do
      # Just after spring equinox
      result = described_class.season_for(day_of_year: 85, latitude: temperate_latitude)
      expect(result[:in_transition]).to be true
    end

    it 'returns false in mid-season' do
      # Mid-summer
      result = described_class.season_for(day_of_year: 220, latitude: temperate_latitude)
      expect(result[:in_transition]).to be false
    end
  end

  # ========================================
  # Tropical Season Calculation
  # ========================================

  describe '.season_for tropical regions' do
    let(:northern_tropical) { 10.0 }
    let(:southern_tropical) { -10.0 }

    context 'Northern Hemisphere tropics' do
      it 'returns wet season around July (peak monsoon)' do
        result = described_class.season_for(day_of_year: 196, latitude: northern_tropical)
        expect(result[:raw_season]).to eq(:wet)
        expect(result[:season]).to eq(:summer) # mapped
        expect(result[:system]).to eq(:tropical)
      end

      it 'returns dry season around January' do
        result = described_class.season_for(day_of_year: 15, latitude: northern_tropical)
        expect(result[:raw_season]).to eq(:dry)
        expect(result[:season]).to eq(:winter) # mapped
      end
    end

    context 'Southern Hemisphere tropics' do
      it 'returns wet season around January (peak monsoon)' do
        result = described_class.season_for(day_of_year: 15, latitude: southern_tropical)
        expect(result[:raw_season]).to eq(:wet)
        expect(result[:season]).to eq(:summer) # mapped
      end

      it 'returns dry season around July' do
        result = described_class.season_for(day_of_year: 196, latitude: southern_tropical)
        expect(result[:raw_season]).to eq(:dry)
        expect(result[:season]).to eq(:winter) # mapped
      end
    end
  end

  # ========================================
  # Polar Season Calculation
  # ========================================

  describe '.season_for polar regions' do
    let(:arctic_latitude) { 80.0 }
    let(:antarctic_latitude) { -80.0 }

    context 'Arctic' do
      it 'returns polar_day around summer solstice' do
        result = described_class.season_for(day_of_year: 172, latitude: arctic_latitude)
        expect(result[:raw_season]).to eq(:polar_day)
        expect(result[:season]).to eq(:summer) # mapped
        expect(result[:system]).to eq(:polar)
      end

      it 'returns polar_night around winter solstice' do
        result = described_class.season_for(day_of_year: 355, latitude: arctic_latitude)
        expect(result[:raw_season]).to eq(:polar_night)
        expect(result[:season]).to eq(:winter) # mapped
      end
    end

    context 'Antarctic' do
      it 'returns polar_day around winter solstice (Southern summer)' do
        result = described_class.season_for(day_of_year: 355, latitude: antarctic_latitude)
        expect(result[:raw_season]).to eq(:polar_day)
        expect(result[:season]).to eq(:summer) # mapped
      end

      it 'returns polar_night around summer solstice (Southern winter)' do
        result = described_class.season_for(day_of_year: 172, latitude: antarctic_latitude)
        expect(result[:raw_season]).to eq(:polar_night)
        expect(result[:season]).to eq(:winter) # mapped
      end
    end
  end

  # ========================================
  # Map to Temperate
  # ========================================

  describe '.map_to_temperate' do
    it 'maps wet to summer' do
      expect(described_class.map_to_temperate(:wet)).to eq(:summer)
    end

    it 'maps dry to winter' do
      expect(described_class.map_to_temperate(:dry)).to eq(:winter)
    end

    it 'maps polar_day to summer' do
      expect(described_class.map_to_temperate(:polar_day)).to eq(:summer)
    end

    it 'maps polar_night to winter' do
      expect(described_class.map_to_temperate(:polar_night)).to eq(:winter)
    end

    it 'passes through standard temperate seasons unchanged' do
      expect(described_class.map_to_temperate(:spring)).to eq(:spring)
      expect(described_class.map_to_temperate(:summer)).to eq(:summer)
      expect(described_class.map_to_temperate(:fall)).to eq(:fall)
      expect(described_class.map_to_temperate(:winter)).to eq(:winter)
    end
  end

  # ========================================
  # Edge Cases
  # ========================================

  describe 'edge cases' do
    it 'clamps day_of_year to valid range' do
      result_low = described_class.season_for(day_of_year: -5, latitude: 45.0)
      result_high = described_class.season_for(day_of_year: 400, latitude: 45.0)

      expect(result_low[:season]).to be_a(Symbol)
      expect(result_high[:season]).to be_a(Symbol)
    end

    it 'clamps latitude to valid range' do
      result_low = described_class.season_for(day_of_year: 100, latitude: -100.0)
      result_high = described_class.season_for(day_of_year: 100, latitude: 100.0)

      expect(result_low[:system]).to eq(:polar)
      expect(result_high[:system]).to eq(:polar)
    end

    it 'uses default latitude when not provided' do
      result = described_class.season_for(day_of_year: 100)
      expect(result[:system]).to eq(:temperate)
    end
  end

  # ========================================
  # Boundaries for Year
  # ========================================

  describe '.boundaries_for_year' do
    it 'returns boundaries for non-leap year' do
      bounds = described_class.boundaries_for_year(2023)
      expect(bounds[:vernal_equinox]).to eq(79)
    end

    it 'adjusts boundaries for leap year' do
      bounds = described_class.boundaries_for_year(2024)
      expect(bounds[:vernal_equinox]).to eq(80)
    end
  end
end
