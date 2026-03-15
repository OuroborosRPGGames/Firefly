# frozen_string_literal: true

require 'spec_helper'

RSpec.describe GameClockConfig do
  let(:universe) { create(:universe) }

  describe 'associations' do
    it 'belongs to universe' do
      config = GameClockConfig.new(universe_id: universe.id)
      expect(config.universe).to eq(universe)
    end
  end

  describe 'validations' do
    it 'requires universe_id' do
      config = GameClockConfig.new(clock_mode: 'realtime')
      expect(config.valid?).to be false
      expect(config.errors[:universe_id]).not_to be_empty
    end

    it 'requires clock_mode' do
      config = GameClockConfig.new(universe_id: universe.id)
      expect(config.valid?).to be false
      expect(config.errors[:clock_mode]).not_to be_empty
    end

    it 'validates clock_mode is in CLOCK_MODES' do
      config = GameClockConfig.new(universe_id: universe.id, clock_mode: 'invalid')
      expect(config.valid?).to be false
      expect(config.errors[:clock_mode]).not_to be_empty
    end

    it 'accepts realtime as clock_mode' do
      config = GameClockConfig.new(universe_id: universe.id, clock_mode: 'realtime')
      expect(config.valid?).to be true
    end

    it 'accepts accelerated as clock_mode' do
      config = GameClockConfig.new(
        universe_id: universe.id,
        clock_mode: 'accelerated',
        time_ratio: 4.0,
        game_epoch: Time.now,
        real_epoch: Time.now
      )
      expect(config.valid?).to be true
    end

    it 'validates uniqueness of universe_id' do
      GameClockConfig.create(universe_id: universe.id, clock_mode: 'realtime')
      duplicate = GameClockConfig.new(universe_id: universe.id, clock_mode: 'realtime')
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:universe_id]).not_to be_empty
    end

    context 'when clock_mode is accelerated' do
      it 'requires time_ratio' do
        config = GameClockConfig.new(
          universe_id: universe.id,
          clock_mode: 'accelerated',
          game_epoch: Time.now,
          real_epoch: Time.now
        )
        expect(config.valid?).to be false
        expect(config.errors[:time_ratio]).not_to be_empty
      end

      it 'requires game_epoch' do
        config = GameClockConfig.new(
          universe_id: universe.id,
          clock_mode: 'accelerated',
          time_ratio: 4.0,
          real_epoch: Time.now
        )
        expect(config.valid?).to be false
        expect(config.errors[:game_epoch]).not_to be_empty
      end

      it 'requires real_epoch' do
        config = GameClockConfig.new(
          universe_id: universe.id,
          clock_mode: 'accelerated',
          time_ratio: 4.0,
          game_epoch: Time.now
        )
        expect(config.valid?).to be false
        expect(config.errors[:real_epoch]).not_to be_empty
      end
    end
  end

  describe '#realtime?' do
    it 'returns true when clock_mode is realtime' do
      config = GameClockConfig.new(clock_mode: 'realtime')
      expect(config.realtime?).to be true
    end

    it 'returns false when clock_mode is accelerated' do
      config = GameClockConfig.new(clock_mode: 'accelerated')
      expect(config.realtime?).to be false
    end
  end

  describe '#accelerated?' do
    it 'returns true when clock_mode is accelerated' do
      config = GameClockConfig.new(clock_mode: 'accelerated')
      expect(config.accelerated?).to be true
    end

    it 'returns false when clock_mode is realtime' do
      config = GameClockConfig.new(clock_mode: 'realtime')
      expect(config.accelerated?).to be false
    end
  end

  describe '#start_accelerated_time!' do
    it 'switches to accelerated mode' do
      config = GameClockConfig.create(universe_id: universe.id, clock_mode: 'realtime')
      config.start_accelerated_time!
      config.refresh

      expect(config.clock_mode).to eq('accelerated')
    end

    it 'sets default time_ratio to 4.0' do
      config = GameClockConfig.create(universe_id: universe.id, clock_mode: 'realtime')
      config.start_accelerated_time!
      config.refresh

      expect(config.time_ratio).to eq(4.0)
    end

    it 'allows custom time_ratio' do
      config = GameClockConfig.create(universe_id: universe.id, clock_mode: 'realtime')
      config.start_accelerated_time!(ratio: 2.0)
      config.refresh

      expect(config.time_ratio).to eq(2.0)
    end

    it 'sets game_epoch and real_epoch' do
      freeze_time = Time.now
      allow(Time).to receive(:now).and_return(freeze_time)

      config = GameClockConfig.create(universe_id: universe.id, clock_mode: 'realtime')
      config.start_accelerated_time!
      config.refresh

      expect(config.real_epoch).to be_within(1).of(freeze_time)
      expect(config.game_epoch).to be_within(1).of(freeze_time)
    end

    it 'allows custom starting_game_time' do
      custom_time = Time.now - 86400 # 1 day ago
      config = GameClockConfig.create(universe_id: universe.id, clock_mode: 'realtime')
      config.start_accelerated_time!(starting_game_time: custom_time)
      config.refresh

      expect(config.game_epoch).to be_within(1).of(custom_time)
    end

    it 'returns self' do
      config = GameClockConfig.create(universe_id: universe.id, clock_mode: 'realtime')
      result = config.start_accelerated_time!
      expect(result).to eq(config)
    end
  end

  describe '#switch_to_realtime!' do
    it 'switches to realtime mode' do
      config = GameClockConfig.create(
        universe_id: universe.id,
        clock_mode: 'accelerated',
        time_ratio: 4.0,
        game_epoch: Time.now,
        real_epoch: Time.now
      )
      config.switch_to_realtime!
      config.refresh

      expect(config.clock_mode).to eq('realtime')
    end

    it 'returns self' do
      config = GameClockConfig.create(
        universe_id: universe.id,
        clock_mode: 'accelerated',
        time_ratio: 4.0,
        game_epoch: Time.now,
        real_epoch: Time.now
      )
      result = config.switch_to_realtime!
      expect(result).to eq(config)
    end
  end

  describe '#current_game_time' do
    context 'in realtime mode' do
      it 'returns current time' do
        freeze_time = Time.now
        allow(Time).to receive(:now).and_return(freeze_time)

        config = GameClockConfig.new(clock_mode: 'realtime')
        expect(config.current_game_time).to eq(freeze_time)
      end
    end

    context 'in accelerated mode' do
      it 'returns current time when epochs are nil' do
        freeze_time = Time.now
        allow(Time).to receive(:now).and_return(freeze_time)

        config = GameClockConfig.new(clock_mode: 'accelerated', time_ratio: 4.0)
        expect(config.current_game_time).to eq(freeze_time)
      end

      it 'calculates accelerated game time correctly' do
        real_start = Time.now - 3600 # 1 hour ago
        game_start = Time.now - 7200 # 2 hours ago in game time
        ratio = 4.0

        config = GameClockConfig.new(
          clock_mode: 'accelerated',
          time_ratio: ratio,
          game_epoch: game_start,
          real_epoch: real_start
        )

        # After 1 real hour at 4x, game time should be 4 hours ahead
        expected_game_time = game_start + (3600 * ratio)
        expect(config.current_game_time).to be_within(5).of(expected_game_time)
      end

      it 'handles fractional ratios' do
        real_start = Time.now - 7200 # 2 hours ago
        game_start = Time.now - 7200
        ratio = 1.5

        config = GameClockConfig.new(
          clock_mode: 'accelerated',
          time_ratio: ratio,
          game_epoch: game_start,
          real_epoch: real_start
        )

        # After 2 real hours at 1.5x, game time should be 3 hours ahead
        expected_game_time = game_start + (7200 * ratio)
        expect(config.current_game_time).to be_within(5).of(expected_game_time)
      end
    end
  end

  describe '#dawn_hour' do
    it 'returns fixed_dawn_hour when set' do
      config = GameClockConfig.new(fixed_dawn_hour: 5)
      expect(config.dawn_hour).to eq(5)
    end

    it 'returns default 6 when fixed_dawn_hour is nil' do
      config = GameClockConfig.new
      expect(config.dawn_hour).to eq(6)
    end
  end

  describe '#dusk_hour' do
    it 'returns fixed_dusk_hour when set' do
      config = GameClockConfig.new(fixed_dusk_hour: 20)
      expect(config.dusk_hour).to eq(20)
    end

    it 'returns default 18 when fixed_dusk_hour is nil' do
      config = GameClockConfig.new
      expect(config.dusk_hour).to eq(18)
    end
  end

  describe '.for_universe' do
    it 'returns existing config for universe' do
      existing = GameClockConfig.create(universe_id: universe.id, clock_mode: 'realtime')
      result = GameClockConfig.for_universe(universe)
      expect(result).to eq(existing)
    end

    it 'creates default config when none exists' do
      allow(GameSetting).to receive(:get).with('default_clock_mode').and_return(nil)
      allow(GameSetting).to receive(:float_setting).with('default_time_ratio').and_return(nil)
      allow(GameSetting).to receive(:get).with('default_timezone').and_return(nil)

      result = GameClockConfig.for_universe(universe)

      expect(result).to be_a(GameClockConfig)
      expect(result.universe_id).to eq(universe.id)
      expect(result.clock_mode).to eq('realtime')
    end
  end

  describe '.create_default_for' do
    it 'creates config with default settings' do
      allow(GameSetting).to receive(:get).with('default_clock_mode').and_return(nil)
      allow(GameSetting).to receive(:float_setting).with('default_time_ratio').and_return(nil)
      allow(GameSetting).to receive(:get).with('default_timezone').and_return(nil)

      result = GameClockConfig.create_default_for(universe)

      expect(result.universe_id).to eq(universe.id)
      expect(result.clock_mode).to eq('realtime')
      expect(result.time_ratio).to eq(1.0)
      expect(result.reference_timezone).to eq('UTC')
      expect(result.is_active).to be true
    end

    it 'uses GameSetting values when available' do
      # Note: accelerated mode requires game_epoch and real_epoch which create_default_for
      # doesn't set, so we test with realtime mode and custom timezone/ratio
      allow(GameSetting).to receive(:get).with('default_clock_mode').and_return('realtime')
      allow(GameSetting).to receive(:float_setting).with('default_time_ratio').and_return(2.0)
      allow(GameSetting).to receive(:get).with('default_timezone').and_return('America/New_York')

      result = GameClockConfig.create_default_for(universe)

      expect(result.clock_mode).to eq('realtime')
      expect(result.time_ratio).to eq(2.0)
      expect(result.reference_timezone).to eq('America/New_York')
    end

    it 'creates valid accelerated configs with required epochs' do
      allow(GameSetting).to receive(:get).with('default_clock_mode').and_return('accelerated')
      allow(GameSetting).to receive(:float_setting).with('default_time_ratio').and_return(3.0)
      allow(GameSetting).to receive(:get).with('default_timezone').and_return('UTC')

      result = GameClockConfig.create_default_for(universe)

      expect(result.clock_mode).to eq('accelerated')
      expect(result.time_ratio).to eq(3.0)
      expect(result.game_epoch).not_to be_nil
      expect(result.real_epoch).not_to be_nil
    end

    it 'falls back to safe defaults for invalid mode and ratio' do
      allow(GameSetting).to receive(:get).with('default_clock_mode').and_return('invalid')
      allow(GameSetting).to receive(:float_setting).with('default_time_ratio').and_return(nil)
      allow(GameSetting).to receive(:get).with('default_timezone').and_return(nil)

      result = GameClockConfig.create_default_for(universe)

      expect(result.clock_mode).to eq('realtime')
      expect(result.time_ratio).to eq(1.0)
    end
  end
end
