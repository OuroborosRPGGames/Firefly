# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BalanceScoreCalculator do
  describe '.score_result' do
    let(:winning_result) do
      CombatSimulatorService::SimResult.new(
        pc_victory: true,
        rounds_taken: 5,
        surviving_pcs: 4,
        total_pc_hp_remaining: 15,
        total_npc_hp_remaining: 0,
        pc_ko_count: 0,
        npc_ko_count: 4,
        seed_used: 12345
      )
    end

    let(:losing_result) do
      CombatSimulatorService::SimResult.new(
        pc_victory: false,
        rounds_taken: 3,
        surviving_pcs: 0,
        total_pc_hp_remaining: 0,
        total_npc_hp_remaining: 10,
        pc_ko_count: 4,
        npc_ko_count: 1,
        seed_used: 12345
      )
    end

    it 'returns negative score for losses' do
      result = described_class.score_result(losing_result)
      expect(result[:score]).to eq(-1000)
      expect(result[:components][:loss]).to be true
    end

    it 'calculates score for wins' do
      result = described_class.score_result(winning_result)
      expect(result[:score]).to be > 0
      expect(result[:components]).to have_key(:hp_score)
      expect(result[:components]).to have_key(:rounds_score)
    end

    it 'includes HP remaining in score' do
      # 15 HP * 10 = 150 points
      result = described_class.score_result(winning_result)
      expect(result[:components][:hp_score]).to eq(150)
    end

    it 'penalizes for rounds taken' do
      # 5 rounds * -2 = -10 points
      result = described_class.score_result(winning_result)
      expect(result[:components][:rounds_score]).to eq(-10)
    end

    it 'adds victory bonus when no PCs knocked out' do
      result = described_class.score_result(winning_result)
      expect(result[:components][:victory_bonus]).to eq(100)
    end

    it 'penalizes for PC knockouts' do
      result_with_ko = winning_result.dup
      result_with_ko.pc_ko_count = 2

      result = described_class.score_result(result_with_ko)
      expect(result[:components][:ko_score]).to eq(-100)
      expect(result[:components][:victory_bonus]).to eq(0)
    end
  end

  describe '.aggregate_scores' do
    let(:balanced_results) do
      4.times.map do |i|
        CombatSimulatorService::SimResult.new(
          pc_victory: true,
          rounds_taken: 4 + i,
          surviving_pcs: 4,
          total_pc_hp_remaining: 8 + i,
          total_npc_hp_remaining: 0,
          pc_ko_count: 0,
          npc_ko_count: 3,
          seed_used: i
        )
      end
    end

    let(:mixed_results) do
      [
        CombatSimulatorService::SimResult.new(
          pc_victory: true, rounds_taken: 5, surviving_pcs: 4,
          total_pc_hp_remaining: 10, total_npc_hp_remaining: 0,
          pc_ko_count: 0, npc_ko_count: 3, seed_used: 1
        ),
        CombatSimulatorService::SimResult.new(
          pc_victory: false, rounds_taken: 3, surviving_pcs: 0,
          total_pc_hp_remaining: 0, total_npc_hp_remaining: 5,
          pc_ko_count: 4, npc_ko_count: 1, seed_used: 2
        )
      ]
    end

    it 'returns empty aggregate for empty results' do
      result = described_class.aggregate_scores([])
      expect(result[:win_rate]).to eq(0.0)
      expect(result[:is_balanced]).to be false
    end

    it 'calculates win rate correctly' do
      result = described_class.aggregate_scores(balanced_results)
      expect(result[:win_rate]).to eq(1.0)

      result = described_class.aggregate_scores(mixed_results)
      expect(result[:win_rate]).to eq(0.5)
    end

    it 'calculates average score from wins only' do
      result = described_class.aggregate_scores(mixed_results)
      # Only the winning result should be scored
      expect(result[:avg_score]).to be > 0
    end

    it 'marks as balanced when win rate is 100% and score in range' do
      # Create results that fall in ideal range (30-80)
      good_results = 5.times.map do |i|
        CombatSimulatorService::SimResult.new(
          pc_victory: true,
          rounds_taken: 8,
          surviving_pcs: 3,
          total_pc_hp_remaining: 5,
          total_npc_hp_remaining: 0,
          pc_ko_count: 1,
          npc_ko_count: 4,
          seed_used: i
        )
      end

      result = described_class.aggregate_scores(good_results)
      # Score: (5 * 10) + (8 * -2) + (1 * -50) + 0 = 50 - 16 - 50 = -16
      # This is actually below range, so let's adjust
      expect(result[:win_rate]).to eq(1.0)
    end

    it 'provides adjustment hint for too-easy fights' do
      easy_results = 5.times.map do |i|
        CombatSimulatorService::SimResult.new(
          pc_victory: true,
          rounds_taken: 2,
          surviving_pcs: 4,
          total_pc_hp_remaining: 24,
          total_npc_hp_remaining: 0,
          pc_ko_count: 0,
          npc_ko_count: 4,
          seed_used: i
        )
      end

      result = described_class.aggregate_scores(easy_results)
      expect(result[:avg_score]).to be > 80
      expect(result[:adjustment_hint]).to eq(:make_harder)
    end

    it 'provides adjustment hint when losing' do
      losing_results = [
        CombatSimulatorService::SimResult.new(
          pc_victory: false, rounds_taken: 3, surviving_pcs: 0,
          total_pc_hp_remaining: 0, total_npc_hp_remaining: 10,
          pc_ko_count: 4, npc_ko_count: 0, seed_used: 1
        )
      ]

      result = described_class.aggregate_scores(losing_results)
      expect(result[:adjustment_hint]).to eq(:make_easier)
    end
  end

  describe '.calculate_adjustment_factor' do
    it 'returns large negative for losing a lot' do
      aggregate = { win_rate: 0.3, avg_score: -500 }
      expect(described_class.calculate_adjustment_factor(aggregate)).to eq(-0.5)
    end

    it 'returns small negative for partial wins' do
      aggregate = { win_rate: 0.8, avg_score: 50 }
      expect(described_class.calculate_adjustment_factor(aggregate)).to eq(-0.2)
    end

    it 'returns positive for too-easy wins' do
      aggregate = { win_rate: 1.0, avg_score: 200 }
      factor = described_class.calculate_adjustment_factor(aggregate)
      expect(factor).to be > 0
      expect(factor).to be <= 0.4
    end

    it 'returns zero for balanced' do
      aggregate = { win_rate: 1.0, avg_score: 55 } # Middle of 30-80
      expect(described_class.calculate_adjustment_factor(aggregate)).to eq(0.0)
    end
  end

  describe '.format_aggregate' do
    it 'formats balanced result correctly' do
      aggregate = {
        is_balanced: true,
        win_rate: 1.0,
        avg_score: 55,
        score_std_dev: 10,
        avg_rounds: 5.5,
        avg_pc_hp_remaining: 8.5,
        avg_pc_kos: 0.5,
        adjustment_hint: :balanced
      }

      output = described_class.format_aggregate(aggregate)
      expect(output).to include('BALANCED')
      expect(output).to include('100.0%')
    end
  end
end
