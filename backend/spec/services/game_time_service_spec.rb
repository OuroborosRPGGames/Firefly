# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GameTimeService do
  # ========================================
  # Constants
  # ========================================

  describe 'constants' do
    it 'defines TIME_PERIODS' do
      expect(GameTimeService::TIME_PERIODS).to eq(%i[dawn day dusk night])
    end

    it 'defines SEASONS' do
      expect(GameTimeService::SEASONS).to eq(%i[spring summer fall winter])
    end

    it 'defines TIME_NAME_MAP' do
      expect(GameTimeService::TIME_NAME_MAP).to include(
        'morning' => :dawn,
        'afternoon' => :day,
        'evening' => :dusk,
        'night' => :night,
        'dawn' => :dawn,
        'day' => :day,
        'dusk' => :dusk
      )
    end
  end

  # ========================================
  # Time Normalization
  # ========================================

  describe '.normalize_time_name' do
    it 'normalizes morning to dawn' do
      expect(described_class.normalize_time_name('morning')).to eq(:dawn)
    end

    it 'normalizes afternoon to day' do
      expect(described_class.normalize_time_name('afternoon')).to eq(:day)
    end

    it 'normalizes evening to dusk' do
      expect(described_class.normalize_time_name('evening')).to eq(:dusk)
    end

    it 'normalizes night to night' do
      expect(described_class.normalize_time_name('night')).to eq(:night)
    end

    it 'handles uppercase input' do
      expect(described_class.normalize_time_name('MORNING')).to eq(:dawn)
    end

    it 'handles mixed case input' do
      expect(described_class.normalize_time_name('Morning')).to eq(:dawn)
    end

    it 'handles input with whitespace' do
      expect(described_class.normalize_time_name('  morning  ')).to eq(:dawn)
    end

    it 'returns nil for nil input' do
      expect(described_class.normalize_time_name(nil)).to be_nil
    end

    it 'returns nil for empty string' do
      expect(described_class.normalize_time_name('')).to be_nil
    end

    it 'returns nil for whitespace only' do
      expect(described_class.normalize_time_name('   ')).to be_nil
    end

    it 'returns nil for dash' do
      expect(described_class.normalize_time_name('-')).to be_nil
    end

    it 'returns nil for invalid time name' do
      expect(described_class.normalize_time_name('midnight')).to be_nil
    end

    it 'handles symbols' do
      expect(described_class.normalize_time_name(:morning)).to eq(:dawn)
    end
  end

  # ========================================
  # Season Normalization
  # ========================================

  describe '.normalize_season_name' do
    it 'normalizes spring' do
      expect(described_class.normalize_season_name('spring')).to eq(:spring)
    end

    it 'normalizes summer' do
      expect(described_class.normalize_season_name('summer')).to eq(:summer)
    end

    it 'normalizes fall' do
      expect(described_class.normalize_season_name('fall')).to eq(:fall)
    end

    it 'normalizes winter' do
      expect(described_class.normalize_season_name('winter')).to eq(:winter)
    end

    it 'handles uppercase input' do
      expect(described_class.normalize_season_name('SPRING')).to eq(:spring)
    end

    it 'handles mixed case input' do
      expect(described_class.normalize_season_name('Spring')).to eq(:spring)
    end

    it 'handles input with whitespace' do
      expect(described_class.normalize_season_name('  spring  ')).to eq(:spring)
    end

    it 'returns nil for nil input' do
      expect(described_class.normalize_season_name(nil)).to be_nil
    end

    it 'returns nil for empty string' do
      expect(described_class.normalize_season_name('')).to be_nil
    end

    it 'returns nil for whitespace only' do
      expect(described_class.normalize_season_name('   ')).to be_nil
    end

    it 'returns nil for dash' do
      expect(described_class.normalize_season_name('-')).to be_nil
    end

    it 'returns nil for invalid season name' do
      expect(described_class.normalize_season_name('autumn')).to be_nil
    end

    it 'handles symbols' do
      expect(described_class.normalize_season_name(:spring)).to eq(:spring)
    end
  end

  # ========================================
  # Current Time (without location)
  # ========================================

  describe '.current_time' do
    context 'without location' do
      it 'returns current time' do
        now = Time.now
        result = described_class.current_time
        # Allow 2 seconds tolerance
        expect(result).to be_within(2).of(now)
      end

      it 'returns a Time object' do
        expect(described_class.current_time).to be_a(Time)
      end
    end
  end

  # ========================================
  # Time of Day
  # ========================================

  describe '.time_of_day' do
    context 'without location' do
      it 'returns a valid time period symbol' do
        result = described_class.time_of_day
        expect(GameTimeService::TIME_PERIODS).to include(result)
      end
    end

    context 'with mocked time' do
      before do
        # Use default sunrise (6) and sunset (18)
        allow(described_class).to receive(:sunrise_hour).and_return(6)
        allow(described_class).to receive(:sunset_hour).and_return(18)
      end

      it 'returns :dawn at sunrise hour' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15, 6, 0))
        expect(described_class.time_of_day).to eq(:dawn)
      end

      it 'returns :dawn at sunrise hour + 30 min' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15, 6, 25))
        expect(described_class.time_of_day).to eq(:dawn)
      end

      it 'returns :day during midday' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15, 12, 0))
        expect(described_class.time_of_day).to eq(:day)
      end

      it 'returns :dusk at sunset hour' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15, 18, 0))
        expect(described_class.time_of_day).to eq(:dusk)
      end

      it 'returns :dusk at sunset hour + 30 min' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15, 18, 25))
        expect(described_class.time_of_day).to eq(:dusk)
      end

      it 'returns :night after dusk period' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15, 20, 0))
        expect(described_class.time_of_day).to eq(:night)
      end

      it 'returns :night before dawn' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15, 3, 0))
        expect(described_class.time_of_day).to eq(:night)
      end
    end
  end

  # ========================================
  # Season
  # ========================================

  describe '.season' do
    context 'without location' do
      it 'returns a valid season symbol' do
        result = described_class.season
        expect(GameTimeService::SEASONS).to include(result)
      end
    end

    # Tests now use astronomical boundaries (solstices/equinoxes) instead of month-based:
    # Spring: ~Mar 20 (day 79) to ~Jun 20 (day 171)
    # Summer: ~Jun 21 (day 172) to ~Sep 21 (day 264)
    # Fall: ~Sep 22 (day 265) to ~Dec 20 (day 354)
    # Winter: ~Dec 21 (day 355) to ~Mar 19 (day 78)
    context 'with mocked time (astronomical boundaries)' do
      it 'returns :spring after vernal equinox (late March)' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 3, 25))
        expect(described_class.season).to eq(:spring)
      end

      it 'returns :spring for April' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 4, 15))
        expect(described_class.season).to eq(:spring)
      end

      it 'returns :spring for May' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 5, 15))
        expect(described_class.season).to eq(:spring)
      end

      it 'returns :spring for early June (before solstice)' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15))
        expect(described_class.season).to eq(:spring)
      end

      it 'returns :summer after summer solstice (late June)' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 25))
        expect(described_class.season).to eq(:summer)
      end

      it 'returns :summer for July' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 7, 15))
        expect(described_class.season).to eq(:summer)
      end

      it 'returns :summer for August' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 8, 15))
        expect(described_class.season).to eq(:summer)
      end

      it 'returns :summer for early September (before equinox)' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 9, 15))
        expect(described_class.season).to eq(:summer)
      end

      it 'returns :fall after autumnal equinox (late September)' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 9, 25))
        expect(described_class.season).to eq(:fall)
      end

      it 'returns :fall for October' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 10, 15))
        expect(described_class.season).to eq(:fall)
      end

      it 'returns :fall for November' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 11, 15))
        expect(described_class.season).to eq(:fall)
      end

      it 'returns :fall for early December (before solstice)' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 12, 15))
        expect(described_class.season).to eq(:fall)
      end

      it 'returns :winter after winter solstice (late December)' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 12, 25))
        expect(described_class.season).to eq(:winter)
      end

      it 'returns :winter for January' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 1, 15))
        expect(described_class.season).to eq(:winter)
      end

      it 'returns :winter for February' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 2, 15))
        expect(described_class.season).to eq(:winter)
      end

      it 'returns :winter for early March (before equinox)' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 3, 15))
        expect(described_class.season).to eq(:winter)
      end
    end
  end

  # ========================================
  # Time Season Key
  # ========================================

  describe '.time_season_key' do
    it 'returns combined time and season key' do
      allow(described_class).to receive(:time_of_day).and_return(:dawn)
      allow(described_class).to receive(:season).and_return(:spring)
      expect(described_class.time_season_key).to eq('dawn_spring')
    end

    it 'returns different key for different time/season combos' do
      allow(described_class).to receive(:time_of_day).and_return(:night)
      allow(described_class).to receive(:season).and_return(:winter)
      expect(described_class.time_season_key).to eq('night_winter')
    end
  end

  # ========================================
  # Season Description
  # ========================================

  describe '.season_description' do
    it 'returns description for spring' do
      allow(described_class).to receive(:season_detail).and_return({
                                                                     season: :spring,
                                                                     raw_season: :spring,
                                                                     system: :temperate,
                                                                     progress: 0.5,
                                                                     intensity: :mid
                                                                   })
      expect(described_class.season_description).to include('spring')
    end

    it 'returns description for summer' do
      allow(described_class).to receive(:season_detail).and_return({
                                                                     season: :summer,
                                                                     raw_season: :summer,
                                                                     system: :temperate,
                                                                     progress: 0.5,
                                                                     intensity: :mid
                                                                   })
      expect(described_class.season_description).to include('summer')
    end

    it 'returns description for fall' do
      allow(described_class).to receive(:season_detail).and_return({
                                                                     season: :fall,
                                                                     raw_season: :fall,
                                                                     system: :temperate,
                                                                     progress: 0.5,
                                                                     intensity: :mid
                                                                   })
      expect(described_class.season_description).to include('autumn')
    end

    it 'returns description for winter' do
      allow(described_class).to receive(:season_detail).and_return({
                                                                     season: :winter,
                                                                     raw_season: :winter,
                                                                     system: :temperate,
                                                                     progress: 0.5,
                                                                     intensity: :mid
                                                                   })
      expect(described_class.season_description).to include('winter')
    end
  end

  # ========================================
  # Night/Day Checks
  # ========================================

  describe '.night?' do
    it 'returns true when time_of_day is :night' do
      allow(described_class).to receive(:time_of_day).and_return(:night)
      expect(described_class.night?).to be true
    end

    it 'returns true when time_of_day is :dusk' do
      allow(described_class).to receive(:time_of_day).and_return(:dusk)
      expect(described_class.night?).to be true
    end

    it 'returns false when time_of_day is :day' do
      allow(described_class).to receive(:time_of_day).and_return(:day)
      expect(described_class.night?).to be false
    end

    it 'returns false when time_of_day is :dawn' do
      allow(described_class).to receive(:time_of_day).and_return(:dawn)
      expect(described_class.night?).to be false
    end
  end

  describe '.day?' do
    it 'returns true when time_of_day is :day' do
      allow(described_class).to receive(:time_of_day).and_return(:day)
      expect(described_class.day?).to be true
    end

    it 'returns true when time_of_day is :dawn' do
      allow(described_class).to receive(:time_of_day).and_return(:dawn)
      expect(described_class.day?).to be true
    end

    it 'returns false when time_of_day is :night' do
      allow(described_class).to receive(:time_of_day).and_return(:night)
      expect(described_class.day?).to be false
    end

    it 'returns false when time_of_day is :dusk' do
      allow(described_class).to receive(:time_of_day).and_return(:dusk)
      expect(described_class.day?).to be false
    end
  end

  # ========================================
  # Formatted Time
  # ========================================

  describe '.formatted_time' do
    let(:test_time) { Time.new(2024, 6, 15, 14, 30, 0) }

    before do
      allow(described_class).to receive(:current_time).and_return(test_time)
    end

    it 'returns short format by default' do
      expect(described_class.formatted_time).to eq('14:30')
    end

    it 'returns short format when specified' do
      expect(described_class.formatted_time(nil, format: :short)).to eq('14:30')
    end

    it 'returns long format with AM/PM' do
      expect(described_class.formatted_time(nil, format: :long)).to eq('2:30 PM')
    end

    it 'returns full format with date and time' do
      result = described_class.formatted_time(nil, format: :full)
      expect(result).to include('Saturday')
      expect(result).to include('June')
      expect(result).to include('15')
      expect(result).to include('2024')
      expect(result).to include('2:30 PM')
    end

    it 'returns date_only format' do
      result = described_class.formatted_time(nil, format: :date_only)
      expect(result).to include('Saturday')
      expect(result).to include('June')
      expect(result).to include('15')
      expect(result).to include('2024')
      expect(result).not_to include('PM')
    end

    it 'returns short format for unknown format' do
      expect(described_class.formatted_time(nil, format: :invalid)).to eq('14:30')
    end
  end

  # ========================================
  # Formatted Date
  # ========================================

  describe '.formatted_date' do
    let(:test_time) { Time.new(2024, 6, 15, 14, 30, 0) }

    before do
      allow(described_class).to receive(:current_time).and_return(test_time)
    end

    it 'returns date without time' do
      result = described_class.formatted_date
      expect(result).to include('Saturday')
      expect(result).to include('June')
      expect(result).to include('15')
      expect(result).to include('2024')
      expect(result).not_to include('PM')
    end
  end

  # ========================================
  # Weekday
  # ========================================

  describe '.weekday' do
    it 'returns lowercase weekday name' do
      allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15))
      expect(described_class.weekday).to eq('saturday')
    end

    it 'returns sunday for sunday' do
      allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 16))
      expect(described_class.weekday).to eq('sunday')
    end

    it 'returns monday for monday' do
      allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 17))
      expect(described_class.weekday).to eq('monday')
    end
  end

  # ========================================
  # Hour and Minute
  # ========================================

  describe '.hour' do
    it 'returns the hour from current time' do
      allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15, 14, 30))
      expect(described_class.hour).to eq(14)
    end

    it 'returns 0 at midnight' do
      allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15, 0, 0))
      expect(described_class.hour).to eq(0)
    end

    it 'returns 23 at 11 PM' do
      allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15, 23, 0))
      expect(described_class.hour).to eq(23)
    end
  end

  describe '.minute' do
    it 'returns the minute from current time' do
      allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15, 14, 30))
      expect(described_class.minute).to eq(30)
    end

    it 'returns 0 at start of hour' do
      allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15, 14, 0))
      expect(described_class.minute).to eq(0)
    end

    it 'returns 59 at end of hour' do
      allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 15, 14, 59))
      expect(described_class.minute).to eq(59)
    end
  end

  # ========================================
  # Sunrise and Sunset Hours
  # ========================================

  describe '.sunrise_hour' do
    it 'returns default of 6 when no location' do
      expect(described_class.sunrise_hour).to eq(6)
    end
  end

  describe '.sunset_hour' do
    it 'returns default of 18 when no location' do
      expect(described_class.sunset_hour).to eq(18)
    end
  end

  # ========================================
  # Time of Day Description
  # ========================================

  describe '.time_of_day_description' do
    it 'returns description for dawn' do
      allow(described_class).to receive(:time_of_day).and_return(:dawn)
      expect(described_class.time_of_day_description).to include('dawn')
    end

    it 'returns description for day' do
      allow(described_class).to receive(:time_of_day).and_return(:day)
      expect(described_class.time_of_day_description).to include('sun')
    end

    it 'returns description for dusk' do
      allow(described_class).to receive(:time_of_day).and_return(:dusk)
      expect(described_class.time_of_day_description).to include('dusk')
    end

    it 'returns description for night' do
      allow(described_class).to receive(:time_of_day).and_return(:night)
      expect(described_class.time_of_day_description).to include('Night')
    end
  end

  # ========================================
  # Season Detail (Latitude-Aware)
  # ========================================

  describe '.season_detail' do
    context 'without location' do
      it 'returns a hash with required keys' do
        result = described_class.season_detail
        expect(result).to include(:season, :raw_season, :system, :progress, :intensity)
      end

      it 'defaults to temperate system' do
        result = described_class.season_detail
        expect(result[:system]).to eq(:temperate)
      end

      it 'returns a mapped season in SEASONS' do
        result = described_class.season_detail
        expect(GameTimeService::SEASONS).to include(result[:season])
      end
    end
  end

  # ========================================
  # Raw Season
  # ========================================

  describe '.raw_season' do
    it 'returns the raw_season from season_detail' do
      allow(described_class).to receive(:season_detail).and_return({
                                                                     season: :summer,
                                                                     raw_season: :wet,
                                                                     system: :tropical,
                                                                     progress: 0.5,
                                                                     intensity: :mid
                                                                   })
      expect(described_class.raw_season).to eq(:wet)
    end
  end

  # ========================================
  # Season Progress
  # ========================================

  describe '.season_progress' do
    it 'returns a value between 0 and 1' do
      result = described_class.season_progress
      expect(result).to be_between(0.0, 1.0)
    end
  end

  # ========================================
  # Season Intensity
  # ========================================

  describe '.season_intensity' do
    it 'returns a valid intensity symbol' do
      result = described_class.season_intensity
      expect(%i[early mid late]).to include(result)
    end
  end

  # ========================================
  # Season System
  # ========================================

  describe '.season_system' do
    it 'returns temperate by default (no location)' do
      expect(described_class.season_system).to eq(:temperate)
    end
  end

  # ========================================
  # Southern Hemisphere
  # ========================================

  describe '.southern_hemisphere?' do
    it 'returns false by default (Northern latitude)' do
      expect(described_class.southern_hemisphere?).to be false
    end
  end

  # ========================================
  # Season Description (Climate-Aware)
  # ========================================

  describe '.season_description climate-aware' do
    context 'temperate climate' do
      before do
        allow(described_class).to receive(:season_detail).and_return({
                                                                       season: :spring,
                                                                       raw_season: :spring,
                                                                       system: :temperate,
                                                                       progress: 0.5,
                                                                       intensity: :mid
                                                                     })
      end

      it 'returns temperate spring description' do
        expect(described_class.season_description).to include('spring')
      end
    end

    context 'tropical climate' do
      before do
        allow(described_class).to receive(:season_detail).and_return({
                                                                       season: :summer,
                                                                       raw_season: :wet,
                                                                       system: :tropical,
                                                                       progress: 0.5,
                                                                       intensity: :mid
                                                                     })
      end

      it 'returns tropical wet season description' do
        expect(described_class.season_description).to include('wet season')
      end
    end

    context 'polar climate' do
      before do
        allow(described_class).to receive(:season_detail).and_return({
                                                                       season: :summer,
                                                                       raw_season: :polar_day,
                                                                       system: :polar,
                                                                       progress: 0.5,
                                                                       intensity: :mid
                                                                     })
      end

      it 'returns polar day description' do
        expect(described_class.season_description).to include('polar day')
      end
    end

    context 'with intensity' do
      before do
        allow(described_class).to receive(:season_detail).and_return({
                                                                       season: :winter,
                                                                       raw_season: :winter,
                                                                       system: :temperate,
                                                                       progress: 0.1,
                                                                       intensity: :early
                                                                     })
      end

      it 'includes intensity prefix for early season' do
        expect(described_class.season_description).to include('Early')
      end
    end
  end

  # ========================================
  # Extended Seasons Constant
  # ========================================

  describe 'EXTENDED_SEASONS constant' do
    it 'includes standard temperate seasons' do
      expect(GameTimeService::EXTENDED_SEASONS).to include(:spring, :summer, :fall, :winter)
    end

    it 'includes tropical seasons' do
      expect(GameTimeService::EXTENDED_SEASONS).to include(:wet, :dry)
    end

    it 'includes polar seasons' do
      expect(GameTimeService::EXTENDED_SEASONS).to include(:polar_day, :polar_night)
    end
  end

  # ========================================
  # Coordinate-Based Sun Times
  # ========================================

  describe '.sun_times' do
    context 'without location' do
      it 'returns default sun times' do
        result = described_class.sun_times
        expect(result[:status]).to eq(:default)
        expect(result[:sunrise]).to eq(6.0)
        expect(result[:sunset]).to eq(18.0)
      end
    end
  end

  describe '.sunrise_hour with precise option' do
    context 'without location' do
      it 'returns integer by default (backward compatible)' do
        result = described_class.sunrise_hour
        expect(result).to be_a(Integer)
        expect(result).to eq(6)
      end

      it 'returns float when precise: true' do
        result = described_class.sunrise_hour(nil, precise: true)
        expect(result).to be_a(Float)
        expect(result).to eq(6.0)
      end
    end
  end

  describe '.sunset_hour with precise option' do
    context 'without location' do
      it 'returns integer by default (backward compatible)' do
        result = described_class.sunset_hour
        expect(result).to be_a(Integer)
        expect(result).to eq(18)
      end

      it 'returns float when precise: true' do
        result = described_class.sunset_hour(nil, precise: true)
        expect(result).to be_a(Float)
        expect(result).to eq(18.0)
      end
    end
  end

  describe 'coordinate-based calculations' do
    let(:universe) { Universe.create(name: 'Test Universe', theme: 'fantasy') }
    let(:world) { World.create(name: 'Test World', universe: universe, gravity_multiplier: 1.0, world_size: 1.0) }
    let(:zone) { Zone.create(name: 'Test Zone', world: world, zone_type: 'wilderness', danger_level: 1) }

    context 'with location having coordinates at equator' do
      let(:location) do
        Location.create(
          name: 'Fantasy Location',
          zone: zone,
          world: world,
          location_type: 'outdoor',
          latitude: 0.0,
          longitude: 0.0  # Equator at prime meridian
        )
      end

      it 'calculates sun times from coordinates' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 21, 12, 0))

        result = described_class.sun_times(location)
        expect(result[:status]).to eq(:calculated)
        # At equator, sunrise should be around 6 AM
        expect(result[:sunrise]).to be_within(1.0).of(6.0)
      end
    end

    context 'with location having explicit lat/lon' do
      let(:location) do
        Location.create(
          name: 'Real Location',
          zone: zone,
          world: world,
          location_type: 'outdoor',
          latitude: 45.0,
          longitude: -93.0  # Minneapolis
        )
      end

      it 'uses explicit coordinates over hex coordinates' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 21, 12, 0))

        result = described_class.sun_times(location)
        expect(result[:status]).to eq(:calculated)
        # At 45°N in summer, sunrise should be early
        expect(result[:sunrise]).to be < 12.0
      end
    end

    context 'with location having weather API data' do
      let(:location) do
        Location.create(
          name: 'API Location',
          zone: zone,
          world: world,
          location_type: 'outdoor'
        )
      end

      before do
        Weather.create(
          location: location,
          condition: 'clear',
          weather_source: 'api',
          sunrise_at: Time.new(2024, 6, 21, 5, 30, 0),
          sunset_at: Time.new(2024, 6, 21, 21, 0, 0),
          timezone_offset: -21600 # -6 hours
        )
      end

      it 'uses API sunrise/sunset times when available' do
        result = described_class.sun_times(location)
        expect(result[:status]).to eq(:api)
        expect(result[:sunrise]).to eq(5.5) # 5:30 AM
        expect(result[:sunset]).to eq(21.0) # 9:00 PM
      end
    end
  end

  describe 'time_of_day with coordinates' do
    context 'polar conditions' do
      before do
        # Mock calculate_sun_times to return polar conditions
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 21, 12, 0))
      end

      it 'returns :day for midnight sun' do
        allow(described_class).to receive(:calculate_sun_times).and_return({
                                                                             sunrise: 0.0,
                                                                             sunset: 24.0,
                                                                             status: :midnight_sun
                                                                           })
        expect(described_class.time_of_day).to eq(:day)
      end

      it 'returns :night for polar night' do
        allow(described_class).to receive(:calculate_sun_times).and_return({
                                                                             sunrise: 12.0,
                                                                             sunset: 12.0,
                                                                             status: :polar_night
                                                                           })
        expect(described_class.time_of_day).to eq(:night)
      end
    end

    context 'with precise dawn/dusk windows' do
      before do
        allow(described_class).to receive(:calculate_sun_times).and_return({
                                                                             sunrise: 6.0,
                                                                             sunset: 20.0,
                                                                             status: :calculated
                                                                           })
      end

      it 'returns :dawn during sunrise window' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 21, 6, 30))
        expect(described_class.time_of_day).to eq(:dawn)
      end

      it 'returns :dawn for 1 hour after sunrise' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 21, 7, 0))
        expect(described_class.time_of_day).to eq(:dawn)
      end

      it 'returns :day after dawn window ends' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 21, 8, 0))
        expect(described_class.time_of_day).to eq(:day)
      end

      it 'returns :dusk starting 30 min before sunset' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 21, 19, 45))
        expect(described_class.time_of_day).to eq(:dusk)
      end

      it 'returns :dusk at sunset' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 21, 20, 0))
        expect(described_class.time_of_day).to eq(:dusk)
      end

      it 'returns :night after dusk window ends' do
        allow(described_class).to receive(:current_time).and_return(Time.new(2024, 6, 21, 21, 30))
        expect(described_class.time_of_day).to eq(:night)
      end
    end
  end
end
