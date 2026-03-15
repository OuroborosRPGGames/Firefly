# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CombatWoundDescriptionService do
  subject(:service) { described_class.new }

  describe '#describe_wound' do
    context 'with slashing damage' do
      it 'returns light wound for 1 HP lost' do
        wound = service.describe_wound(hp_lost: 1, damage_type: 'slashing')
        expect(['a shallow cut', 'a nick', 'a scratch', 'a light slash']).to include(wound)
      end

      it 'returns moderate wound for 2 HP lost' do
        wound = service.describe_wound(hp_lost: 2, damage_type: 'slashing')
        expect(['a bleeding cut', 'a nasty gash', 'a painful slash', 'a deep nick']).to include(wound)
      end

      it 'returns serious wound for 3 HP lost' do
        wound = service.describe_wound(hp_lost: 3, damage_type: 'slashing')
        expect(['a deep gash', 'a bleeding wound', 'a vicious slash', 'a grievous cut']).to include(wound)
      end

      it 'returns critical wound for 4+ HP lost' do
        wound = service.describe_wound(hp_lost: 4, damage_type: 'slashing')
        expect(['a devastating slash', 'a horrific wound', 'a mortal gash', 'a near-fatal cut']).to include(wound)
      end
    end

    context 'with piercing damage' do
      it 'returns serious wound for 3 HP lost' do
        wound = service.describe_wound(hp_lost: 3, damage_type: 'piercing')
        expect(['a deep puncture', 'a grievous stab', 'an impaling strike', 'a vicious thrust']).to include(wound)
      end
    end

    context 'with bludgeoning damage' do
      it 'returns light wound for 1 HP lost' do
        wound = service.describe_wound(hp_lost: 1, damage_type: 'bludgeoning')
        expect(['a battering', 'a light bruise', 'a glancing blow', 'a stinging impact']).to include(wound)
      end

      it 'returns moderate wound for 2 HP lost' do
        wound = service.describe_wound(hp_lost: 2, damage_type: 'bludgeoning')
        expect(['bruising', 'a painful bruise', 'a solid hit', 'a jarring blow']).to include(wound)
      end

      it 'returns serious wound for 3 HP lost' do
        wound = service.describe_wound(hp_lost: 3, damage_type: 'bludgeoning')
        expect(['severe bruises', 'cracked bones', 'a brutal impact', 'a savage strike']).to include(wound)
      end

      it 'returns critical wound for 4+ HP lost' do
        wound = service.describe_wound(hp_lost: 4, damage_type: 'bludgeoning')
        expect(['broken bones', 'a shattering blow', 'a bone-crushing impact', 'a devastating strike']).to include(wound)
      end
    end

    context 'with fire damage' do
      it 'returns serious wound for 3 HP lost' do
        wound = service.describe_wound(hp_lost: 3, damage_type: 'fire')
        expect(['severe burns', 'charred flesh', 'searing agony', 'deep burns']).to include(wound)
      end
    end

    context 'with cold damage' do
      it 'returns light wound for 1 HP lost' do
        wound = service.describe_wound(hp_lost: 1, damage_type: 'cold')
        expect(['mild frostbite', 'chilled skin', 'numbing cold', 'light frost damage']).to include(wound)
      end
    end

    context 'with lightning damage' do
      it 'returns critical wound for 4+ HP lost' do
        wound = service.describe_wound(hp_lost: 4, damage_type: 'lightning')
        expect(['catastrophic electrocution', 'charred nerves', 'cardiac strain', 'devastating shock']).to include(wound)
      end
    end

    context 'with unknown damage type' do
      it 'returns generic moderate wound for 2 HP lost' do
        wound = service.describe_wound(hp_lost: 2, damage_type: 'cosmic')
        expect(['a wound', 'solid damage', 'a good hit', 'a painful injury']).to include(wound)
      end
    end

    context 'with nil damage type' do
      it 'returns generic moderate wound for 2 HP lost' do
        wound = service.describe_wound(hp_lost: 2, damage_type: nil)
        expect(['a wound', 'solid damage', 'a good hit', 'a painful injury']).to include(wound)
      end
    end

    context 'with symbol damage type' do
      it 'normalizes to symbol and returns correct strings' do
        wound = service.describe_wound(hp_lost: 1, damage_type: :slashing)
        expect(['a shallow cut', 'a nick', 'a scratch', 'a light slash']).to include(wound)
      end
    end
  end

  describe '#severity_for' do
    it 'returns :light for 0-1 HP lost' do
      expect(service.severity_for(0)).to eq(:light)
      expect(service.severity_for(1)).to eq(:light)
    end

    it 'returns :moderate for 2 HP lost' do
      expect(service.severity_for(2)).to eq(:moderate)
    end

    it 'returns :serious for 3 HP lost' do
      expect(service.severity_for(3)).to eq(:serious)
    end

    it 'returns :critical for 4+ HP lost' do
      expect(service.severity_for(4)).to eq(:critical)
      expect(service.severity_for(100)).to eq(:critical)
    end
  end

  describe '.damage_types' do
    it 'returns all non-generic damage types' do
      types = described_class.damage_types
      expect(types).to include(:slashing, :piercing, :bludgeoning, :fire, :cold, :lightning)
      expect(types).not_to include(:generic)
    end
  end

  describe '.physical_damage_types' do
    it 'returns physical damage types' do
      expect(described_class.physical_damage_types).to eq(%i[slashing piercing bludgeoning])
    end
  end

  describe '.elemental_damage_types' do
    it 'returns elemental damage types' do
      expect(described_class.elemental_damage_types).to eq(%i[fire cold lightning acid poison])
    end
  end
end
