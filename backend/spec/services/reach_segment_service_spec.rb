# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ReachSegmentService do
  describe '.calculate_segment_range' do
    context 'with equal reach' do
      it 'returns full segment range for equal reach' do
        result = described_class.calculate_segment_range(
          attacker_reach: 3,
          defender_reach: 3,
          is_adjacent: false
        )
        expect(result).to eq({ start: 1, end: 100 })
      end

      it 'returns full range regardless of adjacency when reach is equal' do
        result = described_class.calculate_segment_range(
          attacker_reach: 2,
          defender_reach: 2,
          is_adjacent: true
        )
        expect(result).to eq({ start: 1, end: 100 })
      end
    end

    context 'non-adjacent start (longer weapon advantage)' do
      it 'gives frontloaded segments to longer weapon' do
        result = described_class.calculate_segment_range(
          attacker_reach: 5,
          defender_reach: 2,
          is_adjacent: false
        )
        expect(result[:start]).to eq(1)
        expect(result[:end]).to eq(66)
      end

      it 'gives backloaded segments to shorter weapon' do
        result = described_class.calculate_segment_range(
          attacker_reach: 2,
          defender_reach: 5,
          is_adjacent: false
        )
        expect(result[:start]).to eq(34)
        expect(result[:end]).to eq(100)
      end
    end

    context 'adjacent start (shorter weapon advantage)' do
      it 'gives frontloaded segments to shorter weapon' do
        result = described_class.calculate_segment_range(
          attacker_reach: 1,
          defender_reach: 5,
          is_adjacent: true
        )
        expect(result[:start]).to eq(1)
        expect(result[:end]).to eq(66)
      end

      it 'gives backloaded segments to longer weapon' do
        result = described_class.calculate_segment_range(
          attacker_reach: 5,
          defender_reach: 1,
          is_adjacent: true
        )
        expect(result[:start]).to eq(34)
        expect(result[:end]).to eq(100)
      end
    end
  end

  describe '.compress_segments' do
    it 'returns unchanged segments for full range' do
      base = [20, 40, 60, 80, 100]
      result = described_class.compress_segments(base, { start: 1, end: 100 })
      expect(result).to eq(base)
    end

    it 'compresses segments into frontloaded range (1-66)' do
      base = [20, 40, 60, 80, 100]
      result = described_class.compress_segments(base, { start: 1, end: 66 })

      # All should be within 1-66
      expect(result.all? { |s| s >= 1 && s <= 66 }).to be true
      expect(result).to eq(result.sort)
    end

    it 'compresses segments into backloaded range (34-100)' do
      base = [20, 40, 60, 80, 100]
      result = described_class.compress_segments(base, { start: 34, end: 100 })

      # All should be within 34-100
      expect(result.all? { |s| s >= 34 && s <= 100 }).to be true
      expect(result).to eq(result.sort)
    end

    it 'handles empty segment array' do
      result = described_class.compress_segments([], { start: 1, end: 66 })
      expect(result).to eq([])
    end

    it 'maintains order after compression' do
      base = [10, 30, 50, 70, 90]
      result = described_class.compress_segments(base, { start: 1, end: 66 })
      expect(result).to eq(result.sort)
    end
  end

  describe '.effective_reach' do
    it 'returns nil for ranged weapon type' do
      expect(described_class.effective_reach(:ranged, nil, nil)).to be_nil
    end

    it 'returns nil for natural_ranged weapon type' do
      expect(described_class.effective_reach(:natural_ranged, nil, nil)).to be_nil
    end

    it 'returns unarmed reach for unarmed type' do
      expect(described_class.effective_reach(:unarmed, nil, nil)).to eq(
        GameConfig::Mechanics::REACH[:unarmed_reach]
      )
    end

    it 'returns natural attack reach for natural_melee type' do
      # Mock NpcAttack with melee_reach_value
      attack = double('NpcAttack', melee_reach_value: 4)
      expect(described_class.effective_reach(:natural_melee, nil, attack)).to eq(4)
    end

    it 'falls back to unarmed reach for natural_melee without reach value' do
      attack = double('NpcAttack', melee_reach_value: nil)
      expect(described_class.effective_reach(:natural_melee, nil, attack)).to eq(
        GameConfig::Mechanics::REACH[:unarmed_reach]
      )
    end
  end
end
