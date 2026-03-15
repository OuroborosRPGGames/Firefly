# frozen_string_literal: true

require 'spec_helper'

# Load the balance simulator script (it's not auto-loaded)
require_relative '../../scripts/ability_balance_simulator'

RSpec.describe 'Ability Balance Simulator' do
  # Known formula constants for sense-checking
  BASELINE_DAMAGE = 11      # 2d10 average
  BASELINE_HP = 6           # Standard combatant HP

  before(:all) do
    # Ensure coefficients are loaded once for all tests
    BalanceCoefficients.load!(mode: :fresh)
  end

  # ============================================
  # CRITICAL ASSUMPTIONS
  # These tests verify fundamental assumptions that must not change.
  # If any of these fail, the balance system may produce invalid results.
  # ============================================

  describe 'CRITICAL ASSUMPTIONS' do
    describe 'Power = Average Damage (no multiplier)' do
      it 'base_damage_power equals average damage directly' do
        ability = SyntheticAbility.new(
          name: 'test_damage',
          damage_dice: '2d10',
          status_effects: []
        )
        config = { ability: ability, category: nil }

        power = FormulaPowerCalculator.new(config).calculate_power

        # 2d10 average = 11, power must equal 11 (NOT 11 * 3.5 = 38.5)
        expect(power).to eq(11.0)
      end

      it 'does not inflate damage beyond threshold ranges' do
        # Thresholds: ≤10=miss, 11-15=1HP, 16-24=2HP, 25+=3HP
        # Power values must stay in realistic damage ranges
        ability = SyntheticAbility.new(
          name: 'high_damage',
          damage_dice: '3d10+5', # 21.5 avg
          status_effects: []
        )
        config = { ability: ability, category: nil }

        power = FormulaPowerCalculator.new(config).calculate_power

        # Must be ~21.5, not ~75 (which would break thresholds)
        expect(power).to be_between(20, 25)
      end
    end

    describe 'Control Ability Configuration' do
      it 'uses fixed 2d10+4 dice (not scaled dice)' do
        control = PureDamageControlAbility.new(30)
        expect(control.base_damage_dice).to eq('2d10+4')
      end

      it 'BASE_POWER equals 15 (average of 2d10+4)' do
        expect(PureDamageControlAbility::BASE_POWER).to eq(15.0)
      end

      it 'power_multiplier = target_power / BASE_POWER' do
        control = PureDamageControlAbility.new(30)
        expect(control.power_multiplier).to eq(2.0) # 30 / 15
      end

      it 'responds to power_scaled? for combat simulator integration' do
        control = PureDamageControlAbility.new(15)
        expect(control.power_scaled?).to be true
        expect(control).to respond_to(:power_multiplier)
      end
    end

    describe 'Team Equality (Basic Attacks)' do
      let(:config) { AbilityGenerator.generate_cc_abilities.first }
      let(:sim) { BalanceSimulator.new(config) }

      it 'both teams have identical basic attacks (2d10)' do
        test_team = sim.send(:build_team, config[:ability], 2)
        control_ability = PureDamageControlAbility.new(15)
        control_team = sim.send(:build_team, control_ability, 2)

        [test_team, control_team].flatten.each do |p|
          expect(p.damage_dice_count).to eq(2)
          expect(p.damage_dice_sides).to eq(10)
        end
      end

      it 'both teams have damage_multiplier of 1.0' do
        test_team = sim.send(:build_team, config[:ability], 2)
        control_ability = PureDamageControlAbility.new(15)
        control_team = sim.send(:build_team, control_ability, 2)

        [test_team, control_team].flatten.each do |p|
          expect(p.damage_multiplier).to eq(1.0)
        end
      end

      it 'teams have non-overlapping ID ranges' do
        test_team = sim.send(:build_team, config[:ability], 3)
        control_ability = PureDamageControlAbility.new(15)
        control_team = sim.send(:build_team, control_ability, 3)

        test_ids = test_team.map(&:id)
        control_ids = control_team.map(&:id)

        expect(test_ids & control_ids).to be_empty
      end
    end

    describe 'Combat Damage Thresholds' do
      let(:participant) do
        CombatSimulatorService::SimParticipant.new(
          id: 1, name: 'Test', is_pc: true, team: 'test',
          current_hp: 6, max_hp: 6, hex_x: 0, hex_y: 0,
          damage_bonus: 0, defense_bonus: 0, speed_modifier: 0,
          damage_dice_count: 2, damage_dice_sides: 10,
          stat_modifier: 0, ai_profile: 'balanced',
          abilities: [], ability_chance: 0, damage_multiplier: 1.0
        )
      end

      it 'damage <10 causes 0 HP loss' do
        expect(participant.calculate_hp_loss(0)).to eq(0)
        expect(participant.calculate_hp_loss(9)).to eq(0)
      end

      it 'damage 10-17 causes 1 HP loss' do
        expect(participant.calculate_hp_loss(10)).to eq(1)
        expect(participant.calculate_hp_loss(17)).to eq(1)
      end

      it 'damage 18-29 causes 2 HP loss' do
        expect(participant.calculate_hp_loss(18)).to eq(2)
        expect(participant.calculate_hp_loss(29)).to eq(2)
      end

      it 'damage 30-99 causes 3 HP loss' do
        expect(participant.calculate_hp_loss(30)).to eq(3)
        expect(participant.calculate_hp_loss(99)).to eq(3)
      end

      it 'damage 100+ causes 4+ HP loss with 100 damage bands' do
        expect(participant.calculate_hp_loss(100)).to eq(4)
        expect(participant.calculate_hp_loss(199)).to eq(4)
        expect(participant.calculate_hp_loss(200)).to eq(5)
        expect(participant.calculate_hp_loss(300)).to eq(6)
      end
    end

    describe 'Baseline Constants' do
      it 'baseline damage is 11 (2d10 average)' do
        expect(BalanceCoefficients.baseline(:damage)).to eq(11)
      end

      it 'baseline HP is 6' do
        expect(BalanceCoefficients.baseline(:hp)).to eq(6)
      end
    end
  end

  # ============================================
  # 1. BalanceCoefficients Module
  # ============================================

  describe BalanceCoefficients do
    describe '.load!' do
      it 'loads fresh coefficients in fresh mode' do
        BalanceCoefficients.load!(mode: :fresh)
        # Use actual coefficient names from INITIAL_COEFFICIENTS
        expect(BalanceCoefficients.get(:cc_stun_1r)).to eq(1.0)
        expect(BalanceCoefficients.get(:dot_burning_2r)).to eq(1.0)
      end

      it 'loads from YAML in refine mode when file exists' do
        # Save current values
        BalanceCoefficients.load!(mode: :fresh)
        BalanceCoefficients.set(:cc_stun_1r, 1.5)
        BalanceCoefficients.save!

        # Reload in refine mode
        BalanceCoefficients.load!(mode: :refine)
        expect(BalanceCoefficients.get(:cc_stun_1r)).to eq(1.5)

        # Reset to fresh for other tests
        BalanceCoefficients.load!(mode: :fresh)
        BalanceCoefficients.save!
      end
    end

    describe '.get and .set' do
      before { BalanceCoefficients.load!(mode: :fresh) }

      it 'returns INITIAL value for known key' do
        expect(BalanceCoefficients.get(:cc_stun_1r)).to eq(1.0)
      end

      it 'returns nil for unknown key' do
        expect(BalanceCoefficients.get(:nonexistent_key)).to be_nil
      end

      it 'persists set values' do
        BalanceCoefficients.set(:cc_skip_mult, 2.0)
        expect(BalanceCoefficients.get(:cc_skip_mult)).to eq(2.0)
      end
    end

    describe '.baseline' do
      before { BalanceCoefficients.load!(mode: :fresh) }

      it 'returns correct baseline damage' do
        expect(BalanceCoefficients.baseline(:damage)).to eq(11)
      end

      it 'returns correct baseline HP' do
        expect(BalanceCoefficients.baseline(:hp)).to eq(6)
      end

      it 'returns correct hits per round' do
        expect(BalanceCoefficients.baseline(:hits_per_round)).to eq(1)
      end

      it 'returns correct rounds per fight' do
        expect(BalanceCoefficients.baseline(:rounds_per_fight)).to eq(4)
      end
    end

    describe 'duration_factor calculation' do
      before { BalanceCoefficients.load!(mode: :fresh) }

      # Access private method for testing
      def duration_factor(duration)
        BalanceCoefficients.send(:duration_factor, duration)
      end

      it 'returns base factor for duration 1' do
        expect(duration_factor(1)).to eq(1.0)
      end

      it 'returns correct factor for duration 2' do
        # base + decay^1 = 1.0 + 0.5 = 1.5
        expect(duration_factor(2)).to eq(1.5)
      end

      it 'returns correct factor for duration 3' do
        # base + decay^1 + decay^2 = 1.0 + 0.5 + 0.25 = 1.75
        expect(duration_factor(3)).to eq(1.75)
      end

      it 'converges toward limit with geometric decay' do
        # With decay=0.5, geometric series converges to 2.0 (sum = 1/(1-0.5) = 2)
        # So duration_factor(10) ≈ 1.998, never reaching max_factor of 2.5
        expect(duration_factor(10)).to be_within(0.01).of(2.0)
      end

      it 'respects max_factor when series could exceed it' do
        # Test with a higher decay that could exceed max_factor
        BalanceCoefficients.set(:duration_decay, 0.9)
        # 1 + 0.9 + 0.81 + 0.729 + ... would exceed 2.5 quickly
        # But should be capped at 2.5
        factor = duration_factor(5)
        expect(factor).to be <= BalanceCoefficients.get(:duration_max_factor)

        # Reset
        BalanceCoefficients.load!(mode: :fresh)
      end
    end

    describe 'dot_duration_factor calculation' do
      before { BalanceCoefficients.load!(mode: :fresh) }

      def dot_duration_factor(duration)
        BalanceCoefficients.send(:dot_duration_factor, duration)
      end

      it 'returns correct factor for duration 1' do
        # 0.7^0 = 1.0
        expect(dot_duration_factor(1)).to eq(1.0)
      end

      it 'returns correct factor for duration 2' do
        # 0.7^0 + 0.7^1 = 1.0 + 0.7 = 1.7
        expect(dot_duration_factor(2)).to eq(1.7)
      end

      it 'returns correct factor for duration 3' do
        # 0.7^0 + 0.7^1 + 0.7^2 = 1.0 + 0.7 + 0.49 = 2.19
        expect(dot_duration_factor(3)).to be_within(0.01).of(2.19)
      end
    end

    describe '.save!' do
      before { BalanceCoefficients.load!(mode: :fresh) }

      it 'exports coefficients to AbilityPowerWeights' do
        BalanceCoefficients.set(:cc_skip_mult, 1.25)
        BalanceCoefficients.save!
        AbilityPowerWeights.reload!

        expect(AbilityPowerWeights.coefficient('cc_skip_mult')).to eq(1.25)
      end

      it 'exports derived status weights' do
        BalanceCoefficients.load!(mode: :fresh)
        BalanceCoefficients.save!
        AbilityPowerWeights.reload!

        # stunned = baseline_damage * cc_skip_mult * duration_factor(1)
        # = 11 * 1.0 * 1.0 = 11
        expect(AbilityPowerWeights.status('stunned')).to eq(11)
      end

      it 'exports duration-neutral status baselines for runtime duration scaling' do
        BalanceCoefficients.load!(mode: :fresh)
        BalanceCoefficients.save!
        AbilityPowerWeights.reload!

        # Runtime applies duration curves, so exported weights should be per-round baselines.
        expect(AbilityPowerWeights.status('dazed')).to be_within(0.01).of(5.5)
        expect(AbilityPowerWeights.status('burning')).to be_within(0.01).of(4.0)
        expect(AbilityPowerWeights.status('shielded_10hp')).to be_within(0.01).of(10.0)
      end

      it 'maps tunable coefficients to runtime weight paths' do
        BalanceCoefficients.load!(mode: :fresh)
        BalanceCoefficients.save!
        AbilityPowerWeights.reload!

        expect(AbilityPowerWeights.get('aoe', 'action_economy_multiplier')).to eq(BalanceCoefficients.get(:aoe_action_economy))
        expect(AbilityPowerWeights.get('aoe', 'friendly_fire_penalty')).to eq(BalanceCoefficients.get(:aoe_ff_penalty))
        expect(AbilityPowerWeights.get('chain', 'target_efficiency')).to eq(BalanceCoefficients.get(:chain_target_efficiency))
        expect(AbilityPowerWeights.get('special', 'lifesteal_fraction')).to eq(BalanceCoefficients.get(:lifesteal_efficiency))
      end
    end
  end

  # ============================================
  # 2. FormulaPowerCalculator
  # ============================================

  describe FormulaPowerCalculator do
    before(:each) { BalanceCoefficients.load!(mode: :fresh) }

    describe 'base damage power' do
      it 'calculates power from damage dice average' do
        ability = SyntheticAbility.new(name: 'test', damage_dice: '2d6')
        config = { ability: ability, category: nil }
        calc = FormulaPowerCalculator.new(config)

        # 2d6 avg = 7, power = average damage (no multiplier)
        expect(calc.send(:base_damage_power)).to eq(7.0)
      end

      it 'returns 0 for nil damage dice' do
        ability = SyntheticAbility.new(name: 'test', damage_dice: nil)
        config = { ability: ability, category: nil }
        calc = FormulaPowerCalculator.new(config)

        expect(calc.send(:base_damage_power)).to eq(0)
      end
    end

    describe 'CC skip power (stunned)' do
      it 'calculates stun power correctly' do
        config = AbilityGenerator.generate_cc_abilities.find { |c| c[:ability].name == 'stun_1r' }
        calc = FormulaPowerCalculator.new(config)

        # CC skip: baseline_damage * cc_skip_mult * duration_factor(1)
        # = 11 * 1.0 * 1.0 = 11
        effect_power = calc.send(:effect_power)
        expect(effect_power).to eq(11)
      end

      it 'scales with duration' do
        config_1r = AbilityGenerator.generate_cc_abilities.find { |c| c[:ability].name == 'stun_1r' }
        config_2r = AbilityGenerator.generate_cc_abilities.find { |c| c[:ability].name == 'stun_2r' }

        power_1r = FormulaPowerCalculator.new(config_1r).send(:effect_power)
        power_2r = FormulaPowerCalculator.new(config_2r).send(:effect_power)

        expect(power_2r).to be > power_1r
      end
    end

    describe 'CC penalty power (dazed)' do
      it 'calculates daze power with 50% penalty' do
        config = AbilityGenerator.generate_cc_abilities.find { |c| c[:ability].name == 'daze_1r' }
        calc = FormulaPowerCalculator.new(config)

        # CC penalty: baseline_damage * penalty * coefficient * duration_factor
        # = 11 * 0.5 * 1.0 * 1.0 = 5.5 (coefficients are 1.0 by default)
        effect_power = calc.send(:effect_power)
        expect(effect_power).to be_within(0.5).of(5.5)
      end
    end

    describe 'DoT power' do
      it 'calculates burning power correctly' do
        config = AbilityGenerator.generate_dot_abilities.find { |c| c[:ability].name == 'burning_2r' }
        calc = FormulaPowerCalculator.new(config)

        # DoT: dot_damage * dot_efficiency * dot_duration_factor(2)
        # burning damage = 4 (from STATUS_EFFECTS)
        # = 4 * 1.0 * 1.7 = 6.8
        effect_power = calc.send(:effect_power)
        expect(effect_power).to be_within(1).of(6.8)
      end
    end

    describe 'Buff power (empowered)' do
      it 'calculates empowered power correctly' do
        config = AbilityGenerator.generate_buff_abilities.find { |c| c[:ability].name == 'empower_5dmg_2r' }
        calc = FormulaPowerCalculator.new(config)

        # Buff: bonus * buff_mult * duration_factor(2)
        # = 5 * 1.0 * 1.5 = 7.5
        effect_power = calc.send(:effect_power)
        expect(effect_power).to eq(7.5)
      end
    end

    describe 'Shield power' do
      it 'calculates shield power with duration scaling' do
        config = AbilityGenerator.generate_shield_abilities.find { |c| c[:ability].name == 'shield_10hp_3r' }
        calc = FormulaPowerCalculator.new(config)

        # Shield: hp * coefficient * duration_factor
        # = 10 * 1.0 * 1.75 = 17.5 (3-round duration factor)
        effect_power = calc.send(:effect_power)
        expect(effect_power).to be_within(0.5).of(17.5)
      end
    end

    describe 'Mitigation power' do
      it 'calculates armored (per-hit) power' do
        config = AbilityGenerator.generate_mitigation_abilities.find { |c| c[:ability].name == 'armor_3red_3r' }
        calc = FormulaPowerCalculator.new(config)

        # Mitigation per-hit: reduction * hits_per_round * mitigation_per_hit * duration_factor
        # = 3 * 1 * 1.0 * 1.75 = 5.25
        effect_power = calc.send(:effect_power)
        expect(effect_power).to be_within(0.5).of(5.25)
      end

      it 'calculates protected (pool) power' do
        config = AbilityGenerator.generate_mitigation_abilities.find { |c| c[:ability].name == 'protect_5red_2r' }
        calc = FormulaPowerCalculator.new(config)

        # Mitigation pool: reduction * mitigation_pool * duration_factor
        # = 5 * 1.0 * 1.5 = 7.5
        effect_power = calc.send(:effect_power)
        expect(effect_power).to eq(7.5)
      end
    end

    describe 'AoE multiplier' do
      it 'applies multiplier for circle radius 2' do
        config = AbilityGenerator.generate_aoe_abilities.find { |c| c[:ability].name == 'aoe_circle_r2' }
        calc = FormulaPowerCalculator.new(config)

        # aoe_circle_r2 coefficient = 2.5
        expect(calc.send(:aoe_multiplier)).to eq(2.5)
      end

      it 'returns 1.0 for single target' do
        ability = SyntheticAbility.new(name: 'single', damage_dice: '1d6')
        config = { ability: ability }
        calc = FormulaPowerCalculator.new(config)

        expect(calc.send(:aoe_multiplier)).to eq(1.0)
      end
    end

    describe 'Defensive abilities' do
      it 'shield abilities have 0 base damage' do
        config = AbilityGenerator.generate_shield_abilities.first
        calc = FormulaPowerCalculator.new(config)

        expect(calc.send(:base_damage_power)).to eq(0)
      end

      it 'protected abilities have 0 base damage' do
        config = AbilityGenerator.generate_mitigation_abilities.find { |c| c[:category] == :mitigation_pool }
        calc = FormulaPowerCalculator.new(config)

        expect(calc.send(:base_damage_power)).to eq(0)
      end
    end
  end

  # ============================================
  # 3. SyntheticAbility Duck-Typing
  # ============================================

  describe SyntheticAbility do
    let(:ability) do
      SyntheticAbility.new(
        name: 'test_ability',
        damage_dice: '2d6',
        status_effects: [{ 'effect' => 'stunned', 'duration' => 1 }]
      )
    end

    it 'responds to average_damage' do
      expect(ability).to respond_to(:average_damage)
      expect(ability.average_damage).to eq(7) # 2d6 avg
    end

    it 'responds to parsed_status_effects' do
      expect(ability).to respond_to(:parsed_status_effects)
      expect(ability.parsed_status_effects).to be_an(Array)
      expect(ability.parsed_status_effects.first['effect']).to eq('stunned')
    end

    it 'responds to has_aoe?' do
      expect(ability).to respond_to(:has_aoe?)
      expect(ability.has_aoe?).to be false
    end

    it 'responds to power' do
      expect(ability).to respond_to(:power)
      expect(ability.power).to be_a(Integer)
    end

    describe 'with AoE' do
      let(:aoe_ability) do
        SyntheticAbility.new(
          name: 'aoe_test',
          damage_dice: '1d8',
          aoe_shape: 'circle',
          aoe_radius: 2
        )
      end

      it 'correctly identifies as AoE' do
        expect(aoe_ability.has_aoe?).to be true
      end

      it 'returns correct aoe_shape' do
        expect(aoe_ability.aoe_shape).to eq('circle')
      end

      it 'returns correct aoe_radius' do
        expect(aoe_ability.aoe_radius).to eq(2)
      end
    end

    describe 'status effect with variable data' do
      it 'passes through damage_mult' do
        vuln_ability = SyntheticAbility.new(
          name: 'vuln_test',
          status_effects: [{ 'effect' => 'vulnerable', 'duration' => 2, 'damage_mult' => 2.0 }]
        )
        expect(vuln_ability.parsed_status_effects.first['damage_mult']).to eq(2.0)
      end

      it 'passes through shield_hp' do
        shield_ability = SyntheticAbility.new(
          name: 'shield_test',
          status_effects: [{ 'effect' => 'shielded', 'duration' => 3, 'shield_hp' => 15 }]
        )
        expect(shield_ability.parsed_status_effects.first['shield_hp']).to eq(15)
      end
    end
  end

  # ============================================
  # 4. AbilityGenerator
  # ============================================

  describe AbilityGenerator do
    describe '.generate_all' do
      let(:all_abilities) { AbilityGenerator.generate_all }

      it 'returns at least 30 abilities' do
        expect(all_abilities.size).to be >= 30
      end

      it 'each ability has a category' do
        all_abilities.each do |config|
          expect(config).to have_key(:category)
        end
      end

      it 'each ability has a coef_key' do
        all_abilities.each do |config|
          expect(config).to have_key(:coef_key)
        end
      end
    end

    describe '.generate_cc_abilities' do
      let(:cc_abilities) { AbilityGenerator.generate_cc_abilities }

      it 'includes stun_1r and stun_2r' do
        names = cc_abilities.map { |c| c[:ability].name }
        expect(names).to include('stun_1r', 'stun_2r')
      end

      it 'includes daze_1r, daze_2r, daze_3r' do
        names = cc_abilities.map { |c| c[:ability].name }
        expect(names).to include('daze_1r', 'daze_2r', 'daze_3r')
      end

      it 'includes prone_1r' do
        names = cc_abilities.map { |c| c[:ability].name }
        expect(names).to include('prone_1r')
      end
    end

    describe '.generate_dot_abilities' do
      let(:dot_abilities) { AbilityGenerator.generate_dot_abilities }

      it 'includes all DoT types' do
        names = dot_abilities.map { |c| c[:ability].name }
        expect(names).to include('burning_2r', 'poisoned_2r', 'bleeding_2r', 'freezing_2r')
      end

      it 'includes 3-round variants' do
        names = dot_abilities.map { |c| c[:ability].name }
        expect(names).to include('burning_3r', 'poisoned_3r')
      end
    end

    describe '.generate_shield_abilities' do
      let(:shield_abilities) { AbilityGenerator.generate_shield_abilities }

      it 'all have nil damage_dice' do
        shield_abilities.each do |config|
          expect(config[:ability].base_damage_dice).to be_nil
        end
      end
    end

    describe '.find' do
      it 'finds ability by name' do
        ability = AbilityGenerator.find('stun_1r')
        expect(ability).to be_a(SyntheticAbility)
        expect(ability.name).to eq('stun_1r')
      end

      it 'returns nil for unknown ability' do
        expect(AbilityGenerator.find('nonexistent')).to be_nil
      end
    end
  end

  # ============================================
  # 5. BalanceSimulator
  # ============================================

  describe BalanceSimulator do
    before(:each) { BalanceCoefficients.load!(mode: :fresh) }

    describe 'team building' do
      let(:config) { AbilityGenerator.generate_cc_abilities.first }
      let(:simulator) { BalanceSimulator.new(config) }

      it 'creates correct team size' do
        team = simulator.send(:build_team, config[:ability], 3)
        expect(team.size).to eq(3)
      end

      it 'all team members have BASE_HP' do
        team = simulator.send(:build_team, config[:ability], 3)
        team.each do |member|
          expect(member.current_hp).to eq(BalanceSimulator::BASE_HP)
        end
      end
    end

    describe 'win rate calculation' do
      let(:config) { AbilityGenerator.generate_cc_abilities.first }
      let(:simulator) { BalanceSimulator.new(config) }

      it 'returns 50 when no battles run' do
        expect(simulator.win_rate).to eq(50.0)
      end

      it 'calculates percentage correctly' do
        simulator.instance_variable_set(:@results, { test_wins: 60, control_wins: 40, draws: 0 })
        expect(simulator.win_rate).to eq(60.0)
      end

      it 'treats draws as half-wins for win rate' do
        simulator.instance_variable_set(:@results, { test_wins: 40, control_wins: 40, draws: 20 })
        expect(simulator.win_rate).to eq(50.0)
      end
    end

    describe 'balanced? check' do
      let(:config) { AbilityGenerator.generate_cc_abilities.first }
      let(:simulator) { BalanceSimulator.new(config) }

      it 'returns true for 50% win rate' do
        simulator.instance_variable_set(:@results, { test_wins: 50, control_wins: 50, draws: 0 })
        expect(simulator.balanced?).to be true
      end

      it 'returns true for 48% win rate (within threshold)' do
        simulator.instance_variable_set(:@results, { test_wins: 48, control_wins: 52, draws: 0 })
        expect(simulator.balanced?).to be true
      end

      it 'returns false for 45% win rate (outside threshold)' do
        simulator.instance_variable_set(:@results, { test_wins: 45, control_wins: 55, draws: 0 })
        expect(simulator.balanced?).to be false
      end
    end

    describe '#run' do
      let(:config) { AbilityGenerator.generate_cc_abilities.first }
      let(:simulator) { BalanceSimulator.new(config) }

      it 'does not double-count draws as control wins' do
        draw_result = instance_double(
          'CombatSimulatorService::SimResult',
          pc_victory: false,
          rounds_taken: 3,
          npc_ko_count: 0,
          pc_ko_count: 0
        )
        control_result = instance_double(
          'CombatSimulatorService::SimResult',
          pc_victory: false,
          rounds_taken: 4,
          npc_ko_count: 1,
          pc_ko_count: 2
        )

        fake_sim = instance_double('CombatSimulatorService')
        allow(CombatSimulatorService).to receive(:new).and_return(fake_sim)
        allow(fake_sim).to receive(:simulate!).and_return(draw_result, control_result)

        simulator.run(iterations: 2, seed: 123)

        expect(simulator.results).to eq(test_wins: 0, control_wins: 1, draws: 1)
      end

      it 'uses deterministic team sizes for a fixed seed' do
        draw_result = instance_double(
          'CombatSimulatorService::SimResult',
          pc_victory: false,
          rounds_taken: 1,
          npc_ko_count: 0,
          pc_ko_count: 0
        )

        first_sizes = []
        allow(CombatSimulatorService).to receive(:new) do |args|
          first_sizes << args[:pcs].size
          instance_double('CombatSimulatorService', simulate!: draw_result)
        end
        simulator.run(iterations: 6, seed: 777)

        second_sizes = []
        simulator2 = BalanceSimulator.new(config)
        allow(CombatSimulatorService).to receive(:new) do |args|
          second_sizes << args[:pcs].size
          instance_double('CombatSimulatorService', simulate!: draw_result)
        end
        simulator2.run(iterations: 6, seed: 777)

        expect(first_sizes).to eq(second_sizes)
      end
    end
  end

  # ============================================
  # 6. PureDamageControlAbility
  # ============================================

  describe PureDamageControlAbility do
    describe 'power scaling' do
      it 'calculates multiplier from target power' do
        control = PureDamageControlAbility.new(22.5)
        # multiplier = 22.5 / 15 = 1.5
        expect(control.power_multiplier).to eq(1.5)
      end

      it 'has base dice 2d10+4' do
        control = PureDamageControlAbility.new(100)
        expect(control.base_damage_dice).to eq('2d10+4')
      end

      it 'reports power_scaled? as true' do
        control = PureDamageControlAbility.new(100)
        expect(control.power_scaled?).to be true
      end

      it 'has no status effects' do
        control = PureDamageControlAbility.new(100)
        expect(control.parsed_status_effects).to be_empty
      end
    end
  end

  # ============================================
  # 7. Formula Sense Checks (no simulation needed)
  # ============================================

  describe 'Formula Sense Checks' do
    before(:each) { BalanceCoefficients.load!(mode: :fresh) }

    describe 'Power values are in reasonable ranges' do
      it 'stun_1r power is reasonable (effect only, no base damage)' do
        config = AbilityGenerator.generate_all.find { |c| c[:ability].name == 'stun_1r' }
        power = FormulaPowerCalculator.new(config).calculate_power

        # Stun 1r: 1d6 (3.5 avg) + 11 * 1.0 * 1.0 = 3.5 + 11 = ~14.5
        # Should be in range 10-20
        expect(power).to be_between(10, 20)
      end

      it 'stun_2r power is higher than stun_1r' do
        config_1r = AbilityGenerator.generate_all.find { |c| c[:ability].name == 'stun_1r' }
        config_2r = AbilityGenerator.generate_all.find { |c| c[:ability].name == 'stun_2r' }

        power_1r = FormulaPowerCalculator.new(config_1r).calculate_power
        power_2r = FormulaPowerCalculator.new(config_2r).calculate_power

        expect(power_2r).to be > power_1r
      end

      it 'burning_2r power is reasonable' do
        config = AbilityGenerator.generate_all.find { |c| c[:ability].name == 'burning_2r' }
        power = FormulaPowerCalculator.new(config).calculate_power

        # Burning 2r: 1d6 (3.5) + 4 * 1.0 * dot_factor(2) ≈ 3.5 + 6.8 = ~10
        expect(power).to be_between(8, 15)
      end

      it 'shield_10hp power includes duration scaling' do
        config = AbilityGenerator.generate_all.find { |c| c[:ability].name == 'shield_10hp_3r' }
        power = FormulaPowerCalculator.new(config).calculate_power

        # Shield: 10 * 1.0 * 1.75 = 17.5 (no base damage, but has duration factor)
        expect(power).to be_within(1).of(17.5)
      end

      it 'aoe_circle_r2 power is multiplied by target count' do
        config = AbilityGenerator.generate_all.find { |c| c[:ability].name == 'aoe_circle_r2' }
        calc = FormulaPowerCalculator.new(config)

        base_power = calc.send(:base_damage_power)
        total_power = calc.calculate_power

        # AoE r2 multiplier = 2.5
        expect(total_power).to be_within(1).of(base_power * 2.5)
      end
    end

    describe 'Power ratios make sense' do
      it 'longer duration effects have more power' do
        abilities = AbilityGenerator.generate_all
        daze_1r = abilities.find { |c| c[:ability].name == 'daze_1r' }
        daze_2r = abilities.find { |c| c[:ability].name == 'daze_2r' }
        daze_3r = abilities.find { |c| c[:ability].name == 'daze_3r' }

        power_1 = FormulaPowerCalculator.new(daze_1r).calculate_power
        power_2 = FormulaPowerCalculator.new(daze_2r).calculate_power
        power_3 = FormulaPowerCalculator.new(daze_3r).calculate_power

        expect(power_1).to be < power_2
        expect(power_2).to be < power_3
      end

      it 'larger shields have more power' do
        abilities = AbilityGenerator.generate_all
        shield_10 = abilities.find { |c| c[:ability].name == 'shield_10hp_3r' }
        shield_15 = abilities.find { |c| c[:ability].name == 'shield_15hp_2r' }
        shield_20 = abilities.find { |c| c[:ability].name == 'shield_20hp_2r' }

        power_10 = FormulaPowerCalculator.new(shield_10).calculate_power
        power_15 = FormulaPowerCalculator.new(shield_15).calculate_power
        power_20 = FormulaPowerCalculator.new(shield_20).calculate_power

        expect(power_10).to be < power_15
        expect(power_15).to be < power_20
      end

      it 'higher damage reduction has more power' do
        abilities = AbilityGenerator.generate_all
        armor_3 = abilities.find { |c| c[:ability].name == 'armor_3red_3r' }
        armor_4 = abilities.find { |c| c[:ability].name == 'armor_4red_2r' }
        armor_6 = abilities.find { |c| c[:ability].name == 'armor_6red_1r' }

        power_3 = FormulaPowerCalculator.new(armor_3).calculate_power
        power_4 = FormulaPowerCalculator.new(armor_4).calculate_power
        power_6 = FormulaPowerCalculator.new(armor_6).calculate_power

        # 3 reduction for 3 rounds vs 4 for 2 rounds vs 6 for 1 round
        # All should be similar-ish in power
        expect([power_3, power_4, power_6].max - [power_3, power_4, power_6].min).to be < 10
      end
    end

    describe 'Control ability scaling' do
      it 'PureDamageControlAbility at power 15 has multiplier 1.0' do
        control = PureDamageControlAbility.new(15)
        expect(control.power_multiplier).to eq(1.0)
      end

      it 'PureDamageControlAbility at power 30 has multiplier 2.0' do
        control = PureDamageControlAbility.new(30)
        expect(control.power_multiplier).to eq(2.0)
      end

      it 'control ability power matches target power' do
        [10, 15, 20, 30].each do |target|
          control = PureDamageControlAbility.new(target)
          expect(control.power).to eq(target)
        end
      end
    end

    describe 'All generated abilities have valid power' do
      it 'no abilities have negative power' do
        AbilityGenerator.generate_all.each do |config|
          power = FormulaPowerCalculator.new(config).calculate_power
          expect(power).to be >= 0, "#{config[:ability].name} has negative power: #{power}"
        end
      end

      it 'no abilities have NaN or Infinity power' do
        AbilityGenerator.generate_all.each do |config|
          power = FormulaPowerCalculator.new(config).calculate_power
          expect(power).not_to be_nan, "#{config[:ability].name} has NaN power"
          expect(power).to be < Float::INFINITY, "#{config[:ability].name} has Infinity power"
        end
      end

      it 'all abilities have power less than 500 (sanity check)' do
        AbilityGenerator.generate_all.each do |config|
          power = FormulaPowerCalculator.new(config).calculate_power
          expect(power).to be < 500, "#{config[:ability].name} has unexpectedly high power: #{power}"
        end
      end
    end
  end

  # ============================================
  # 8. Edge Cases
  # ============================================

  describe 'Edge Cases' do
    before(:each) { BalanceCoefficients.load!(mode: :fresh) }

    describe 'nil damage dice' do
      it 'does not crash' do
        ability = SyntheticAbility.new(name: 'no_damage', damage_dice: nil)
        # Use a real coefficient key that exists in INITIAL_COEFFICIENTS
        config = { ability: ability, category: :shield, coef_key: :shield_10hp_3r, shield_hp: 10 }

        expect { FormulaPowerCalculator.new(config).calculate_power }.not_to raise_error
      end
    end

    describe 'duration 0 status effect' do
      it 'handles gracefully' do
        ability = SyntheticAbility.new(
          name: 'zero_duration',
          damage_dice: '1d6',
          status_effects: [{ 'effect' => 'stunned', 'duration' => 0 }]
        )
        # Use a real coefficient key that exists in INITIAL_COEFFICIENTS
        config = { ability: ability, category: :cc_skip, coef_key: :cc_stun_1r, duration: 0 }

        power = FormulaPowerCalculator.new(config).calculate_power
        expect(power).to be >= 0
      end
    end

    describe 'very high power ability' do
      it 'does not overflow' do
        ability = SyntheticAbility.new(
          name: 'high_power',
          damage_dice: '10d12',
          status_effects: [
            { 'effect' => 'stunned', 'duration' => 5 },
            { 'effect' => 'burning', 'duration' => 5 }
          ],
          aoe_shape: 'circle',
          aoe_radius: 4
        )
        # Use a real coefficient key that exists in INITIAL_COEFFICIENTS
        config = { ability: ability, category: :cc_skip, coef_key: :cc_stun_1r, duration: 5 }

        power = FormulaPowerCalculator.new(config).calculate_power
        expect(power).to be < Float::INFINITY
        expect(power).not_to be_nan
      end
    end

    describe 'missing coefficient key' do
      it 'falls back to default' do
        expect(BalanceCoefficients.get(:nonexistent_key)).to be_nil
        # This confirms the fallback behavior - nil is returned, not an error
      end
    end

    describe 'AoE radius 5+ (no defined weight)' do
      it 'uses fallback multiplier' do
        ability = SyntheticAbility.new(
          name: 'huge_aoe',
          damage_dice: '1d6',
          aoe_shape: 'circle',
          aoe_radius: 5
        )
        config = { ability: ability, category: :aoe, coef_key: :aoe_circle_r5 }
        calc = FormulaPowerCalculator.new(config)

        # Should fallback to 1.0 when coefficient not found
        multiplier = calc.send(:aoe_multiplier)
        expect(multiplier).to eq(1.0)
      end
    end
  end

  # ============================================
  # 9. Known Issues Verification
  # ============================================

  describe 'Known Issues Verification' do
    before(:each) { BalanceCoefficients.load!(mode: :fresh) }

    describe 'DoT damage values' do
      it 'burning has 4 damage in STATUS_EFFECTS' do
        burning = CombatSimulatorService::STATUS_EFFECTS[:burning]
        expect(burning[:dot_damage]).to eq(4)
      end

      it 'poisoned has 2 damage in STATUS_EFFECTS' do
        poisoned = CombatSimulatorService::STATUS_EFFECTS[:poisoned]
        expect(poisoned[:dot_damage]).to eq(2)
      end

      it 'bleeding has 3 damage in STATUS_EFFECTS' do
        bleeding = CombatSimulatorService::STATUS_EFFECTS[:bleeding]
        expect(bleeding[:dot_damage]).to eq(3)
      end

      it 'generator uses correct DoT damage from STATUS_EFFECTS' do
        burning_config = AbilityGenerator.generate_dot_abilities.find { |c| c[:ability].name == 'burning_2r' }
        expect(burning_config[:dot_damage]).to eq(4)
      end
    end

    describe 'Debuff attack_penalty lookup' do
      it 'frightened has attack_penalty defined' do
        frightened = CombatSimulatorService::STATUS_EFFECTS[:frightened]
        expect(frightened).to have_key(:attack_penalty)
      end

      it 'taunted effect exists' do
        taunted = CombatSimulatorService::STATUS_EFFECTS[:taunted]
        expect(taunted).not_to be_nil
      end
    end

    describe 'Team assignment (is_pc flag)' do
      let(:config) { AbilityGenerator.generate_cc_abilities.first }
      let(:simulator) { BalanceSimulator.new(config) }

      it 'test team has is_pc=true' do
        team = simulator.send(:build_team, config[:ability], 2)
        team.each do |member|
          expect(member.is_pc).to be true
        end
      end

      it 'control team has is_pc=false' do
        control_ability = PureDamageControlAbility.new(100)
        team = simulator.send(:build_team, control_ability, 2)
        team.each do |member|
          expect(member.is_pc).to be false
        end
      end
    end
  end
end
