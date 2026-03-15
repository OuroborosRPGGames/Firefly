# frozen_string_literal: true

require 'spec_helper'
require_relative '../../app/lib/sun_calculator'

RSpec.describe SunCalculator do
  # ========================================
  # Constants
  # ========================================

  describe 'constants' do
    it 'defines DEGREES_TO_RADIANS' do
      expect(described_class::DEGREES_TO_RADIANS).to be_within(0.0001).of(Math::PI / 180.0)
    end

    it 'defines RADIANS_TO_DEGREES' do
      expect(described_class::RADIANS_TO_DEGREES).to be_within(0.0001).of(180.0 / Math::PI)
    end

    it 'defines SOLAR_ZENITH for civil twilight' do
      expect(described_class::SOLAR_ZENITH).to eq(90.833)
    end
  end

  # ========================================
  # Sunrise/Sunset Calculations
  # ========================================

  describe '.sunrise_sunset' do
    context 'at temperate latitude (45°N) on summer solstice (day 172)' do
      let(:result) do
        described_class.sunrise_sunset(
          latitude: 45.0,
          longitude: 0.0,
          day_of_year: 172,
          timezone_offset_hours: 0
        )
      end

      it 'returns normal status' do
        expect(result[:status]).to eq(:normal)
      end

      it 'returns early sunrise (around 4-6 AM UTC)' do
        expect(result[:sunrise]).to be_between(4.0, 6.0)
      end

      it 'returns late sunset (around 19-21 UTC)' do
        expect(result[:sunset]).to be_between(19.0, 21.0)
      end

      it 'has longer days in summer' do
        day_length = result[:sunset] - result[:sunrise]
        expect(day_length).to be > 14.0 # More than 14 hours of daylight
      end
    end

    context 'at temperate latitude (45°N) on winter solstice (day 355)' do
      let(:result) do
        described_class.sunrise_sunset(
          latitude: 45.0,
          longitude: 0.0,
          day_of_year: 355,
          timezone_offset_hours: 0
        )
      end

      it 'returns normal status' do
        expect(result[:status]).to eq(:normal)
      end

      it 'returns late sunrise (around 7-9 AM UTC)' do
        expect(result[:sunrise]).to be_between(7.0, 9.0)
      end

      it 'returns early sunset (around 15-17 UTC)' do
        expect(result[:sunset]).to be_between(15.0, 17.0)
      end

      it 'has shorter days in winter' do
        day_length = result[:sunset] - result[:sunrise]
        expect(day_length).to be < 10.0 # Less than 10 hours of daylight
      end
    end

    context 'at equator (0°) on equinox' do
      let(:result) do
        described_class.sunrise_sunset(
          latitude: 0.0,
          longitude: 0.0,
          day_of_year: 79,
          timezone_offset_hours: 0
        )
      end

      it 'returns normal status' do
        expect(result[:status]).to eq(:normal)
      end

      it 'has approximately 12-hour days year-round' do
        day_length = result[:sunset] - result[:sunrise]
        expect(day_length).to be_within(0.5).of(12.0)
      end

      it 'has sunrise around 6 AM' do
        expect(result[:sunrise]).to be_within(0.5).of(6.0)
      end

      it 'has sunset around 18:00' do
        expect(result[:sunset]).to be_within(0.5).of(18.0)
      end
    end

    context 'with timezone offset' do
      let(:result_utc) do
        described_class.sunrise_sunset(
          latitude: 45.0,
          longitude: -93.0, # Minneapolis
          day_of_year: 172,
          timezone_offset_hours: 0
        )
      end

      let(:result_cst) do
        described_class.sunrise_sunset(
          latitude: 45.0,
          longitude: -93.0,
          day_of_year: 172,
          timezone_offset_hours: -6 # Central Standard Time
        )
      end

      it 'adjusts sunrise by timezone offset' do
        diff = result_cst[:sunrise] - result_utc[:sunrise]
        # Result should differ by timezone offset (with potential day wraparound)
        expect((diff + 24) % 24).to be_within(0.1).of(18.0) # -6 hours = +18 mod 24
      end

      it 'adjusts sunset by timezone offset' do
        diff = result_cst[:sunset] - result_utc[:sunset]
        expect((diff + 24) % 24).to be_within(0.1).of(18.0)
      end
    end

    context 'polar regions - midnight sun' do
      let(:result) do
        described_class.sunrise_sunset(
          latitude: 80.0,
          longitude: 0.0,
          day_of_year: 172, # Summer solstice
          timezone_offset_hours: 0
        )
      end

      it 'returns midnight_sun status' do
        expect(result[:status]).to eq(:midnight_sun)
      end

      it 'returns nil for sunrise' do
        expect(result[:sunrise]).to be_nil
      end

      it 'returns nil for sunset' do
        expect(result[:sunset]).to be_nil
      end
    end

    context 'polar regions - polar night' do
      let(:result) do
        described_class.sunrise_sunset(
          latitude: 80.0,
          longitude: 0.0,
          day_of_year: 355, # Winter solstice
          timezone_offset_hours: 0
        )
      end

      it 'returns polar_night status' do
        expect(result[:status]).to eq(:polar_night)
      end

      it 'returns nil for sunrise' do
        expect(result[:sunrise]).to be_nil
      end

      it 'returns nil for sunset' do
        expect(result[:sunset]).to be_nil
      end
    end

    context 'southern hemisphere' do
      let(:summer_result) do
        described_class.sunrise_sunset(
          latitude: -45.0, # Sydney-ish
          longitude: 0.0,
          day_of_year: 355, # December = summer in southern hemisphere
          timezone_offset_hours: 0
        )
      end

      let(:winter_result) do
        described_class.sunrise_sunset(
          latitude: -45.0,
          longitude: 0.0,
          day_of_year: 172, # June = winter in southern hemisphere
          timezone_offset_hours: 0
        )
      end

      it 'has longer days in December (southern summer)' do
        summer_day = summer_result[:sunset] - summer_result[:sunrise]
        winter_day = winter_result[:sunset] - winter_result[:sunrise]
        expect(summer_day).to be > winter_day
      end
    end

    context 'input clamping' do
      it 'clamps latitude to -90..90' do
        result = described_class.sunrise_sunset(
          latitude: 100.0, # Invalid
          longitude: 0.0,
          day_of_year: 172
        )
        expect(result[:status]).to eq(:midnight_sun) # At 90°N in summer
      end

      it 'clamps longitude to -180..180' do
        result1 = described_class.sunrise_sunset(
          latitude: 45.0,
          longitude: 200.0, # Invalid, should clamp to 180
          day_of_year: 172
        )
        result2 = described_class.sunrise_sunset(
          latitude: 45.0,
          longitude: 180.0,
          day_of_year: 172
        )
        expect(result1[:sunrise]).to eq(result2[:sunrise])
      end

      it 'clamps day_of_year to 1..366' do
        result1 = described_class.sunrise_sunset(
          latitude: 45.0,
          longitude: 0.0,
          day_of_year: 400 # Invalid
        )
        result2 = described_class.sunrise_sunset(
          latitude: 45.0,
          longitude: 0.0,
          day_of_year: 366
        )
        expect(result1[:sunrise]).to eq(result2[:sunrise])
      end
    end
  end

  # ========================================
  # Day Length Calculations
  # ========================================

  describe '.day_length' do
    context 'normal conditions' do
      it 'returns day length in hours' do
        length = described_class.day_length(
          latitude: 45.0,
          longitude: 0.0,
          day_of_year: 172
        )
        expect(length).to be_between(14.0, 17.0)
      end

      it 'returns shorter days in winter' do
        summer = described_class.day_length(latitude: 45.0, longitude: 0.0, day_of_year: 172)
        winter = described_class.day_length(latitude: 45.0, longitude: 0.0, day_of_year: 355)
        expect(summer).to be > winter
      end
    end

    context 'polar conditions' do
      it 'returns 24.0 for midnight sun' do
        length = described_class.day_length(
          latitude: 80.0,
          longitude: 0.0,
          day_of_year: 172
        )
        expect(length).to eq(24.0)
      end

      it 'returns 0.0 for polar night' do
        length = described_class.day_length(
          latitude: 80.0,
          longitude: 0.0,
          day_of_year: 355
        )
        expect(length).to eq(0.0)
      end
    end

    context 'at equator' do
      it 'returns approximately 12 hours year-round' do
        spring = described_class.day_length(latitude: 0.0, longitude: 0.0, day_of_year: 79)
        summer = described_class.day_length(latitude: 0.0, longitude: 0.0, day_of_year: 172)
        fall = described_class.day_length(latitude: 0.0, longitude: 0.0, day_of_year: 265)
        winter = described_class.day_length(latitude: 0.0, longitude: 0.0, day_of_year: 355)

        [spring, summer, fall, winter].each do |length|
          expect(length).to be_within(0.5).of(12.0)
        end
      end
    end
  end

  # ========================================
  # Solar Noon Calculations
  # ========================================

  describe '.solar_noon' do
    it 'returns solar noon at approximately 12:00 for longitude 0' do
      noon = described_class.solar_noon(
        longitude: 0.0,
        day_of_year: 172,
        timezone_offset_hours: 0
      )
      expect(noon).to be_within(0.5).of(12.0)
    end

    it 'shifts solar noon earlier for eastern longitudes' do
      noon_0 = described_class.solar_noon(longitude: 0.0, day_of_year: 172)
      noon_90e = described_class.solar_noon(longitude: 90.0, day_of_year: 172)
      expect(noon_90e).to be < noon_0
    end

    it 'shifts solar noon later for western longitudes' do
      noon_0 = described_class.solar_noon(longitude: 0.0, day_of_year: 172)
      noon_90w = described_class.solar_noon(longitude: -90.0, day_of_year: 172)
      expect(noon_90w).to be > noon_0
    end

    it 'adjusts for timezone offset' do
      noon_utc = described_class.solar_noon(
        longitude: -90.0,
        day_of_year: 172,
        timezone_offset_hours: 0
      )
      noon_local = described_class.solar_noon(
        longitude: -90.0,
        day_of_year: 172,
        timezone_offset_hours: -6
      )
      # Local time should be closer to 12:00
      expect((noon_local - 12.0).abs).to be < (noon_utc - 12.0).abs
    end
  end

  # ========================================
  # Seasonal Variation Tests
  # ========================================

  describe 'seasonal variation at various latitudes' do
    it 'shows greater day length variation at higher latitudes' do
      # At 60°N
      summer_60 = described_class.day_length(latitude: 60.0, longitude: 0.0, day_of_year: 172)
      winter_60 = described_class.day_length(latitude: 60.0, longitude: 0.0, day_of_year: 355)
      variation_60 = summer_60 - winter_60

      # At 30°N
      summer_30 = described_class.day_length(latitude: 30.0, longitude: 0.0, day_of_year: 172)
      winter_30 = described_class.day_length(latitude: 30.0, longitude: 0.0, day_of_year: 355)
      variation_30 = summer_30 - winter_30

      expect(variation_60).to be > variation_30
    end

    it 'has minimal variation at equator' do
      summer = described_class.day_length(latitude: 0.0, longitude: 0.0, day_of_year: 172)
      winter = described_class.day_length(latitude: 0.0, longitude: 0.0, day_of_year: 355)
      variation = (summer - winter).abs
      expect(variation).to be < 0.5
    end
  end
end
