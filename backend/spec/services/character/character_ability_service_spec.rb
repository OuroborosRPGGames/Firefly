# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CharacterAbilityService do
  let(:universe) { create(:universe) }
  let(:character_instance) { create(:character_instance) }
  let(:ability) { create(:ability, universe: universe) }
  let(:service) { described_class.new(character_instance) }

  describe '#assign' do
    it 'assigns an ability to the character' do
      result = service.assign(ability)

      expect(result).to be_a(CharacterAbility)
      expect(result.character_instance_id).to eq(character_instance.id)
      expect(result.ability_id).to eq(ability.id)
      expect(result.proficiency_level).to eq(1)
      expect(result.learned_at).not_to be_nil
    end

    it 'accepts ability ID instead of object' do
      result = service.assign(ability.id)

      expect(result).to be_a(CharacterAbility)
      expect(result.ability_id).to eq(ability.id)
    end

    it 'sets custom proficiency level' do
      result = service.assign(ability, proficiency_level: 5)

      expect(result.proficiency_level).to eq(5)
    end

    it 'returns existing record if already assigned' do
      first_result = service.assign(ability)
      second_result = service.assign(ability)

      expect(second_result.id).to eq(first_result.id)
      expect(CharacterAbility.where(character_instance_id: character_instance.id).count).to eq(1)
    end

    it 'returns nil for invalid ability' do
      result = service.assign(nil)

      expect(result).to be_nil
    end
  end

  describe '#unassign' do
    it 'removes an assigned ability' do
      service.assign(ability)

      result = service.unassign(ability)

      expect(result).to be true
      expect(service.has_ability?(ability)).to be false
    end

    it 'returns false if ability not assigned' do
      result = service.unassign(ability)

      expect(result).to be false
    end

    it 'accepts ability ID instead of object' do
      service.assign(ability)

      result = service.unassign(ability.id)

      expect(result).to be true
    end
  end

  describe '#has_ability?' do
    it 'returns true if character has the ability' do
      service.assign(ability)

      expect(service.has_ability?(ability)).to be true
    end

    it 'returns false if character does not have the ability' do
      expect(service.has_ability?(ability)).to be false
    end

    it 'accepts ability ID instead of object' do
      service.assign(ability)

      expect(service.has_ability?(ability.id)).to be true
    end
  end

  describe '#abilities' do
    it 'returns all abilities for the character' do
      ability2 = create(:ability, universe: universe)
      service.assign(ability)
      service.assign(ability2)

      result = service.abilities

      expect(result).to contain_exactly(ability, ability2)
    end

    it 'returns empty array if no abilities assigned' do
      expect(service.abilities).to eq([])
    end
  end

  describe '#character_abilities' do
    it 'returns CharacterAbility records' do
      service.assign(ability, proficiency_level: 3)

      result = service.character_abilities

      expect(result.first).to be_a(CharacterAbility)
      expect(result.first.proficiency_level).to eq(3)
    end
  end

  describe '#get' do
    it 'returns the CharacterAbility record for an ability' do
      service.assign(ability, proficiency_level: 7)

      result = service.get(ability)

      expect(result).to be_a(CharacterAbility)
      expect(result.proficiency_level).to eq(7)
    end

    it 'returns nil if ability not assigned' do
      expect(service.get(ability)).to be_nil
    end
  end

  describe '#assign_all' do
    it 'assigns multiple abilities at once' do
      ability2 = create(:ability, universe: universe)
      ability3 = create(:ability, universe: universe)

      results = service.assign_all([ability, ability2, ability3])

      expect(results.length).to eq(3)
      expect(service.abilities).to contain_exactly(ability, ability2, ability3)
    end

    it 'sets proficiency level for all' do
      ability2 = create(:ability, universe: universe)

      service.assign_all([ability, ability2], proficiency_level: 4)

      expect(service.get(ability).proficiency_level).to eq(4)
      expect(service.get(ability2).proficiency_level).to eq(4)
    end
  end

  describe '#clear_all' do
    it 'removes all abilities' do
      ability2 = create(:ability, universe: universe)
      service.assign(ability)
      service.assign(ability2)

      count = service.clear_all

      expect(count).to eq(2)
      expect(service.abilities).to eq([])
    end

    it 'returns 0 if no abilities to clear' do
      expect(service.clear_all).to eq(0)
    end
  end

  describe '#abilities_by_type' do
    it 'filters abilities by type' do
      combat_ability = create(:ability, universe: universe, ability_type: 'combat')
      utility_ability = create(:ability, universe: universe, ability_type: 'utility')
      service.assign(combat_ability)
      service.assign(utility_ability)

      result = service.abilities_by_type('combat')

      expect(result).to contain_exactly(combat_ability)
    end
  end

  describe '#usable_abilities' do
    it 'returns abilities not on cooldown' do
      service.assign(ability)
      char_ability = service.get(ability)

      # By default, abilities should be usable (no cooldown triggered)
      expect(service.usable_abilities).to include(char_ability)
    end
  end
end
