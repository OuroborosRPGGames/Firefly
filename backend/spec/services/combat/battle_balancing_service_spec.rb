# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BattleBalancingService do
  let(:pc_ids) { [1, 2, 3] }
  let(:mandatory_archetype_ids) { [10] }
  let(:optional_archetype_ids) { [20, 21] }

  let(:mock_archetype_10) { instance_double('NpcArchetype', id: 10, name: 'Boss') }
  let(:mock_archetype_20) { instance_double('NpcArchetype', id: 20, name: 'Minion') }
  let(:mock_archetype_21) { instance_double('NpcArchetype', id: 21, name: 'Minion2') }

  let(:mock_pc_participant) do
    instance_double('CombatSimulatorService::SimParticipant',
                    id: 1, name: 'Hero', is_pc: true, team: 1,
                    current_hp: 6, max_hp: 6, hex_x: 0, hex_y: 0,
                    damage_bonus: 2, defense_bonus: 1, speed_modifier: 0,
                    damage_dice_count: 2, damage_dice_sides: 6,
                    stat_modifier: 0.0, ai_profile: nil,
                    abilities: [], ability_chance: 0.0)
  end

  let(:mock_npc_participant) do
    instance_double('CombatSimulatorService::SimParticipant',
                    id: 100, name: 'Boss', is_pc: false, team: 2,
                    current_hp: 8, max_hp: 8, hex_x: 5, hex_y: 5,
                    damage_bonus: 3, defense_bonus: 2, speed_modifier: 0,
                    damage_dice_count: 3, damage_dice_sides: 6,
                    stat_modifier: 0.0, ai_profile: :aggressive,
                    abilities: [], ability_chance: 0.3)
  end

  before do
    # Stub NpcArchetype lookups with flexible matching
    allow(NpcArchetype).to receive(:where) do |args|
      ids = args[:id] || []
      archetypes = []
      archetypes << mock_archetype_10 if ids.include?(10)
      archetypes << mock_archetype_20 if ids.include?(20)
      archetypes << mock_archetype_21 if ids.include?(21)
      double(all: archetypes)
    end
    allow(NpcArchetype).to receive(:[]).with(10).and_return(mock_archetype_10)
    allow(NpcArchetype).to receive(:[]).with(20).and_return(mock_archetype_20)
    allow(NpcArchetype).to receive(:[]).with(21).and_return(mock_archetype_21)

    # Stub PowerCalculatorService
    allow(PowerCalculatorService).to receive(:calculate_pc_group_power).and_return(100)
    allow(PowerCalculatorService).to receive(:pcs_to_participants).and_return([mock_pc_participant])
    allow(PowerCalculatorService).to receive(:calculate_archetype_power).and_return(30)
    allow(PowerCalculatorService).to receive(:estimate_balanced_composition).and_return(
      { 10 => { count: 1, power: 80 } }
    )
    allow(PowerCalculatorService).to receive(:composition_to_participants).and_return([mock_npc_participant])
  end

  describe 'constants' do
    it 'defines SIMULATIONS' do
      expect(described_class::SIMULATIONS).to eq(100)
    end

    it 'defines MAX_ITERATIONS' do
      expect(described_class::MAX_ITERATIONS).to eq(10)
    end

    it 'defines DEFAULT_ARENA_WIDTH' do
      expect(described_class::DEFAULT_ARENA_WIDTH).to eq(10)
    end

    it 'defines DEFAULT_ARENA_HEIGHT' do
      expect(described_class::DEFAULT_ARENA_HEIGHT).to eq(10)
    end
  end

  describe '#initialize' do
    it 'stores pc_ids' do
      service = described_class.new(pc_ids: pc_ids, mandatory_archetype_ids: mandatory_archetype_ids)
      expect(service.pc_ids).to eq(pc_ids)
    end

    it 'stores mandatory_archetype_ids' do
      service = described_class.new(pc_ids: pc_ids, mandatory_archetype_ids: mandatory_archetype_ids)
      expect(service.mandatory_archetype_ids).to eq(mandatory_archetype_ids)
    end

    it 'stores optional_archetype_ids' do
      service = described_class.new(
        pc_ids: pc_ids,
        mandatory_archetype_ids: mandatory_archetype_ids,
        optional_archetype_ids: optional_archetype_ids
      )
      expect(service.optional_archetype_ids).to eq(optional_archetype_ids)
    end

    it 'defaults optional_archetype_ids to empty array' do
      service = described_class.new(pc_ids: pc_ids, mandatory_archetype_ids: mandatory_archetype_ids)
      expect(service.optional_archetype_ids).to eq([])
    end

    it 'initializes iterations_used to 0' do
      service = described_class.new(pc_ids: pc_ids, mandatory_archetype_ids: mandatory_archetype_ids)
      expect(service.iterations_used).to eq(0)
    end

    it 'initializes simulation_count to 0' do
      service = described_class.new(pc_ids: pc_ids, mandatory_archetype_ids: mandatory_archetype_ids)
      expect(service.simulation_count).to eq(0)
    end

    it 'loads PC power' do
      service = described_class.new(pc_ids: pc_ids, mandatory_archetype_ids: mandatory_archetype_ids)
      expect(service.pc_power).to eq(100)
    end

    it 'loads mandatory archetypes' do
      service = described_class.new(pc_ids: pc_ids, mandatory_archetype_ids: mandatory_archetype_ids)
      expect(service.mandatory_archetypes).to eq([mock_archetype_10])
    end

    it 'loads optional archetypes' do
      service = described_class.new(
        pc_ids: pc_ids,
        mandatory_archetype_ids: mandatory_archetype_ids,
        optional_archetype_ids: optional_archetype_ids
      )
      expect(service.optional_archetypes).to eq([mock_archetype_20, mock_archetype_21])
    end

    it 'loads PC participants' do
      service = described_class.new(pc_ids: pc_ids, mandatory_archetype_ids: mandatory_archetype_ids)
      expect(service.pc_participants).to eq([mock_pc_participant])
    end
  end

  describe '#balance!' do
    let(:service) do
      described_class.new(
        pc_ids: pc_ids,
        mandatory_archetype_ids: mandatory_archetype_ids,
        optional_archetype_ids: optional_archetype_ids
      )
    end

    let(:balanced_aggregate) do
      {
        win_rate: 1.0,
        avg_score: 55,
        is_balanced: true,
        score_distribution: { 30 => 10, 50 => 50, 70 => 40 }
      }
    end

    let(:unbalanced_aggregate) do
      {
        win_rate: 0.8,
        avg_score: 20,
        is_balanced: false,
        score_distribution: { 10 => 40, 20 => 40, 30 => 20 }
      }
    end

    let(:mock_sim_result) do
      instance_double('CombatSimulatorService::SimulationResult',
                      winner: :pcs, rounds: 5, pc_casualties: 1, npc_casualties: 3,
                      final_pc_hp_ratio: 0.6, final_npc_hp_ratio: 0.0)
    end

    before do
      mock_simulator = instance_double('CombatSimulatorService')
      allow(CombatSimulatorService).to receive(:new).and_return(mock_simulator)
      allow(mock_simulator).to receive(:simulate!).and_return(mock_sim_result)
    end

    context 'when balance is achieved immediately' do
      before do
        allow(BalanceScoreCalculator).to receive(:aggregate_scores).and_return(balanced_aggregate)
      end

      it 'returns balanced status' do
        result = service.balance!
        expect(result[:status]).to eq('balanced')
      end

      it 'returns composition' do
        result = service.balance!
        expect(result[:composition]).to be_a(Hash)
      end

      it 'returns difficulty_variants' do
        result = service.balance!
        expect(result[:difficulty_variants]).to have_key('easy')
        expect(result[:difficulty_variants]).to have_key('normal')
        expect(result[:difficulty_variants]).to have_key('hard')
        expect(result[:difficulty_variants]).to have_key('nightmare')
      end

      it 'returns pc_power' do
        result = service.balance!
        expect(result[:pc_power]).to eq(100)
      end

      it 'returns iterations_used' do
        result = service.balance!
        expect(result[:iterations_used]).to eq(1)
      end

      it 'returns simulation_count' do
        result = service.balance!
        expect(result[:simulation_count]).to eq(100)
      end

      it 'returns aggregate scores' do
        result = service.balance!
        expect(result[:aggregate]).to eq(balanced_aggregate)
      end
    end

    context 'when balance requires iterations' do
      before do
        # First call returns unbalanced, second returns balanced
        call_count = 0
        allow(BalanceScoreCalculator).to receive(:aggregate_scores) do
          call_count += 1
          call_count == 1 ? unbalanced_aggregate : balanced_aggregate
        end
        allow(BalanceScoreCalculator).to receive(:calculate_adjustment_factor).and_return(-0.1)
      end

      it 'iterates until balanced' do
        result = service.balance!
        expect(result[:status]).to eq('balanced')
        expect(result[:iterations_used]).to eq(2)
      end

      it 'runs more simulations' do
        result = service.balance!
        expect(result[:simulation_count]).to eq(200)
      end
    end

    context 'when balance cannot be achieved' do
      before do
        allow(BalanceScoreCalculator).to receive(:aggregate_scores).and_return(unbalanced_aggregate)
        allow(BalanceScoreCalculator).to receive(:calculate_adjustment_factor).and_return(-0.1)
      end

      it 'returns approximate status after max iterations' do
        result = service.balance!
        expect(result[:status]).to eq('approximate')
      end

      it 'uses all iterations' do
        result = service.balance!
        expect(result[:iterations_used]).to eq(10)
      end

      it 'returns best found aggregate' do
        result = service.balance!
        expect(result[:aggregate]).to eq(unbalanced_aggregate)
      end

      it 'returns stat modifiers from the best-scoring iteration' do
        aggregates = [
          { win_rate: 0.8, avg_score: 20, is_balanced: false },
          { win_rate: 0.7, avg_score: 20, is_balanced: false }
        ]
        allow(BalanceScoreCalculator).to receive(:aggregate_scores) do
          aggregates.shift || { win_rate: 0.7, avg_score: 20, is_balanced: false }
        end
        allow(BalanceScoreCalculator).to receive(:calculate_adjustment_factor).and_return(-0.1)

        result = service.balance!

        # First iteration is best by win_rate and has no modifier adjustments yet.
        expect(result[:status]).to eq('approximate')
        expect(result[:stat_modifiers]).to eq({})
      end
    end
  end

  describe '#quick_check' do
    let(:service) do
      described_class.new(
        pc_ids: pc_ids,
        mandatory_archetype_ids: mandatory_archetype_ids,
        optional_archetype_ids: optional_archetype_ids
      )
    end

    let(:composition) { { 10 => { count: 1, power: 80 } } }
    let(:aggregate) do
      { win_rate: 1.0, avg_score: 55, is_balanced: true }
    end

    let(:mock_sim_result) do
      instance_double('CombatSimulatorService::SimulationResult',
                      winner: :pcs, rounds: 5, pc_casualties: 1, npc_casualties: 3,
                      final_pc_hp_ratio: 0.6, final_npc_hp_ratio: 0.0)
    end

    before do
      mock_simulator = instance_double('CombatSimulatorService')
      allow(CombatSimulatorService).to receive(:new).and_return(mock_simulator)
      allow(mock_simulator).to receive(:simulate!).and_return(mock_sim_result)
      allow(BalanceScoreCalculator).to receive(:aggregate_scores).and_return(aggregate)
    end

    it 'runs simulations for the given composition' do
      expect(CombatSimulatorService).to receive(:new).at_least(:once).and_return(
        instance_double('CombatSimulatorService', simulate!: mock_sim_result)
      )
      service.quick_check(composition)
    end

    it 'returns aggregate scores' do
      result = service.quick_check(composition)
      expect(result).to eq(aggregate)
    end

    it 'accepts stat_modifiers' do
      stat_modifiers = { 10 => 0.1 }
      result = service.quick_check(composition, stat_modifiers: stat_modifiers)
      expect(result).to eq(aggregate)
    end
  end

  describe 'private methods' do
    let(:service) do
      described_class.new(
        pc_ids: pc_ids,
        mandatory_archetype_ids: mandatory_archetype_ids,
        optional_archetype_ids: optional_archetype_ids
      )
    end

    describe '#is_better_aggregate?' do
      it 'prefers higher win rate' do
        better = { win_rate: 1.0, avg_score: 30 }
        worse = { win_rate: 0.9, avg_score: 55 }
        expect(service.send(:is_better_aggregate?, better, worse)).to be true
      end

      it 'prefers score closer to ideal when win rates equal' do
        # Assuming ideal range is 30-80, mid is 55
        closer = { win_rate: 1.0, avg_score: 55 }
        farther = { win_rate: 1.0, avg_score: 20 }
        expect(service.send(:is_better_aggregate?, closer, farther)).to be true
      end

      it 'returns false when new is worse' do
        better = { win_rate: 1.0, avg_score: 55 }
        worse = { win_rate: 0.8, avg_score: 55 }
        expect(service.send(:is_better_aggregate?, worse, better)).to be false
      end
    end

    describe '#deep_copy' do
      it 'creates a new hash' do
        original = { a: { count: 1 }, b: 2 }
        copy = service.send(:deep_copy, original)
        expect(copy).not_to be(original)
      end

      it 'duplicates nested hashes' do
        original = { a: { count: 1 } }
        copy = service.send(:deep_copy, original)
        copy[:a][:count] = 99
        expect(original[:a][:count]).to eq(1)
      end
    end

    describe '#make_easier' do
      let(:composition) { { 10 => { count: 1 }, 20 => { count: 2 } } }
      let(:stat_modifiers) { {} }

      it 'reduces mandatory NPC stats' do
        service.send(:make_easier, composition, stat_modifiers, 0.1)
        expect(stat_modifiers[10]).to eq(-0.1)
      end

      it 'respects minimum stat modifier' do
        stat_modifiers[10] = -0.35
        service.send(:make_easier, composition, stat_modifiers, 0.1)
        expect(stat_modifiers[10]).to eq(-0.4)
      end

      it 'does not remove optional NPCs while mandatory stats can still be reduced' do
        service.send(:make_easier, composition, stat_modifiers, 0.1)
        expect(composition[20][:count]).to eq(2)
      end

      it 'removes optional NPCs after mandatory stats hit minimum' do
        stat_modifiers[10] = -0.4
        service.send(:make_easier, composition, stat_modifiers, 0.1)
        expect(composition[20][:count]).to eq(1)
      end
    end

    describe '#make_harder' do
      let(:composition) { { 10 => { count: 1 } } }
      let(:stat_modifiers) { {} }

      it 'adds optional NPCs first' do
        service.send(:make_harder, composition, stat_modifiers, 0.1)
        expect(composition[20]).not_to be_nil
        expect(composition[20][:count]).to eq(1)
      end

      it 'prefers least represented optional archetype' do
        composition[20] = { count: 3 }
        composition[21] = { count: 0 }

        service.send(:make_harder, composition, stat_modifiers, 0.1)

        expect(composition[21][:count]).to eq(1)
      end

      it 'boosts mandatory NPC stats when no optionals available' do
        # All optionals already at max
        allow(NpcArchetype).to receive(:[]).with(20).and_return(nil)
        allow(NpcArchetype).to receive(:[]).with(21).and_return(nil)

        service.send(:make_harder, composition, stat_modifiers, 0.1)
        expect(stat_modifiers[10]).to eq(0.1)
      end

      it 'respects maximum stat modifier' do
        stat_modifiers[10] = 0.35
        allow(NpcArchetype).to receive(:[]).with(20).and_return(nil)
        allow(NpcArchetype).to receive(:[]).with(21).and_return(nil)

        service.send(:make_harder, composition, stat_modifiers, 0.1)
        expect(stat_modifiers[10]).to eq(0.4)
      end
    end

    describe '#fine_tune' do
      let(:composition) { { 10 => { count: 1 } } }
      let(:stat_modifiers) { {} }

      it 'slightly reduces stats when below ideal mid' do
        aggregate = { avg_score: 40 } # Below 55 mid
        service.send(:fine_tune, composition, stat_modifiers, aggregate)
        expect(stat_modifiers[10]).to eq(-0.05)
      end

      it 'slightly increases stats when above ideal mid' do
        aggregate = { avg_score: 70 } # Above 55 mid
        service.send(:fine_tune, composition, stat_modifiers, aggregate)
        expect(stat_modifiers[10]).to eq(0.05)
      end
    end

    describe '#generate_difficulty_variants' do
      let(:base_composition) { { 10 => { count: 1 } } }
      let(:base_modifiers) { { 10 => 0.0 } }

      it 'returns all difficulty levels' do
        variants = service.send(:generate_difficulty_variants, base_composition, base_modifiers)
        expect(variants.keys).to contain_exactly('easy', 'normal', 'hard', 'nightmare')
      end

      it 'easy has negative modifier' do
        variants = service.send(:generate_difficulty_variants, base_composition, base_modifiers)
        expect(variants['easy'][:stat_modifiers][10]).to eq(-0.20)
      end

      it 'normal has base modifier' do
        variants = service.send(:generate_difficulty_variants, base_composition, base_modifiers)
        expect(variants['normal'][:stat_modifiers][10]).to eq(0.0)
      end

      it 'hard has positive modifier' do
        variants = service.send(:generate_difficulty_variants, base_composition, base_modifiers)
        expect(variants['hard'][:stat_modifiers][10]).to eq(0.15)
      end

      it 'nightmare has higher positive modifier' do
        variants = service.send(:generate_difficulty_variants, base_composition, base_modifiers)
        expect(variants['nightmare'][:stat_modifiers][10]).to eq(0.30)
      end

      it 'returns independent normal composition copy' do
        variants = service.send(:generate_difficulty_variants, base_composition, base_modifiers)
        variants['normal'][:composition][10][:count] = 9

        expect(base_composition[10][:count]).to eq(1)
      end

      it 'returns independent normal modifier copy' do
        variants = service.send(:generate_difficulty_variants, base_composition, base_modifiers)
        variants['normal'][:stat_modifiers][10] = 0.25

        expect(base_modifiers[10]).to eq(0.0)
      end
    end

    describe '#apply_difficulty_variant' do
      let(:composition) { { 10 => { count: 1 }, 20 => { count: 2 } } }
      let(:base_modifiers) { { 10 => 0.1, 20 => -0.1 } }

      it 'applies modifier to all archetypes' do
        result = service.send(:apply_difficulty_variant, composition, base_modifiers, 0.2)
        expect(result[:stat_modifiers][10]).to be_within(0.001).of(0.3)
        expect(result[:stat_modifiers][20]).to be_within(0.001).of(0.1)
      end

      it 'clamps modifiers to valid range' do
        high_modifiers = { 10 => 0.4 }
        result = service.send(:apply_difficulty_variant, composition, high_modifiers, 0.3)
        expect(result[:stat_modifiers][10]).to eq(0.5) # Clamped at 0.5
      end

      it 'duplicates composition' do
        result = service.send(:apply_difficulty_variant, composition, base_modifiers, 0.2)
        expect(result[:composition]).not_to be(composition)
      end
    end
  end
end
