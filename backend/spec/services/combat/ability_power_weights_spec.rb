# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AbilityPowerWeights do
  # Store original state to restore after tests
  before(:all) do
    @original_weights = described_class.instance_variable_get(:@weights)&.dup
    @original_loaded = described_class.instance_variable_get(:@loaded)
  end

  after(:all) do
    described_class.instance_variable_set(:@weights, @original_weights)
    described_class.instance_variable_set(:@loaded, @original_loaded)
  end

  before(:each) do
    # Reset state before each test
    described_class.instance_variable_set(:@weights, nil)
    described_class.instance_variable_set(:@coefficients, nil)
    described_class.instance_variable_set(:@baseline, nil)
    described_class.instance_variable_set(:@metadata, nil)
    described_class.instance_variable_set(:@locked_coefficients, nil)
    described_class.instance_variable_set(:@last_run, nil)
    described_class.instance_variable_set(:@loaded, false)
  end

  describe 'constants' do
    it 'defines YAML_PATH' do
      expect(described_class::YAML_PATH).to include('ability_power_weights.yml')
    end

  end

  describe '.load!' do
    context 'when YAML file exists' do
      before do
        allow(File).to receive(:exist?).with(described_class::YAML_PATH).and_return(true)
        allow(YAML).to receive(:load_file).and_return({
          'version' => 1,
          'mode' => 'tuned',
          'baseline' => { 'damage' => 11, 'hp' => 6 },
          'coefficients' => { 'cc_skip_mult' => 1.0, 'dot_damage_mult' => 0.5 },
          'weights' => {
            'global' => { 'power_per_damage' => 6.67 },
            'status' => { 'stunned' => 75, 'blinded' => 50 }
          },
          'locked_coefficients' => ['cc_skip_mult'],
          'last_run' => { 'timestamp' => '2026-01-01', 'mode' => 'refine', 'iterations' => 100 }
        })
      end

      it 'loads metadata' do
        described_class.load!

        expect(described_class.instance_variable_get(:@metadata)['version']).to eq(1)
        expect(described_class.instance_variable_get(:@metadata)['mode']).to eq('tuned')
      end

      it 'loads baseline values' do
        described_class.load!

        expect(described_class.baseline('damage')).to eq(11)
        expect(described_class.baseline('hp')).to eq(6)
      end

      it 'loads coefficients' do
        described_class.load!

        expect(described_class.coefficient('cc_skip_mult')).to eq(1.0)
        expect(described_class.coefficient('dot_damage_mult')).to eq(0.5)
      end

      it 'loads weights by category' do
        described_class.load!

        expect(described_class.get('global', 'power_per_damage')).to eq(6.67)
        expect(described_class.get('status', 'stunned')).to eq(75)
      end

      it 'loads locked coefficients' do
        described_class.load!

        expect(described_class.locked_coefficients).to include('cc_skip_mult')
      end

      it 'loads last run data' do
        described_class.load!

        expect(described_class.last_run['timestamp']).to eq('2026-01-01')
      end

      it 'sets loaded flag' do
        described_class.load!

        expect(described_class.loaded?).to be true
      end
    end

  end

  describe '.loaded?' do
    it 'returns false when not loaded' do
      described_class.instance_variable_set(:@loaded, false)

      expect(described_class.loaded?).to be false
    end

    it 'returns true when loaded' do
      described_class.instance_variable_set(:@loaded, true)

      expect(described_class.loaded?).to be true
    end
  end

  describe '.reload!' do
    before do
      allow(File).to receive(:exist?).with(described_class::YAML_PATH).and_return(true)
      allow(YAML).to receive(:load_file).and_return({
        'weights' => { 'global' => { 'test' => 1 } },
        'coefficients' => {},
        'baseline' => {}
      })
    end

    it 'resets and reloads weights' do
      described_class.instance_variable_set(:@weights, { 'old' => 'data' })
      described_class.instance_variable_set(:@loaded, true)

      described_class.reload!

      expect(described_class.instance_variable_get(:@weights)).to include('global')
      expect(described_class.instance_variable_get(:@weights)).not_to include('old')
    end
  end

  describe '.get' do
    before do
      described_class.instance_variable_set(:@weights, {
        'global' => { 'power_per_damage' => 6.67 },
        'status' => { 'stunned' => 75 }
      })
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'returns weight value' do
      expect(described_class.get('global', 'power_per_damage')).to eq(6.67)
    end

    it 'returns nil for missing key' do
      expect(described_class.get('global', 'nonexistent')).to be_nil
    end

    it 'returns default for missing key' do
      expect(described_class.get('global', 'nonexistent', default: 100)).to eq(100)
    end

    it 'handles symbol keys' do
      expect(described_class.get(:global, :power_per_damage)).to eq(6.67)
    end
  end

  describe '.set' do
    before do
      described_class.instance_variable_set(:@weights, { 'global' => {} })
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'sets weight value' do
      described_class.set('global', 'new_weight', 42)

      expect(described_class.get('global', 'new_weight')).to eq(42)
    end

    it 'creates category if not exists' do
      described_class.set('new_category', 'key', 99)

      expect(described_class.get('new_category', 'key')).to eq(99)
    end
  end

  describe '.coefficient' do
    before do
      described_class.instance_variable_set(:@coefficients, { 'cc_skip_mult' => 1.5 })
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'returns coefficient value' do
      expect(described_class.coefficient('cc_skip_mult')).to eq(1.5)
    end

    it 'returns default for missing key' do
      expect(described_class.coefficient('nonexistent', default: 1.0)).to eq(1.0)
    end
  end

  describe '.set_coefficient' do
    before do
      described_class.instance_variable_set(:@coefficients, {})
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'sets coefficient value' do
      described_class.set_coefficient('new_coef', 2.5)

      expect(described_class.coefficient('new_coef')).to eq(2.5)
    end
  end

  describe '.baseline' do
    before do
      described_class.instance_variable_set(:@baseline, { 'damage' => 11, 'hp' => 6 })
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'returns baseline value' do
      expect(described_class.baseline('damage')).to eq(11)
      expect(described_class.baseline('hp')).to eq(6)
    end
  end

  describe '.status' do
    before do
      described_class.instance_variable_set(:@weights, {
        'status' => { 'stunned' => 75, 'blinded' => 50, 'fractional' => 12.75 }
      })
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'returns status effect power' do
      expect(described_class.status('stunned')).to eq(75)
      expect(described_class.status('blinded')).to eq(50)
    end

    it 'returns default for missing status' do
      expect(described_class.status('nonexistent')).to eq(15)
    end

    it 'allows custom default' do
      expect(described_class.status('nonexistent', default: 25)).to eq(25)
    end

    it 'preserves fractional status weights' do
      expect(described_class.status('fractional')).to eq(12.75)
    end
  end

  describe '.global' do
    before do
      described_class.instance_variable_set(:@weights, {
        'global' => { 'power_per_damage' => 6.67 }
      })
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'returns global weight' do
      expect(described_class.global('power_per_damage')).to eq(6.67)
    end
  end

  describe '.aoe_circle_targets' do
    before do
      described_class.instance_variable_set(:@weights, {
        'aoe_circle' => {
          'radius_1' => 1.5,
          'radius_2' => 3.0,
          'radius_3' => 5.0,
          'radius_max' => 8
        }
      })
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'returns specific radius targets' do
      expect(described_class.aoe_circle_targets(1)).to eq(1.5)
      expect(described_class.aoe_circle_targets(2)).to eq(3.0)
    end

    it 'calculates fallback for missing radius' do
      # For radius 5 not defined, fallback = min(radius*2, max) = min(10, 8) = 8.0
      expect(described_class.aoe_circle_targets(5)).to eq(8.0)
    end
  end

  describe '.all' do
    before do
      described_class.instance_variable_set(:@weights, { 'global' => { 'test' => 1 } })
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'returns duplicate of all weights' do
      result = described_class.all

      expect(result).to eq({ 'global' => { 'test' => 1 } })
      expect(result).not_to be(described_class.instance_variable_get(:@weights))
    end
  end

  describe '.all_coefficients' do
    before do
      described_class.instance_variable_set(:@coefficients, { 'coef1' => 1.0 })
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'returns duplicate of all coefficients' do
      result = described_class.all_coefficients

      expect(result).to eq({ 'coef1' => 1.0 })
      expect(result).not_to be(described_class.instance_variable_get(:@coefficients))
    end
  end

  describe '.locked?' do
    before do
      described_class.instance_variable_set(:@locked_coefficients, ['cc_skip_mult'])
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'returns true for locked coefficient' do
      expect(described_class.locked?('cc_skip_mult')).to be true
    end

    it 'returns false for unlocked coefficient' do
      expect(described_class.locked?('other_coef')).to be false
    end
  end

  describe '.set_locked' do
    before do
      described_class.instance_variable_set(:@locked_coefficients, [])
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'locks a coefficient' do
      described_class.set_locked('new_coef', true)

      expect(described_class.locked?('new_coef')).to be true
    end

    it 'unlocks a coefficient' do
      described_class.set_locked('coef', true)
      described_class.set_locked('coef', false)

      expect(described_class.locked?('coef')).to be false
    end

    it 'does not duplicate locked entries' do
      described_class.set_locked('coef', true)
      described_class.set_locked('coef', true)

      expect(described_class.locked_coefficients.count('coef')).to eq(1)
    end
  end

  describe '.locked_coefficients' do
    before do
      described_class.instance_variable_set(:@locked_coefficients, ['coef1', 'coef2'])
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'returns list of locked coefficients' do
      expect(described_class.locked_coefficients).to eq(['coef1', 'coef2'])
    end
  end

  describe '.set_last_run and .last_run' do
    before do
      described_class.instance_variable_set(:@last_run, nil)
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'stores last run data' do
      described_class.set_last_run(
        timestamp: '2026-01-15 10:00:00',
        mode: :fresh,
        iterations: 500,
        results: { 'coef1' => { 'win_rate' => 50.0 } }
      )

      run = described_class.last_run
      expect(run['timestamp']).to eq('2026-01-15 10:00:00')
      expect(run['mode']).to eq('fresh')
      expect(run['iterations']).to eq(500)
      expect(run['results']).to include('coef1')
    end
  end

  describe '.status_effects' do
    before do
      described_class.instance_variable_set(:@weights, {
        'status' => { 'stunned' => 75, 'blinded' => 50 }
      })
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'returns all status effects' do
      result = described_class.status_effects

      expect(result).to eq({ 'stunned' => 75, 'blinded' => 50 })
    end

    it 'returns empty hash when no status weights' do
      described_class.instance_variable_set(:@weights, {})

      expect(described_class.status_effects).to eq({})
    end
  end

  describe '.entries_for_category' do
    before do
      described_class.instance_variable_set(:@weights, {
        'global' => { 'key1' => 1, 'key2' => 2 }
      })
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'returns entries for category' do
      result = described_class.entries_for_category('global')

      expect(result).to eq({ 'key1' => 1, 'key2' => 2 })
    end

    it 'returns empty hash for missing category' do
      result = described_class.entries_for_category('nonexistent')

      expect(result).to eq({})
    end
  end

  describe '.save!' do
    before do
      described_class.instance_variable_set(:@weights, { 'global' => { 'test' => 1 } })
      described_class.instance_variable_set(:@coefficients, { 'coef1' => 1.5 })
      described_class.instance_variable_set(:@baseline, { 'damage' => 11 })
      described_class.instance_variable_set(:@metadata, { 'version' => 1, 'mode' => 'tuned' })
      described_class.instance_variable_set(:@locked_coefficients, ['coef1'])
      described_class.instance_variable_set(:@last_run, { 'timestamp' => '2026-01-01' })
      described_class.instance_variable_set(:@loaded, true)
    end

    it 'writes YAML file' do
      expect(File).to receive(:write).with(described_class::YAML_PATH, anything)

      described_class.save!
    end

    it 'includes version and mode' do
      content = nil
      allow(File).to receive(:write) { |_, c| content = c }

      described_class.save!

      expect(content).to include('version: 1')
      expect(content).to include('mode: tuned')
    end
  end

  describe '.yaml_path' do
    it 'returns YAML_PATH constant' do
      expect(described_class.yaml_path).to eq(described_class::YAML_PATH)
    end
  end

  describe 'private methods' do
    describe '#stringify_keys' do
      it 'converts symbol keys to strings' do
        result = described_class.send(:stringify_keys, { foo: 1, bar: 2 })
        expect(result).to eq({ 'foo' => 1, 'bar' => 2 })
      end

      it 'handles non-hash input' do
        result = described_class.send(:stringify_keys, 'not a hash')
        expect(result).to eq({})
      end
    end

    describe '#format_yaml_value' do
      it 'formats floats with up to 2 decimal places' do
        result = described_class.send(:format_yaml_value, 3.14159)
        expect(result).to eq('3.14')
      end

      it 'removes trailing zeros' do
        result = described_class.send(:format_yaml_value, 3.10)
        expect(result).to eq('3.1')
      end

      it 'handles integers' do
        result = described_class.send(:format_yaml_value, 42)
        expect(result).to eq('42')
      end
    end
  end
end
