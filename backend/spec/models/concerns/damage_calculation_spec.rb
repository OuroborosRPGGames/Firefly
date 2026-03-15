# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DamageCalculation do
  describe '.calculate_damage_thresholds' do
    context 'with no wound penalty' do
      let(:thresholds) { described_class.calculate_damage_thresholds(0) }

      it 'returns base thresholds from config' do
        expect(thresholds[:miss]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:miss])
        expect(thresholds[:one_hp]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:one_hp])
        expect(thresholds[:two_hp]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:two_hp])
        expect(thresholds[:three_hp]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:three_hp])
      end

      it 'returns expected base values' do
        # Based on CLAUDE.md documentation:
        # 0-9 = miss, 10-17 = 1HP, 18-29 = 2HP, 30-99 = 3HP
        expect(thresholds[:miss]).to eq(9)
        expect(thresholds[:one_hp]).to eq(17)
        expect(thresholds[:two_hp]).to eq(29)
        expect(thresholds[:three_hp]).to eq(99)
      end
    end

    context 'with wound penalty' do
      it 'shifts all thresholds down by wound penalty' do
        wound_penalty = 2
        thresholds = described_class.calculate_damage_thresholds(wound_penalty)

        expect(thresholds[:miss]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:miss] - wound_penalty)
        expect(thresholds[:one_hp]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:one_hp] - wound_penalty)
        expect(thresholds[:two_hp]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:two_hp] - wound_penalty)
        expect(thresholds[:three_hp]).to eq(GameConfig::Mechanics::DAMAGE_THRESHOLDS[:three_hp] - wound_penalty)
      end

      it 'allows thresholds to go negative' do
        # Heavy wound penalty can push thresholds negative
        wound_penalty = 15
        thresholds = described_class.calculate_damage_thresholds(wound_penalty)

        expect(thresholds[:miss]).to eq(9 - 15) # -6
        expect(thresholds[:miss]).to be < 0
      end
    end
  end

  describe '.calculate_hp_from_raw_damage' do
    context 'at full health (no wound penalty)' do
      let(:wound_penalty) { 0 }

      it 'returns 0 HP for damage at or below miss threshold' do
        expect(described_class.calculate_hp_from_raw_damage(0, wound_penalty)).to eq(0)
        expect(described_class.calculate_hp_from_raw_damage(5, wound_penalty)).to eq(0)
        expect(described_class.calculate_hp_from_raw_damage(9, wound_penalty)).to eq(0)
      end

      it 'returns 1 HP for damage in first tier' do
        expect(described_class.calculate_hp_from_raw_damage(10, wound_penalty)).to eq(1)
        expect(described_class.calculate_hp_from_raw_damage(15, wound_penalty)).to eq(1)
        expect(described_class.calculate_hp_from_raw_damage(17, wound_penalty)).to eq(1)
      end

      it 'returns 2 HP for damage in second tier' do
        expect(described_class.calculate_hp_from_raw_damage(18, wound_penalty)).to eq(2)
        expect(described_class.calculate_hp_from_raw_damage(25, wound_penalty)).to eq(2)
        expect(described_class.calculate_hp_from_raw_damage(29, wound_penalty)).to eq(2)
      end

      it 'returns 3 HP for damage in third tier' do
        expect(described_class.calculate_hp_from_raw_damage(30, wound_penalty)).to eq(3)
        expect(described_class.calculate_hp_from_raw_damage(50, wound_penalty)).to eq(3)
        expect(described_class.calculate_hp_from_raw_damage(99, wound_penalty)).to eq(3)
      end

      it 'returns 4 HP for damage at high damage start' do
        expect(described_class.calculate_hp_from_raw_damage(100, wound_penalty)).to eq(4)
        expect(described_class.calculate_hp_from_raw_damage(150, wound_penalty)).to eq(4)
        expect(described_class.calculate_hp_from_raw_damage(199, wound_penalty)).to eq(4)
      end

      it 'returns 5 HP for damage in second high band' do
        expect(described_class.calculate_hp_from_raw_damage(200, wound_penalty)).to eq(5)
        expect(described_class.calculate_hp_from_raw_damage(250, wound_penalty)).to eq(5)
        expect(described_class.calculate_hp_from_raw_damage(299, wound_penalty)).to eq(5)
      end

      it 'returns 6+ HP for very high damage' do
        expect(described_class.calculate_hp_from_raw_damage(300, wound_penalty)).to eq(6)
        expect(described_class.calculate_hp_from_raw_damage(400, wound_penalty)).to eq(7)
        expect(described_class.calculate_hp_from_raw_damage(500, wound_penalty)).to eq(8)
      end
    end

    context 'with wound penalty' do
      it 'lowers effective thresholds, increasing damage taken' do
        # With wound penalty of 2:
        # - miss threshold: 7 (was 9)
        # - 1HP threshold: 15 (was 17)
        wound_penalty = 2

        # 8 damage is now 1 HP (was miss at full health)
        expect(described_class.calculate_hp_from_raw_damage(8, wound_penalty)).to eq(1)

        # 16 damage is now 2 HP (was 1 HP at full health)
        expect(described_class.calculate_hp_from_raw_damage(16, wound_penalty)).to eq(2)
      end

      it 'demonstrates increased vulnerability when wounded' do
        # Same 15 damage at different wound levels
        expect(described_class.calculate_hp_from_raw_damage(15, 0)).to eq(1)  # Full health
        expect(described_class.calculate_hp_from_raw_damage(15, 2)).to eq(1)  # 2 HP lost
        expect(described_class.calculate_hp_from_raw_damage(15, 6)).to eq(2)  # 6 HP lost (threshold at 11)
      end
    end

    context 'edge cases' do
      it 'handles zero damage' do
        expect(described_class.calculate_hp_from_raw_damage(0, 0)).to eq(0)
        expect(described_class.calculate_hp_from_raw_damage(0, 5)).to eq(0)
      end

      it 'handles negative damage as zero' do
        # Negative damage shouldn't happen but should be handled gracefully
        expect(described_class.calculate_hp_from_raw_damage(-10, 0)).to eq(0)
      end

      it 'handles extreme wound penalty' do
        # Wound penalty that pushes all thresholds negative
        wound_penalty = 20
        # Even minimal damage should cause HP loss (thresholds become -11, -3, 9, 79)
        # 1 damage > -11 miss threshold, <= -3 one_hp threshold = 1 HP
        # Actually at this wound penalty, thresholds are: miss=-11, 1hp=-3, 2hp=9, 3hp=79
        # 1 > -11 and 1 <= -3 is false, 1 <= 9 is true, so 2 HP
        expect(described_class.calculate_hp_from_raw_damage(1, wound_penalty)).to eq(2)
      end
    end
  end

  describe 'instance methods when included' do
    let(:test_class) do
      Class.new do
        include DamageCalculation

        attr_accessor :max_hp, :current_hp

        def initialize(max_hp:, current_hp:)
          @max_hp = max_hp
          @current_hp = current_hp
        end
      end
    end

    let(:full_health_instance) { test_class.new(max_hp: 6, current_hp: 6) }
    let(:wounded_instance) { test_class.new(max_hp: 6, current_hp: 4) }

    describe '#wound_penalty_for_damage' do
      it 'returns 0 for full health' do
        expect(full_health_instance.wound_penalty_for_damage).to eq(0)
      end

      it 'returns HP lost for wounded character' do
        expect(wounded_instance.wound_penalty_for_damage).to eq(2)
      end
    end

    describe '#damage_thresholds' do
      it 'returns base thresholds for full health' do
        thresholds = full_health_instance.damage_thresholds
        expect(thresholds[:miss]).to eq(9)
      end

      it 'returns adjusted thresholds for wounded character' do
        thresholds = wounded_instance.damage_thresholds
        expect(thresholds[:miss]).to eq(7) # 9 - 2 wound penalty
      end
    end

    describe '#calculate_hp_from_damage' do
      it 'uses current wound penalty automatically' do
        # Full health: 15 damage = 1 HP
        expect(full_health_instance.calculate_hp_from_damage(15)).to eq(1)

        # Wounded (2 HP lost): 15 damage still = 1 HP (threshold at 15)
        expect(wounded_instance.calculate_hp_from_damage(15)).to eq(1)

        # Wounded (2 HP lost): 8 damage = 1 HP (was miss at full health)
        expect(wounded_instance.calculate_hp_from_damage(8)).to eq(1)
      end
    end
  end

  describe 'integration with FightParticipant' do
    let(:character) { create(:character) }
    let(:room) { create(:room) }
    let(:character_instance) { create(:character_instance, character: character, current_room: room) }
    let(:fight) { create(:fight, room: room) }
    let(:participant) do
      create(:fight_participant,
             fight: fight,
             character_instance: character_instance,
             current_hp: 6,
             max_hp: 6)
    end

    it 'includes DamageCalculation methods' do
      expect(participant).to respond_to(:damage_thresholds)
      expect(participant).to respond_to(:calculate_hp_from_damage)
    end

    it 'calculates thresholds based on current HP' do
      # Full health participant
      expect(participant.damage_thresholds[:miss]).to eq(9)

      # Wound the participant
      participant.update(current_hp: 4)
      expect(participant.damage_thresholds[:miss]).to eq(7)
    end
  end
end
