# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Generators::AbilityGeneratorService do
  describe 'constants' do
    it 'defines ABILITY_MODEL' do
      expect(described_class::ABILITY_MODEL).to include(:provider, :model)
    end

    it 'defines ROLE_ABILITY_COUNTS' do
      expect(described_class::ROLE_ABILITY_COUNTS[:boss]).to eq(2..3)
      expect(described_class::ROLE_ABILITY_COUNTS[:lieutenant]).to eq(1..2)
      expect(described_class::ROLE_ABILITY_COUNTS[:minion]).to eq(0..1)
    end

    it 'defines TARGET_POWER for roles' do
      expect(described_class::TARGET_POWER[:boss]).to eq(150)
      expect(described_class::TARGET_POWER[:lieutenant]).to eq(100)
      expect(described_class::TARGET_POWER[:minion]).to eq(60)
    end

    it 'defines MATCH_THRESHOLD' do
      expect(described_class::MATCH_THRESHOLD).to eq(50)
    end

    it 'defines ELEMENT_KEYWORDS' do
      expect(described_class::ELEMENT_KEYWORDS.keys).to include('fire', 'ice', 'lightning', 'poison', 'shadow', 'holy', 'arcane')
    end
  end

  describe '.assign_abilities' do
    let(:archetype) { double('NpcArchetype', id: 1, name: 'Fire Dragon') }

    before do
      # Mock search to return no matches by default
      allow(described_class).to receive(:search_existing_abilities).and_return([])
      # Mock generate to return success
      ability = double('Ability', id: 100)
      allow(described_class).to receive(:generate_new_ability).and_return({ success: true, ability: ability })
    end

    it 'returns empty result when count is 0 (minion with low roll)' do
      # Force count to be 0 by stubbing rand to return the minimum of the range
      allow(described_class).to receive(:rand).with(0..1).and_return(0)

      result = described_class.assign_abilities(
        archetype: archetype,
        role: :minion,
        description: 'Small goblin',
        difficulty: :easy
      )

      expect(result[:success]).to be true
      expect(result[:ability_ids]).to be_empty
    end

    context 'with existing abilities that match' do
      let(:existing_ability) { double('Ability', id: 50) }

      before do
        allow(described_class).to receive(:search_existing_abilities).and_return([
          { ability: existing_ability, score: 75 }
        ])
      end

      it 'selects existing abilities when score >= threshold' do
        # Force count to be 1 for lieutenant
        allow(described_class).to receive(:rand).with(1..2).and_return(1)

        result = described_class.assign_abilities(
          archetype: archetype,
          role: :lieutenant,
          description: 'Fire mage',
          difficulty: :normal
        )

        expect(result[:selected_count]).to eq(1)
        expect(result[:ability_ids]).to include(50)
      end
    end

    context 'with no matching abilities' do
      it 'generates new abilities' do
        # Force count to be 1 for lieutenant
        allow(described_class).to receive(:rand).with(1..2).and_return(1)

        result = described_class.assign_abilities(
          archetype: archetype,
          role: :lieutenant,
          description: 'Unique creature',
          difficulty: :normal
        )

        expect(result[:generated_count]).to eq(1)
        expect(result[:ability_ids]).to include(100)
      end
    end

    context 'when generation fails' do
      before do
        allow(described_class).to receive(:generate_new_ability).and_return({
          success: false,
          ability: nil,
          error: 'LLM error'
        })
      end

      it 'records errors' do
        # Force count to be 1 for lieutenant
        allow(described_class).to receive(:rand).with(1..2).and_return(1)

        result = described_class.assign_abilities(
          archetype: archetype,
          role: :lieutenant,
          description: 'Test',
          difficulty: :normal
        )

        expect(result[:errors]).to include('LLM error')
      end
    end
  end

  describe '.search_existing_abilities' do
    let!(:fire_ability) do
      Ability.create(
        name: 'Flame Burst',
        description: 'Shoots flames',
        ability_type: 'combat',
        user_type: 'npc',
        damage_type: 'fire',
        aoe_shape: 'cone'
      )
    end

    let!(:ice_ability) do
      Ability.create(
        name: 'Ice Shard',
        description: 'Frozen spike',
        ability_type: 'combat',
        user_type: 'npc',
        damage_type: 'ice',
        aoe_shape: 'single'
      )
    end

    it 'returns empty array when no NPC abilities exist' do
      Ability.where(user_type: 'npc').delete

      result = described_class.search_existing_abilities(
        description: 'fire dragon',
        role: :boss,
        target_power: 150
      )

      expect(result).to be_empty
    end

    it 'scores abilities matching detected elements higher' do
      result = described_class.search_existing_abilities(
        description: 'A fierce fire breathing dragon',
        role: :boss,
        target_power: 150
      )

      # Fire ability should score higher for fire description
      fire_match = result.find { |r| r[:ability].id == fire_ability.id }
      ice_match = result.find { |r| r[:ability].id == ice_ability.id }

      expect(fire_match[:score]).to be > ice_match[:score]
    end

    it 'returns abilities sorted by score descending' do
      result = described_class.search_existing_abilities(
        description: 'fire',
        role: :boss,
        target_power: 150
      )

      scores = result.map { |r| r[:score] }
      expect(scores).to eq(scores.sort.reverse)
    end
  end

  describe '.generate_new_ability' do
    let(:llm_response) do
      {
        success: true,
        text: {
          name: 'Dragon Breath',
          description: 'Breathes fire in a cone',
          ability_type: 'combat',
          action_type: 'main',
          target_type: 'enemy',
          aoe_shape: 'cone',
          aoe_radius: 0,
          aoe_length: 4,
          base_damage_dice: '4d8',
          damage_type: 'fire',
          damage_modifier: 5,
          activation_segment: 50,
          cooldown_seconds: 20
        }.to_json
      }
    end

    before do
      allow(LLM::Client).to receive(:generate).and_return(llm_response)
    end

    it 'calls LLM with formatted prompt' do
      expect(LLM::Client).to receive(:generate).with(
        hash_including(
          prompt: a_string_matching(/Fire Dragon/),
          json_mode: true
        )
      )

      described_class.generate_new_ability(
        name: 'Fire Dragon',
        description: 'Ancient fire breathing dragon',
        role: :boss,
        target_power: 150
      )
    end

    it 'creates ability from LLM response' do
      result = described_class.generate_new_ability(
        name: 'Fire Dragon',
        description: 'Ancient fire breathing dragon',
        role: :boss,
        target_power: 150
      )

      expect(result[:success]).to be true
      expect(result[:ability]).to be_a(Ability)
      expect(result[:ability].name).to eq('Dragon Breath')
      expect(result[:ability].damage_type).to eq('fire')
    end

    context 'when LLM fails' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({ success: false, error: 'API error' })
      end

      it 'creates fallback ability' do
        result = described_class.generate_new_ability(
          name: 'Fire Dragon',
          description: 'fire breathing dragon',
          role: :boss,
          target_power: 150
        )

        expect(result[:success]).to be true
        expect(result[:ability].name).to include('Strike')
        expect(result[:ability].damage_type).to eq('fire') # Detected from description
      end
    end

    context 'when LLM returns invalid JSON' do
      before do
        allow(LLM::Client).to receive(:generate).and_return({ success: true, text: 'not json' })
      end

      it 'creates fallback ability' do
        # Use 'frozen beast' instead of 'ice dragon' because 'dragon' matches fire keywords
        result = described_class.generate_new_ability(
          name: 'Frost Giant',
          description: 'frozen arctic beast',
          role: :lieutenant,
          target_power: 100
        )

        expect(result[:success]).to be true
        expect(result[:ability].damage_type).to eq('ice')
      end
    end
  end

  describe '.balance_ability' do
    let(:ability) do
      Ability.create(
        name: 'Test Ability',
        description: 'Test',
        ability_type: 'combat',
        user_type: 'npc',
        damage_type: 'physical',
        damage_modifier: 5,
        base_damage_dice: '2d6'
      )
    end

    it 'returns ability unchanged if power is 0' do
      allow(ability).to receive(:power).and_return(0)

      result = described_class.balance_ability(ability, 100)
      expect(result).to eq(ability)
    end

    it 'returns ability unchanged if within 25% of target' do
      allow(ability).to receive(:power).and_return(110)
      expect(ability).not_to receive(:update)

      result = described_class.balance_ability(ability, 100)
      expect(result).to eq(ability)
    end

    it 'adjusts moderately over-target abilities (no dead zone above tolerance)' do
      allow(ability).to receive(:power).and_return(130)

      expect(ability).to receive(:update).with(hash_including(:damage_modifier))

      described_class.balance_ability(ability, 100)
    end

    it 'adjusts moderately under-target abilities (no dead zone below tolerance)' do
      allow(ability).to receive(:power).and_return(70)

      expect(ability).to receive(:update).with(hash_including(:damage_modifier))

      described_class.balance_ability(ability, 100)
    end

    it 'reduces damage_modifier when too powerful' do
      allow(ability).to receive(:power).and_return(200)

      expect(ability).to receive(:update).with(hash_including(:damage_modifier))

      described_class.balance_ability(ability, 100)
    end

    it 'increases damage_modifier when too weak' do
      allow(ability).to receive(:power).and_return(30)

      expect(ability).to receive(:update).with(hash_including(:damage_modifier))

      described_class.balance_ability(ability, 100)
    end
  end

  describe 'private methods' do
    describe '#detect_elements' do
      it 'detects fire element' do
        result = described_class.send(:detect_elements, 'a fiery dragon with blazing breath')
        expect(result).to include('fire')
      end

      it 'detects ice element' do
        result = described_class.send(:detect_elements, 'frozen tundra beast with icy claws')
        expect(result).to include('ice')
      end

      it 'detects multiple elements' do
        result = described_class.send(:detect_elements, 'a phoenix wreathed in fire and lightning')
        expect(result).to include('fire', 'lightning')
      end

      it 'returns empty array when no elements detected' do
        result = described_class.send(:detect_elements, 'a plain warrior')
        expect(result).to be_empty
      end
    end

    describe '#calculate_match_score' do
      let(:ability) do
        double('Ability',
          name: 'Fire Blast',
          description: 'Shoots fire',
          damage_type: 'fire',
          power: 100,
          aoe_shape: 'cone',
          respond_to?: false
        )
      end

      it 'adds 30 points for element match' do
        score = described_class.send(:calculate_match_score,
          ability: ability,
          description: 'fire dragon',
          detected_elements: ['fire'],
          target_power: 100,
          role: :boss
        )

        expect(score).to be >= 30
      end

      it 'adds points for power proximity' do
        score_close = described_class.send(:calculate_match_score,
          ability: ability,
          description: 'creature',
          detected_elements: [],
          target_power: 100,
          role: :boss
        )

        score_far = described_class.send(:calculate_match_score,
          ability: double('Ability', name: 'X', description: '', damage_type: 'physical', power: 300, aoe_shape: 'single', respond_to?: false),
          description: 'creature',
          detected_elements: [],
          target_power: 100,
          role: :boss
        )

        expect(score_close).to be > score_far
      end

      it 'adds points for AoE match by role' do
        # Boss prefers AoE abilities
        score_aoe = described_class.send(:calculate_match_score,
          ability: double('Ability', name: 'X', description: '', damage_type: 'fire', power: 100, aoe_shape: 'cone', respond_to?: false),
          description: 'dragon',
          detected_elements: [],
          target_power: 100,
          role: :boss
        )

        score_single = described_class.send(:calculate_match_score,
          ability: double('Ability', name: 'X', description: '', damage_type: 'fire', power: 100, aoe_shape: 'single', respond_to?: false),
          description: 'dragon',
          detected_elements: [],
          target_power: 100,
          role: :boss
        )

        expect(score_aoe).to be > score_single
      end
    end

    describe '#valid_ability_data?' do
      it 'returns true for valid data' do
        result = described_class.send(:valid_ability_data?, { 'name' => 'Fire Blast' })
        expect(result).to be true
      end

      it 'returns false for missing name' do
        result = described_class.send(:valid_ability_data?, {})
        expect(result).to be false
      end

      it 'returns false for empty name' do
        result = described_class.send(:valid_ability_data?, { 'name' => '' })
        expect(result).to be false
      end
    end

    describe '#create_ability_from_data' do
      let(:data) do
        {
          'name' => 'Dragon Breath',
          'description' => 'Breathes fire',
          'ability_type' => 'combat',
          'action_type' => 'main',
          'target_type' => 'enemy',
          'aoe_shape' => 'cone',
          'aoe_radius' => 0,
          'aoe_length' => 4,
          'base_damage_dice' => '4d8',
          'damage_type' => 'fire',
          'damage_modifier' => 5,
          'activation_segment' => 50,
          'cooldown_seconds' => 20
        }
      end

      it 'creates ability with correct attributes' do
        ability = described_class.send(:create_ability_from_data, data)

        expect(ability).to be_a(Ability)
        expect(ability.name).to eq('Dragon Breath')
        expect(ability.aoe_shape).to eq('cone')
        expect(ability.damage_type).to eq('fire')
        expect(ability.user_type).to eq('npc')
      end

      it 'uses default values for missing fields' do
        minimal_data = { 'name' => 'Basic Attack', 'base_damage_dice' => '1d6' }
        ability = described_class.send(:create_ability_from_data, minimal_data)

        expect(ability.ability_type).to eq('combat')
        expect(ability.aoe_shape).to eq('single')
        expect(ability.damage_type).to eq('physical')
      end
    end

    describe '#create_fallback_ability' do
      it 'creates ability with boss settings' do
        result = described_class.send(:create_fallback_ability, 'Dragon', 'fire dragon', :boss, 150)

        expect(result[:success]).to be true
        expect(result[:ability].base_damage_dice).to eq('4d8')
        expect(result[:ability].aoe_shape).to eq('cone')
        expect(result[:ability].damage_type).to eq('fire')
      end

      it 'creates ability with lieutenant settings' do
        result = described_class.send(:create_fallback_ability, 'Knight', 'shadow knight', :lieutenant, 100)

        expect(result[:success]).to be true
        expect(result[:ability].base_damage_dice).to eq('3d6')
        expect(result[:ability].damage_type).to eq('shadow')
      end

      it 'creates ability with minion settings' do
        result = described_class.send(:create_fallback_ability, 'Goblin', 'small goblin', :minion, 60)

        expect(result[:success]).to be true
        expect(result[:ability].base_damage_dice).to eq('2d6')
        expect(result[:ability].aoe_shape).to eq('single')
      end

      it 'uses physical damage when no element detected' do
        result = described_class.send(:create_fallback_ability, 'Warrior', 'a warrior', :minion, 60)

        expect(result[:ability].damage_type).to eq('physical')
      end
    end
  end
end
