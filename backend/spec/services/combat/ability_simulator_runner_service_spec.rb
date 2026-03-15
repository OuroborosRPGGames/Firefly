# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AbilitySimulatorRunnerService do
  describe 'constants' do
    it 'defines SCRIPT_PATH' do
      expect(described_class::SCRIPT_PATH).to include('ability_balance_simulator.rb')
    end

    it 'defines GRID_SEARCH_POINTS' do
      expect(described_class::GRID_SEARCH_POINTS).to be_an(Array)
      expect(described_class::GRID_SEARCH_POINTS).to include(0.1, 1.0, 2.0)
    end

    it 'defines FINAL_THRESHOLD' do
      expect(described_class::FINAL_THRESHOLD).to eq(5.0)
    end
  end

  describe '#initialize' do
    it 'defaults to refine mode' do
      service = described_class.new

      expect(service.mode).to eq(:refine)
    end

    it 'defaults to 200 iterations' do
      service = described_class.new

      expect(service.iterations).to eq(200)
    end

    it 'accepts custom mode' do
      service = described_class.new(mode: :fresh)

      expect(service.mode).to eq(:fresh)
    end

    it 'accepts custom iterations' do
      service = described_class.new(iterations: 500)

      expect(service.iterations).to eq(500)
    end

    it 'clamps iterations to minimum 10' do
      service = described_class.new(iterations: 5)

      expect(service.iterations).to eq(10)
    end

    it 'clamps iterations to maximum 1000' do
      service = described_class.new(iterations: 2000)

      expect(service.iterations).to eq(1000)
    end

    it 'initializes empty results' do
      service = described_class.new

      expect(service.results).to eq({})
    end
  end

  describe '#run!' do
    let(:service) { described_class.new(mode: :refine, iterations: 100) }
    let(:simulator) { double('BalanceSimulator') }

    before do
      # Mock the script classes that would be loaded
      stub_const('BalanceCoefficients', Class.new do
        def self.load!(mode:); end
        def self.get(key); 1.0; end
        def self.set(key, value); end
        def self.save!; end
      end)

      stub_const('AbilityGenerator', Class.new do
        def self.generate_all
          [
            { ability: 'test_ability', coef_key: :test_coef }
          ]
        end
      end)

      stub_const('BalanceSimulator', Class.new do
        def initialize(config); end
        def run(iterations:); end
        def win_rate; 50.0; end
      end)

      allow(AbilityPowerWeights).to receive(:locked?).and_return(false)
      allow(AbilityPowerWeights).to receive(:set_last_run)
      allow(AbilityPowerWeights).to receive(:save!)

      # Skip script loading
      allow(service).to receive(:load_script_classes!)
    end

    it 'loads balance coefficients in specified mode' do
      expect(BalanceCoefficients).to receive(:load!).with(mode: :refine)

      service.run!
    end

    it 'generates all abilities' do
      expect(AbilityGenerator).to receive(:generate_all).and_return([])

      service.run!
    end

    it 'saves coefficients after tuning' do
      expect(BalanceCoefficients).to receive(:save!)

      service.run!
    end

    it 'saves results to AbilityPowerWeights' do
      expect(AbilityPowerWeights).to receive(:set_last_run).with(
        hash_including(
          mode: :refine,
          iterations: 100
        )
      )
      expect(AbilityPowerWeights).to receive(:save!)

      service.run!
    end

    it 'returns results hash' do
      result = service.run!

      expect(result).to be_a(Hash)
    end

    context 'with locked coefficient' do
      before do
        allow(AbilityPowerWeights).to receive(:locked?).with('test_coef').and_return(true)
      end

      it 'skips locked coefficients' do
        result = service.run!

        expect(result['test_coef']['locked']).to be true
        expect(result['test_coef']['win_rate']).to be_nil
      end

      it 'preserves original value' do
        result = service.run!

        expect(result['test_coef']['original']).to eq(1.0)
        expect(result['test_coef']['final']).to eq(1.0)
      end
    end

    context 'with abilities without coef_key' do
      before do
        allow(AbilityGenerator).to receive(:generate_all).and_return([
          { ability: 'no_coef_ability', coef_key: nil }
        ])
      end

      it 'skips abilities without coef_key' do
        result = service.run!

        expect(result).to be_empty
      end
    end
  end

  describe '#clamp_coefficient' do
    let(:service) { described_class.new }

    it 'clamps heal_mult between 0.1 and 10.0' do
      expect(service.send(:clamp_coefficient, :heal_mult, 0.01)).to eq(0.1)
      expect(service.send(:clamp_coefficient, :heal_mult, 20.0)).to eq(10.0)
    end

    it 'clamps cc_ prefixed coefficients' do
      expect(service.send(:clamp_coefficient, :cc_skip, 0.01)).to eq(0.1)
      expect(service.send(:clamp_coefficient, :cc_skip, 30.0)).to eq(20.0)
    end

    it 'clamps dot_ prefixed coefficients' do
      expect(service.send(:clamp_coefficient, :dot_damage, 0.001)).to eq(0.01)
      expect(service.send(:clamp_coefficient, :dot_damage, 20.0)).to eq(15.0)
    end

    it 'clamps vuln_ prefixed coefficients' do
      expect(service.send(:clamp_coefficient, :vuln_mult, 0.01)).to eq(0.1)
      expect(service.send(:clamp_coefficient, :vuln_mult, 20.0)).to eq(15.0)
    end

    it 'clamps debuff_ prefixed coefficients' do
      expect(service.send(:clamp_coefficient, :debuff_mult, 0.01)).to eq(0.1)
      expect(service.send(:clamp_coefficient, :debuff_mult, 20.0)).to eq(15.0)
    end

    it 'clamps buff_ prefixed coefficients' do
      expect(service.send(:clamp_coefficient, :buff_mult, 0.01)).to eq(0.1)
      expect(service.send(:clamp_coefficient, :buff_mult, 20.0)).to eq(15.0)
    end

    it 'clamps armor_ prefixed coefficients' do
      expect(service.send(:clamp_coefficient, :armor_mult, 0.01)).to eq(0.1)
      expect(service.send(:clamp_coefficient, :armor_mult, 30.0)).to eq(20.0)
    end

    it 'clamps protect_ prefixed coefficients' do
      expect(service.send(:clamp_coefficient, :protect_mult, 0.01)).to eq(0.1)
      expect(service.send(:clamp_coefficient, :protect_mult, 30.0)).to eq(20.0)
    end

    it 'clamps shield_ prefixed coefficients' do
      expect(service.send(:clamp_coefficient, :shield_mult, 0.01)).to eq(0.1)
      expect(service.send(:clamp_coefficient, :shield_mult, 30.0)).to eq(20.0)
    end

    it 'clamps aoe_circle_r prefixed coefficients' do
      expect(service.send(:clamp_coefficient, :aoe_circle_r1, 0.1)).to eq(0.5)
      expect(service.send(:clamp_coefficient, :aoe_circle_r5, 20.0)).to eq(15.0)
    end

    it 'uses default range for unknown coefficients' do
      expect(service.send(:clamp_coefficient, :unknown, 0.01)).to eq(0.1)
      expect(service.send(:clamp_coefficient, :unknown, 30.0)).to eq(20.0)
    end
  end

  describe 'tuning algorithm' do
    let(:service) { described_class.new(iterations: 100) }
    let(:simulator_instance) { double('BalanceSimulator') }

    before do
      # Use module for state storage to avoid class variable issues
      balance_coefficients_values = {}

      balance_coefficients = Module.new do
        define_singleton_method(:values) { balance_coefficients_values }
        define_singleton_method(:load!) { |mode:| }
        define_singleton_method(:get) { |key| balance_coefficients_values[key.to_s] || 1.0 }
        define_singleton_method(:set) { |key, value| balance_coefficients_values[key.to_s] = value }
        define_singleton_method(:save!) { }
      end
      stub_const('BalanceCoefficients', balance_coefficients)

      ability_generator = Module.new do
        define_singleton_method(:generate_all) do
          [{ ability: 'fireball', coef_key: :damage_mult }]
        end
      end
      stub_const('AbilityGenerator', ability_generator)

      # Use a simple class with instance method stubbing
      balance_simulator_class = Class.new do
        def initialize(config); end
        def run(iterations:); end
        def win_rate; 50.0; end
      end
      stub_const('BalanceSimulator', balance_simulator_class)

      allow(AbilityPowerWeights).to receive(:locked?).and_return(false)
      allow(AbilityPowerWeights).to receive(:set_last_run)
      allow(AbilityPowerWeights).to receive(:save!)
      allow(service).to receive(:load_script_classes!)
    end

    it 'performs grid search to find approximate balance' do
      # Each grid point runs simulation - multiple instances are created
      # so we use allow_any_instance_of and verify results
      allow_any_instance_of(BalanceSimulator).to receive(:run)

      results = service.run!

      # Verify that tuning happened by checking results exist
      expect(results['damage_mult']).to be_a(Hash)
    end

    it 'stores final results' do
      results = service.run!

      expect(results['damage_mult']).to be_a(Hash)
      expect(results['damage_mult']).to have_key('win_rate')
      expect(results['damage_mult']).to have_key('original')
      expect(results['damage_mult']).to have_key('final')
      expect(results['damage_mult']).to have_key('balanced')
    end

    it 'marks as balanced when within threshold' do
      # Mock to return exactly 50% win rate
      allow_any_instance_of(BalanceSimulator).to receive(:win_rate).and_return(50.0)

      results = service.run!

      expect(results['damage_mult']['balanced']).to be true
    end

    it 'marks as unbalanced when outside threshold' do
      # Mock to return 60% win rate (outside 5% threshold)
      allow_any_instance_of(BalanceSimulator).to receive(:win_rate).and_return(60.0)

      results = service.run!

      expect(results['damage_mult']['balanced']).to be false
    end
  end
end
