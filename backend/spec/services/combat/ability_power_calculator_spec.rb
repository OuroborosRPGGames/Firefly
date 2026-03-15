# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AbilityPowerCalculator do
  let(:universe) { create(:universe) }
  let(:ability) { create(:ability, universe: universe) }

  describe 'constants' do
    it 'uses GameConfig for DEFAULT_POWER_PER_DAMAGE' do
      expect(GameConfig::AbilityPower::DEFAULT_POWER_PER_DAMAGE).to be_within(0.1).of(100.0 / 15.0)
    end

    it 'uses GameConfig for PC_UNIFIED_ROLL_EXPECTED' do
      expect(GameConfig::Mechanics::UNIFIED_ROLL[:expected_value]).to eq(10.3)
    end

    it 'defines THRESHOLD_PROBABILITIES' do
      expect(described_class::THRESHOLD_PROBABILITIES).to be_a(Hash)
      expect(described_class::THRESHOLD_PROBABILITIES[2]).to eq(1.0)
    end
  end

  describe '#initialize' do
    it 'sets ability and for_pc flag' do
      calc = described_class.new(ability, for_pc: true)
      expect(calc.ability).to eq(ability)
      expect(calc.for_pc).to be true
    end

    it 'defaults for_pc to false' do
      calc = described_class.new(ability)
      expect(calc.for_pc).to be false
    end

    it 'infers for_pc true for persisted pc abilities' do
      ability.update(user_type: 'pc')

      calc = described_class.new(ability)
      expect(calc.for_pc).to be true
    end

    it 'honors synthetic is_pc_ability flag when present' do
      synthetic = Struct.new(:is_pc_ability).new(true)

      calc = described_class.new(synthetic)
      expect(calc.for_pc).to be true
    end
  end

  describe '#total_power' do
    it 'returns integer' do
      calc = described_class.new(ability)
      expect(calc.total_power).to be_an(Integer)
    end

    it 'returns sum of breakdown components' do
      calc = described_class.new(ability)
      breakdown = calc.breakdown
      expected = breakdown.values.sum.round

      expect(calc.total_power).to eq(expected)
    end
  end

  describe '#breakdown' do
    it 'returns hash with power components' do
      calc = described_class.new(ability)
      breakdown = calc.breakdown

      expect(breakdown).to include(
        :base_damage,
        :aoe_bonus,
        :chain_bonus,
        :status_effects,
        :special_mechanics,
        :cost_penalties
      )
    end

    it 'caches breakdown' do
      calc = described_class.new(ability)
      breakdown1 = calc.breakdown
      breakdown2 = calc.breakdown

      expect(breakdown1.object_id).to eq(breakdown2.object_id)
    end
  end

  describe 'base damage calculation' do
    it 'returns 0 when no damage dice' do
      ability.update(base_damage_dice: nil)
      calc = described_class.new(ability)

      expect(calc.breakdown[:base_damage]).to eq(0)
    end
  end

  describe 'AoE calculation' do
    it 'returns 0 for single target' do
      ability.update(aoe_shape: 'single')
      calc = described_class.new(ability)

      expect(calc.breakdown[:aoe_bonus]).to eq(0)
    end

    it 'calculates bonus for circle AoE' do
      ability.update(aoe_shape: 'circle', aoe_radius: 3, base_damage_dice: '2d6')
      calc = described_class.new(ability)

      expect(calc.breakdown[:aoe_bonus]).to be >= 0
    end

    it 'calculates bonus for cone AoE' do
      ability.update(aoe_shape: 'cone', aoe_length: 4, aoe_angle: 60, base_damage_dice: '2d6')
      calc = described_class.new(ability)

      expect(calc.breakdown[:aoe_bonus]).to be >= 0
    end

    it 'calculates bonus for line AoE' do
      ability.update(aoe_shape: 'line', aoe_length: 5, base_damage_dice: '2d6')
      calc = described_class.new(ability)

      expect(calc.breakdown[:aoe_bonus]).to be >= 0
    end

    it 'applies friendly-fire penalty when AoE hits allies' do
      ability.update(aoe_shape: 'circle', aoe_radius: 3, base_damage_dice: '2d6', aoe_hits_allies: false)
      no_friendly_fire = described_class.new(ability).breakdown[:aoe_bonus]

      ability.update(aoe_hits_allies: true)
      with_friendly_fire = described_class.new(ability).breakdown[:aoe_bonus]

      expect(with_friendly_fire).to be < no_friendly_fire
    end
  end

  describe 'chain calculation' do
    it 'returns 0 when no chain' do
      ability.update(chain_config: nil)
      allow(ability).to receive(:has_chain?).and_return(false)
      calc = described_class.new(ability)

      expect(calc.breakdown[:chain_bonus]).to eq(0)
    end

    it 'applies target efficiency multiplier for chain bonus' do
      ability.update(base_damage_dice: '2d6')
      allow(ability).to receive(:has_chain?).and_return(true)
      allow(ability).to receive(:parsed_chain_config).and_return({ 'max_targets' => 3, 'damage_falloff' => 1.0 })

      allow(AbilityPowerWeights).to receive(:get).and_call_original
      allow(AbilityPowerWeights).to receive(:get).with('chain', 'target_efficiency', default: 1.0).and_return(1.0)
      full_efficiency = described_class.new(ability).breakdown[:chain_bonus]

      allow(AbilityPowerWeights).to receive(:get).with('chain', 'target_efficiency', default: 1.0).and_return(0.5)
      half_efficiency = described_class.new(ability).breakdown[:chain_bonus]

      expect(half_efficiency).to be_within(0.01).of(full_efficiency * 0.5)
    end
  end

  describe 'status effect calculation' do
    it 'returns 0 when no status effects' do
      allow(ability).to receive(:parsed_status_effects).and_return([])
      calc = described_class.new(ability)

      expect(calc.breakdown[:status_effects]).to eq(0)
    end

    it 'calculates power for status effects' do
      effects = [{ 'effect' => 'burning', 'duration_rounds' => 3, 'chance' => 1.0 }]
      allow(ability).to receive(:parsed_status_effects).and_return(effects)
      calc = described_class.new(ability)

      expect(calc.breakdown[:status_effects]).to be >= 0
    end

    it 'uses geometric duration scaling for non-dot effects' do
      effects = [{ 'effect' => 'stunned', 'duration_rounds' => 3, 'chance' => 1.0 }]
      allow(ability).to receive(:parsed_status_effects).and_return(effects)

      allow(AbilityPowerWeights).to receive(:get).and_call_original
      allow(AbilityPowerWeights).to receive(:get).with('duration', 'base_factor', default: 1.0).and_return(1.0)
      allow(AbilityPowerWeights).to receive(:get).with('duration', 'subsequent_factor', default: 0.5).and_return(0.5)
      allow(AbilityPowerWeights).to receive(:get).with('duration', 'max_factor', default: 2.5).and_return(2.5)

      calc = described_class.new(ability)
      allow(calc).to receive(:status_power).and_return(10)

      # Geometric scaling: 1.0 + 0.5 + 0.25 = 1.75, then rounded.
      expect(calc.send(:calculate_status_power)).to eq(18)
    end
  end

  describe 'special mechanics calculation' do
    it 'returns 0 when no special mechanics' do
      allow(ability).to receive(:has_execute?).and_return(false)
      allow(ability).to receive(:has_forced_movement?).and_return(false)
      allow(ability).to receive(:has_lifesteal?).and_return(false)
      allow(ability).to receive(:has_conditional_damage?).and_return(false)
      allow(ability).to receive(:has_combo?).and_return(false)
      ability.update(bypasses_resistances: false)
      calc = described_class.new(ability)

      expect(calc.breakdown[:special_mechanics]).to eq(0)
    end

    it 'adds power for resistance bypass' do
      ability.update(bypasses_resistances: true)
      allow(ability).to receive(:has_execute?).and_return(false)
      allow(ability).to receive(:has_forced_movement?).and_return(false)
      allow(ability).to receive(:has_lifesteal?).and_return(false)
      allow(ability).to receive(:has_conditional_damage?).and_return(false)
      allow(ability).to receive(:has_combo?).and_return(false)
      calc = described_class.new(ability)

      expect(calc.breakdown[:special_mechanics]).to be > 0
    end

    it 'applies lifesteal efficiency multiplier' do
      ability.update(base_damage_dice: '2d6', lifesteal_max: 20, bypasses_resistances: false)
      allow(ability).to receive(:has_execute?).and_return(false)
      allow(ability).to receive(:has_forced_movement?).and_return(false)
      allow(ability).to receive(:has_lifesteal?).and_return(true)
      allow(ability).to receive(:has_conditional_damage?).and_return(false)
      allow(ability).to receive(:has_combo?).and_return(false)

      allow(AbilityPowerWeights).to receive(:get).and_call_original
      allow(AbilityPowerWeights).to receive(:get).with('special', 'lifesteal_fraction', default: 1.0).and_return(1.0)
      full_efficiency = described_class.new(ability).breakdown[:special_mechanics]

      allow(AbilityPowerWeights).to receive(:get).with('special', 'lifesteal_fraction', default: 1.0).and_return(0.5)
      half_efficiency = described_class.new(ability).breakdown[:special_mechanics]

      expect(half_efficiency).to be_within(1).of(full_efficiency * 0.5)
    end
  end

  describe 'cost penalties calculation' do
    it 'returns 0 when no costs' do
      allow(ability).to receive(:parsed_costs).and_return({})
      ability.update(cooldown_seconds: 0)
      calc = described_class.new(ability)

      expect(calc.breakdown[:cost_penalties]).to eq(0)
    end

    it 'applies ability penalty cost from costs JSONB' do
      costs = { 'ability_penalty' => { 'amount' => -2, 'decay_per_round' => 1 } }
      allow(ability).to receive(:parsed_costs).and_return(costs)
      ability.update(cooldown_seconds: 0)
      calc = described_class.new(ability)

      # Ability penalties should reduce total power.
      expect(calc.breakdown[:cost_penalties]).to be <= 0
    end
  end

  describe 'threshold probability calculation' do
    it 'returns 1.0 for low thresholds' do
      calc = described_class.new(ability)
      prob = calc.send(:calculate_threshold_probability, 2)
      expect(prob).to eq(1.0)
    end

    it 'returns 1.0 for nil threshold' do
      calc = described_class.new(ability)
      prob = calc.send(:calculate_threshold_probability, nil)
      expect(prob).to eq(1.0)
    end

    it 'returns low probability for high thresholds' do
      calc = described_class.new(ability)
      prob = calc.send(:calculate_threshold_probability, 20)
      expect(prob).to be < 0.1
    end

    it 'returns minimum for very high thresholds' do
      calc = described_class.new(ability)
      prob = calc.send(:calculate_threshold_probability, 25)
      expect(prob).to eq(0.01)
    end
  end

  describe 'status weight key building' do
    it 'builds key for armored effect' do
      calc = described_class.new(ability)
      key = calc.send(:build_status_weight_key, 'armored', { 'damage_reduction' => 4 })
      expect(key).to eq('armored_4red')
    end

    it 'builds key for shielded effect' do
      calc = described_class.new(ability)
      key = calc.send(:build_status_weight_key, 'shielded', { 'shield_hp' => 10 })
      expect(key).to eq('shielded_10hp')
    end

    it 'builds key for empowered effect' do
      calc = described_class.new(ability)
      key = calc.send(:build_status_weight_key, 'empowered', { 'damage_bonus' => 5 })
      expect(key).to eq('empowered_5dmg')
    end

    it 'returns name for unknown effects' do
      calc = described_class.new(ability)
      key = calc.send(:build_status_weight_key, 'custom', {})
      expect(key).to eq('custom')
    end

    it 'builds key for fractional vulnerable multipliers' do
      calc = described_class.new(ability)
      key = calc.send(:build_status_weight_key, 'vulnerable', { 'damage_mult' => 1.5 })
      expect(key).to eq('vulnerable_1_5x')
    end
  end

  describe 'AoE scaling formulas' do
    it 'scales circle AoE bonus with radius' do
      ability.update(base_damage_dice: '2d6', aoe_shape: 'circle', aoe_radius: 1)
      small_aoe = described_class.new(ability).breakdown[:aoe_bonus]

      ability.update(aoe_radius: 5)
      large_aoe = described_class.new(ability).breakdown[:aoe_bonus]

      expect(large_aoe).to be > small_aoe
    end

    it 'scales cone AoE with angle' do
      ability.update(base_damage_dice: '2d6', aoe_shape: 'cone', aoe_length: 4, aoe_angle: 30)
      narrow = described_class.new(ability).breakdown[:aoe_bonus]

      ability.update(aoe_angle: 120)
      wide = described_class.new(ability).breakdown[:aoe_bonus]

      expect(wide).to be > narrow
    end

    it 'scales line AoE with length' do
      ability.update(base_damage_dice: '2d6', aoe_shape: 'line', aoe_length: 2)
      short = described_class.new(ability).breakdown[:aoe_bonus]

      ability.update(aoe_length: 8)
      long_line = described_class.new(ability).breakdown[:aoe_bonus]

      expect(long_line).to be >= short
    end
  end

  describe 'cost penalty formulas' do
    it 'applies cooldown penalty proportional to duration' do
      ability.update(base_damage_dice: '3d6', cooldown_seconds: 0)
      allow(ability).to receive(:parsed_costs).and_return({})
      no_cd_power = described_class.new(ability).total_power

      ability.update(cooldown_seconds: 120)
      with_cd_power = described_class.new(ability).total_power

      expect(with_cd_power).to be < no_cd_power
    end

    it 'caps cooldown penalty at max percentage' do
      ability.update(base_damage_dice: '3d6', cooldown_seconds: 1000)
      allow(ability).to receive(:parsed_costs).and_return({})
      long_cd_power = described_class.new(ability).breakdown[:cost_penalties]

      ability.update(cooldown_seconds: 10_000)
      very_long_cd_power = described_class.new(ability).breakdown[:cost_penalties]

      # Both should be capped at the same maximum penalty
      expect(long_cd_power).to eq(very_long_cd_power)
    end

    it 'applies ability penalty from costs' do
      ability.update(base_damage_dice: '3d6', cooldown_seconds: 0)
      allow(ability).to receive(:parsed_costs).and_return({ 'ability_penalty' => { 'amount' => -3 } })
      penalty = described_class.new(ability).breakdown[:cost_penalties]

      expect(penalty).to be < 0
    end
  end

  describe 'healing multiplier' do
    it 'applies healing_multiplier to healing abilities' do
      ability.update(base_damage_dice: '2d6', is_healing: false)
      damage_power = described_class.new(ability).breakdown[:base_damage]

      ability.update(is_healing: true)
      healing_power = described_class.new(ability).breakdown[:base_damage]

      # healing_multiplier is 1.5 — healing is valued more
      expect(healing_power).not_to eq(damage_power)
    end
  end

  describe 'damage stat scaling' do
    it 'adds stat bonus power when damage_stat present' do
      ability.update(base_damage_dice: '2d6', damage_stat: nil)
      no_stat_power = described_class.new(ability).breakdown[:base_damage]

      ability.update(damage_stat: 'STR')
      with_stat_power = described_class.new(ability).breakdown[:base_damage]

      expect(with_stat_power).to be > no_stat_power
    end
  end

  describe 'damage multiplier' do
    it 'scales base damage by damage_multiplier' do
      ability.update(base_damage_dice: '2d6', damage_multiplier: 1.0)
      base = described_class.new(ability).breakdown[:base_damage]

      ability.update(damage_multiplier: 2.0)
      doubled = described_class.new(ability).breakdown[:base_damage]

      expect(doubled).to be_within(1).of(base * 2)
    end
  end
end
