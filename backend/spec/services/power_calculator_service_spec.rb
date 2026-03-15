# frozen_string_literal: true

require 'spec_helper'

RSpec.describe PowerCalculatorService do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }

  describe '.calculate_archetype_power' do
    let(:archetype) do
      NpcArchetype.create(
        name: 'Test Warrior',
        combat_max_hp: 6,
        combat_damage_bonus: 2,
        combat_defense_bonus: 1,
        combat_speed_modifier: 0,
        damage_dice_count: 2,
        damage_dice_sides: 6,
        combat_ai_profile: 'balanced'
      )
    end

    it 'calculates power rating based on combat stats' do
      power = described_class.calculate_archetype_power(archetype)
      expect(power).to be_a(Float)
      expect(power).to be > 0
    end

    it 'gives higher power to archetypes with more HP' do
      low_hp_archetype = NpcArchetype.create(
        name: 'Low HP NPC',
        combat_max_hp: 3,
        combat_ai_profile: 'balanced'
      )
      high_hp_archetype = NpcArchetype.create(
        name: 'High HP NPC',
        combat_max_hp: 9,
        combat_ai_profile: 'balanced'
      )

      low_power = described_class.calculate_archetype_power(low_hp_archetype)
      high_power = described_class.calculate_archetype_power(high_hp_archetype)

      expect(high_power).to be > low_power
    end

    it 'applies AI profile modifiers' do
      berserker = NpcArchetype.create(
        name: 'Berserker NPC',
        combat_max_hp: 6,
        combat_ai_profile: 'berserker'
      )
      coward = NpcArchetype.create(
        name: 'Coward NPC',
        combat_max_hp: 6,
        combat_ai_profile: 'coward'
      )

      berserker_power = described_class.calculate_archetype_power(berserker)
      coward_power = described_class.calculate_archetype_power(coward)

      expect(berserker_power).to be > coward_power
    end

    it 'factors in damage bonus' do
      no_bonus = NpcArchetype.create(
        name: 'No Bonus NPC',
        combat_max_hp: 6,
        combat_damage_bonus: 0,
        combat_ai_profile: 'balanced'
      )
      high_bonus = NpcArchetype.create(
        name: 'High Bonus NPC',
        combat_max_hp: 6,
        combat_damage_bonus: 5,
        combat_ai_profile: 'balanced'
      )

      expect(described_class.calculate_archetype_power(high_bonus)).to be >
        described_class.calculate_archetype_power(no_bonus)
    end
  end

  describe '.calculate_ability_power' do
    it 'returns 0 for nil abilities' do
      expect(described_class.calculate_ability_power(nil)).to eq(0.0)
    end

    it 'returns 0 for empty abilities array' do
      expect(described_class.calculate_ability_power([])).to eq(0.0)
    end

    it 'calculates power from ability power attribute' do
      ability = double('Ability', power: 50.0)
      result = described_class.calculate_ability_power([ability])
      expect(result).to be > 0
    end

    it 'applies scaling bonus for multiple abilities' do
      ability1 = double('Ability', power: 50.0)
      ability2 = double('Ability', power: 50.0)

      single_power = described_class.calculate_ability_power([ability1])
      double_power = described_class.calculate_ability_power([ability1, ability2])

      # Multiple abilities get a scaling bonus (1 + log(n) * 0.3)
      # So double_power > single_power * 2
      expect(double_power).to be > single_power
      # The bonus factor for 2 abilities is ~1.208
      expect(double_power).to be_within(5).of(single_power * 2 * 1.208)
    end
  end

  describe '.calculate_pc_power' do
    it 'calculates power for a character' do
      power = described_class.calculate_pc_power(character)
      expect(power).to be_a(Numeric)
      expect(power).to be > 0
    end
  end

  describe '.calculate_pc_group_power' do
    let(:character2) { create(:character, user: user) }

    it 'sums power of multiple characters' do
      ids = [character.id, character2.id]
      group_power = described_class.calculate_pc_group_power(ids)

      single_power = described_class.calculate_pc_power(character)

      expect(group_power).to be > single_power
    end

    it 'returns 0 for empty character list' do
      expect(described_class.calculate_pc_group_power([])).to eq(0)
    end
  end

  describe '.estimate_balanced_composition' do
    let(:boss_archetype) do
      NpcArchetype.create(
        name: 'Boss Monster',
        combat_max_hp: 12,
        combat_damage_bonus: 5,
        combat_ai_profile: 'aggressive'
      )
    end

    let(:minion_archetype) do
      NpcArchetype.create(
        name: 'Minion Monster',
        combat_max_hp: 3,
        combat_damage_bonus: 0,
        combat_ai_profile: 'balanced'
      )
    end

    it 'includes mandatory archetypes in composition' do
      composition = described_class.estimate_balanced_composition(
        pc_power: 200,
        mandatory_archetypes: [boss_archetype],
        optional_archetypes: []
      )

      expect(composition).to have_key(boss_archetype.id)
      expect(composition[boss_archetype.id][:count]).to eq(1)
    end

    it 'fills remaining power budget with optional archetypes' do
      composition = described_class.estimate_balanced_composition(
        pc_power: 500,
        mandatory_archetypes: [boss_archetype],
        optional_archetypes: [minion_archetype]
      )

      # Should have both boss and minions
      expect(composition).to have_key(boss_archetype.id)
      expect(composition).to have_key(minion_archetype.id)
    end

    it 'returns empty composition with no archetypes' do
      composition = described_class.estimate_balanced_composition(
        pc_power: 100,
        mandatory_archetypes: [],
        optional_archetypes: []
      )

      expect(composition).to be_empty
    end

    it 'handles zero-power archetypes without division by zero' do
      zero_power_archetype = NpcArchetype.create(
        name: 'Zero Power NPC',
        combat_max_hp: 0,
        combat_damage_bonus: 0,
        combat_defense_bonus: 0,
        combat_speed_modifier: 0,
        damage_dice_count: 0,
        damage_dice_sides: 0,
        combat_ai_profile: 'balanced'
      )

      allow(described_class).to receive(:calculate_archetype_power).and_call_original
      allow(described_class).to receive(:calculate_archetype_power)
        .with(zero_power_archetype).and_return(0.0)

      expect {
        described_class.estimate_balanced_composition(
          pc_power: 100.0,
          mandatory_archetypes: [],
          optional_archetypes: [zero_power_archetype]
        )
      }.not_to raise_error
    end

    it 'skips zero-power optional archetypes gracefully' do
      zero_power_archetype = NpcArchetype.create(
        name: 'Zero Power Skipped NPC',
        combat_max_hp: 0,
        combat_damage_bonus: 0,
        combat_defense_bonus: 0,
        combat_speed_modifier: 0,
        damage_dice_count: 0,
        damage_dice_sides: 0,
        combat_ai_profile: 'balanced'
      )

      allow(described_class).to receive(:calculate_archetype_power).and_call_original
      allow(described_class).to receive(:calculate_archetype_power)
        .with(zero_power_archetype).and_return(0.0)

      result = described_class.estimate_balanced_composition(
        pc_power: 100.0,
        mandatory_archetypes: [],
        optional_archetypes: [zero_power_archetype, minion_archetype]
      )

      # Zero-power archetype should be skipped, minion should be included if power budget allows
      expect(result).not_to have_key(zero_power_archetype.id)
    end

    it 'handles negative-power archetypes without infinite loop' do
      neg_archetype = NpcArchetype.create(
        name: 'Negative Power NPC',
        combat_max_hp: 1,
        combat_damage_bonus: 0,
        combat_defense_bonus: 0,
        combat_speed_modifier: -5,
        damage_dice_count: 1,
        damage_dice_sides: 4,
        combat_ai_profile: 'balanced'
      )

      allow(described_class).to receive(:calculate_archetype_power).and_call_original
      allow(described_class).to receive(:calculate_archetype_power)
        .with(neg_archetype).and_return(-5.0)

      expect {
        described_class.estimate_balanced_composition(
          pc_power: 100.0,
          mandatory_archetypes: [],
          optional_archetypes: [neg_archetype]
        )
      }.not_to raise_error
    end

    it 'returns empty composition when no remaining budget' do
      result = described_class.estimate_balanced_composition(
        pc_power: 0.0,
        mandatory_archetypes: [],
        optional_archetypes: [minion_archetype]
      )

      expect(result).to be_empty
    end
  end

  describe '.apply_difficulty_modifier' do
    let(:archetype) do
      NpcArchetype.create(
        name: 'Test Modifier NPC',
        combat_max_hp: 6,
        combat_damage_bonus: 2,
        combat_defense_bonus: 2,
        combat_speed_modifier: 0,
        combat_ai_profile: 'balanced'
      )
    end

    it 'increases stats with positive modifier' do
      modified = described_class.apply_difficulty_modifier(archetype, 0.3)

      expect(modified[:damage_bonus]).to be > 2
      expect(modified[:max_hp]).to be > 6
    end

    it 'decreases stats with negative modifier' do
      modified = described_class.apply_difficulty_modifier(archetype, -0.3)

      expect(modified[:damage_bonus]).to be < 2
      expect(modified[:defense_bonus]).to be < 2
    end

    it 'does not go below zero for stats' do
      modified = described_class.apply_difficulty_modifier(archetype, -1.0)

      expect(modified[:damage_bonus]).to be >= 0
      expect(modified[:defense_bonus]).to be >= 0
    end
  end

  describe '.composition_to_participants' do
    let(:archetype) do
      NpcArchetype.create(
        name: 'Goblin Fighter',
        combat_max_hp: 4,
        combat_damage_bonus: 1,
        damage_dice_count: 2,
        damage_dice_sides: 6,
        combat_ai_profile: 'aggressive'
      )
    end

    it 'creates SimParticipant objects from composition' do
      composition = { archetype.id => { count: 2 } }
      participants = described_class.composition_to_participants(composition)

      expect(participants.size).to eq(2)
      expect(participants.first).to be_a(CombatSimulatorService::SimParticipant)
      expect(participants.first.name).to include('Goblin')
      expect(participants.first.is_pc).to be false
    end

    it 'applies stat modifiers if provided' do
      composition = { archetype.id => { count: 1 } }
      participants = described_class.composition_to_participants(
        composition,
        stat_modifiers: { archetype.id => 0.5 }
      )

      # With positive modifier, HP should be higher than base
      expect(participants.first.max_hp).to be > 4
    end

    it 'supports string-keyed composition counts from JSONB' do
      composition = { archetype.id.to_s => { 'count' => 2 } }
      participants = described_class.composition_to_participants(composition)

      expect(participants.size).to eq(2)
    end

    it 'accepts stat modifiers keyed by string archetype ID' do
      composition = { archetype.id.to_s => { 'count' => 1 } }
      participants = described_class.composition_to_participants(
        composition,
        stat_modifiers: { archetype.id.to_s => 0.5 }
      )

      expect(participants.first.max_hp).to be > 4
    end

    it 'handles empty composition' do
      expect(described_class.composition_to_participants({})).to eq([])
    end

    it 'skips invalid archetype IDs' do
      composition = { 99999 => { count: 1 } }
      expect(described_class.composition_to_participants(composition)).to eq([])
    end
  end

  describe '.pcs_to_participants' do
    it 'converts characters to SimParticipant objects' do
      participants = described_class.pcs_to_participants([character.id])

      expect(participants.size).to eq(1)
      expect(participants.first).to be_a(CombatSimulatorService::SimParticipant)
      expect(participants.first.is_pc).to be true
      expect(participants.first.name).to eq(character.full_name)
    end

    it 'returns empty array for no characters' do
      expect(described_class.pcs_to_participants([])).to eq([])
    end

    it 'uses 2d8 dice for PCs' do
      participants = described_class.pcs_to_participants([character.id])

      expect(participants.first.damage_dice_count).to eq(2)
      expect(participants.first.damage_dice_sides).to eq(8)
    end
  end

  describe '.format_analysis' do
    it 'formats power analysis as string' do
      composition = { 1 => { count: 2, power: 50.0 } }
      output = described_class.format_analysis(pc_power: 100.0, composition: composition)

      expect(output).to include('Power Analysis')
      expect(output).to include('PC Power: 100.0')
      expect(output).to include('NPC Power: 100.0')
    end
  end

  describe 'constants' do
    it 'has WEIGHTS defined' do
      expect(described_class::WEIGHTS).to be_a(Hash)
      expect(described_class::WEIGHTS[:hp]).to be > 0
    end

    it 'has BALANCED_POWER_RATIO defined' do
      expect(described_class::BALANCED_POWER_RATIO).to be_between(0.5, 1.5)
    end
  end
end
