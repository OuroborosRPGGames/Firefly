# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Generators::AdversaryGeneratorService do
  describe '.generate' do
    let(:adversaries) do
      [
        {
          'name' => 'Shadow Assassin',
          'description' => 'A deadly masked killer',
          'role' => 'boss',
          'behavior' => 'cunning',
          'combat_encounter_key' => 'shadow_assassin'
        },
        {
          'name' => 'Manor Guard',
          'description' => 'A trained household guard',
          'role' => 'minion',
          'behavior' => 'aggressive',
          'combat_encounter_key' => 'manor_guards'
        }
      ]
    end
    let(:setting) { :fantasy }
    let(:difficulty) { :normal }

    let(:llm_stats) do
      {
        'max_hp' => 30,
        'damage_dice_count' => 3,
        'damage_dice_sides' => 8,
        'damage_bonus' => 4,
        'defense_bonus' => 3,
        'speed_modifier' => 1,
        'ability_chance' => 30,
        'flee_threshold' => 0,
        'ai_profile' => 'balanced'
      }
    end

    before do
      allow(LLM::Client).to receive(:generate).and_return({
        success: true,
        text: llm_stats.to_json
      })
    end

    it 'creates NpcArchetype records for each adversary' do
      result = described_class.generate(
        adversaries: adversaries,
        setting: setting,
        difficulty: difficulty
      )

      expect(result[:success]).to be true
      expect(result[:archetypes]).to be_a(Hash)
      expect(result[:archetypes].keys).to include('shadow_assassin')
      expect(result[:archetypes].keys).to include('manor_guards')
    end

    it 'returns empty archetypes for nil input' do
      result = described_class.generate(
        adversaries: nil,
        setting: setting,
        difficulty: difficulty
      )

      expect(result[:success]).to be true
      expect(result[:archetypes]).to be_empty
    end

    it 'returns empty archetypes for empty array' do
      result = described_class.generate(
        adversaries: [],
        setting: setting,
        difficulty: difficulty
      )

      expect(result[:success]).to be true
      expect(result[:archetypes]).to be_empty
    end

    it 'collects errors for failed generations' do
      allow(NpcArchetype).to receive(:create).and_raise(StandardError.new('DB error'))

      result = described_class.generate(
        adversaries: adversaries,
        setting: setting,
        difficulty: difficulty
      )

      expect(result[:errors]).not_to be_empty
    end
  end

  describe '.generate_adversary' do
    let(:adversary) do
      {
        'name' => 'Goblin Shaman',
        'description' => 'A cunning goblin spellcaster',
        'role' => 'lieutenant',
        'behavior' => 'cunning'
      }
    end

    before do
      allow(LLM::Client).to receive(:generate).and_return({
        success: true,
        text: { 'max_hp' => 20, 'damage_dice_count' => 2, 'damage_dice_sides' => 8,
                'damage_bonus' => 2, 'defense_bonus' => 2 }.to_json
      })
    end

    it 'creates NpcArchetype with correct attributes' do
      result = described_class.generate_adversary(
        adversary: adversary,
        setting: :fantasy,
        difficulty: :normal
      )

      expect(result[:success]).to be true
      archetype = result[:archetype]
      expect(archetype).to be_a(NpcArchetype)
      expect(archetype.name).to eq('Goblin Shaman')
      expect(archetype.is_generated).to be true
    end

    it 'uses fallback stats when LLM fails' do
      allow(LLM::Client).to receive(:generate).and_return({
        success: false,
        error: 'API error'
      })

      result = described_class.generate_adversary(
        adversary: adversary,
        setting: :fantasy,
        difficulty: :normal
      )

      expect(result[:success]).to be true
      expect(result[:archetype].combat_max_hp).to be_positive
    end
  end

  describe '.generate_fallback_stats' do
    it 'generates stats for boss role' do
      stats = described_class.send(:generate_fallback_stats, :boss, :normal, 'aggressive')

      expect(stats['max_hp']).to be_between(25, 40)
      expect(stats['ai_profile']).to eq('aggressive')
    end

    it 'generates stats for minion role' do
      stats = described_class.send(:generate_fallback_stats, :minion, :normal, 'defensive')

      expect(stats['max_hp']).to be_between(5, 12)
      expect(stats['flee_threshold']).to eq(20)
    end

    it 'scales stats by difficulty' do
      easy_stats = described_class.send(:generate_fallback_stats, :lieutenant, :easy, 'balanced')
      hard_stats = described_class.send(:generate_fallback_stats, :lieutenant, :hard, 'balanced')

      # Hard should generally have higher stats due to multiplier
      # (though RNG could occasionally make this fail)
      expect(hard_stats['max_hp']).to be >= (easy_stats['max_hp'] * 0.8)
    end
  end

  describe 'ROLE_STATS' do
    it 'defines stats for boss, lieutenant, and minion' do
      expect(described_class::ROLE_STATS).to have_key(:boss)
      expect(described_class::ROLE_STATS).to have_key(:lieutenant)
      expect(described_class::ROLE_STATS).to have_key(:minion)
    end

    it 'has higher HP for boss than minion' do
      boss_hp = described_class::ROLE_STATS[:boss][:hp_range].max
      minion_hp = described_class::ROLE_STATS[:minion][:hp_range].max

      expect(boss_hp).to be > minion_hp
    end
  end

  describe 'DIFFICULTY_MULTIPLIERS' do
    it 'has lower multiplier for easy than hard' do
      expect(described_class::DIFFICULTY_MULTIPLIERS[:easy]).to be < described_class::DIFFICULTY_MULTIPLIERS[:hard]
    end

    it 'has 1.0 multiplier for normal' do
      expect(described_class::DIFFICULTY_MULTIPLIERS[:normal]).to eq(1.0)
    end
  end
end
