# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MonsterSegmentTemplate do
  let(:monster_template) do
    MonsterTemplate.create(
      name: 'Test Dragon',
      total_hp: 1000,
      hex_width: 3,
      hex_height: 3,
      climb_distance: 2,
      defeat_threshold_percent: 50
    )
  end

  describe 'constants' do
    it 'defines SEGMENT_TYPES' do
      expect(described_class::SEGMENT_TYPES).to eq(%w[head limb body tail wing tentacle core])
    end
  end

  describe 'validations' do
    it 'requires monster_template_id' do
      segment = described_class.new(name: 'Head', hp_percent: 20, attacks_per_round: 2, attack_speed: 3)
      expect(segment.valid?).to be false
      expect(segment.errors[:monster_template_id]).to include('is not present')
    end

    it 'requires name' do
      segment = described_class.new(monster_template_id: monster_template.id, hp_percent: 20, attacks_per_round: 2, attack_speed: 3)
      expect(segment.valid?).to be false
      expect(segment.errors[:name]).to include('is not present')
    end

    it 'requires hp_percent' do
      segment = described_class.new(monster_template_id: monster_template.id, name: 'Head', attacks_per_round: 2, attack_speed: 3)
      expect(segment.valid?).to be false
      expect(segment.errors[:hp_percent]).to include('is not present')
    end

    it 'requires attacks_per_round' do
      segment = described_class.new(monster_template_id: monster_template.id, name: 'Head', hp_percent: 20, attack_speed: 3)
      expect(segment.valid?).to be false
      expect(segment.errors[:attacks_per_round]).to include('is not present')
    end

    it 'requires attack_speed' do
      segment = described_class.new(monster_template_id: monster_template.id, name: 'Head', hp_percent: 20, attacks_per_round: 2)
      expect(segment.valid?).to be false
      expect(segment.errors[:attack_speed]).to include('is not present')
    end

    it 'validates name max length' do
      segment = described_class.new(
        monster_template_id: monster_template.id,
        name: 'A' * 51,
        hp_percent: 20,
        attacks_per_round: 2,
        attack_speed: 3
      )
      expect(segment.valid?).to be false
      expect(segment.errors[:name]).not_to be_empty
    end

    it 'validates segment_type is in SEGMENT_TYPES' do
      segment = described_class.new(
        monster_template_id: monster_template.id,
        name: 'Head',
        hp_percent: 20,
        attacks_per_round: 2,
        attack_speed: 3,
        segment_type: 'invalid'
      )
      expect(segment.valid?).to be false
      expect(segment.errors[:segment_type]).not_to be_empty
    end

    it 'accepts valid segment_type' do
      described_class::SEGMENT_TYPES.each do |type|
        segment = described_class.new(
          monster_template_id: monster_template.id,
          name: "Test #{type}",
          hp_percent: 20,
          attacks_per_round: 2,
          attack_speed: 3,
          reach: 1,
          segment_type: type
        )
        expect(segment.valid?).to eq(true), "Expected segment_type '#{type}' to be valid"
      end
    end

    it 'accepts nil segment_type' do
      segment = described_class.new(
        monster_template_id: monster_template.id,
        name: 'No Type',
        hp_percent: 20,
        attacks_per_round: 2,
        attack_speed: 3,
        reach: 1,
        segment_type: nil
      )
      expect(segment.valid?).to be true
    end

    it 'accepts valid segment' do
      segment = described_class.new(
        monster_template_id: monster_template.id,
        name: 'Head',
        hp_percent: 20,
        attacks_per_round: 2,
        attack_speed: 3,
        reach: 1
      )
      expect(segment.valid?).to be true
    end
  end

  describe 'associations' do
    let(:segment) do
      described_class.create(
        monster_template_id: monster_template.id,
        name: 'Test Head',
        hp_percent: 20,
        attacks_per_round: 2,
        attack_speed: 3,
        reach: 1
      )
    end

    it 'belongs to monster_template' do
      expect(segment.monster_template).to eq(monster_template)
    end

    it 'has many monster_segment_instances' do
      expect(segment.monster_segment_instances).to eq([])
    end
  end

  describe '#attack_segments' do
    it 'returns empty array when attacks_per_round is 0' do
      segment = described_class.new(attacks_per_round: 0)
      expect(segment.attack_segments).to eq([])
    end

    it 'returns attack segments for single attack' do
      segment = described_class.new(attacks_per_round: 1)
      segments = segment.attack_segments

      expect(segments.length).to eq(1)
      expect(segments.first).to be_between(1, 100)
    end

    it 'returns attack segments for multiple attacks' do
      segment = described_class.new(attacks_per_round: 4)
      segments = segment.attack_segments

      expect(segments.length).to eq(4)
      segments.each { |s| expect(s).to be_between(1, 100) }
    end

    it 'distributes attacks evenly across the timeline' do
      segment = described_class.new(attacks_per_round: 4)
      segments = segment.attack_segments

      # With 4 attacks, they should be roughly at 12.5, 37.5, 62.5, 87.5
      expect(segments[0]).to be_between(10, 15)
      expect(segments[1]).to be_between(35, 40)
      expect(segments[2]).to be_between(60, 65)
      expect(segments[3]).to be_between(85, 90)
    end
  end

  describe '#parsed_damage_dice' do
    it 'parses standard damage dice' do
      segment = described_class.new(damage_dice: '3d6')
      result = segment.parsed_damage_dice

      expect(result[:count]).to eq(3)
      expect(result[:sides]).to eq(6)
      expect(result[:modifier]).to eq(0)
    end

    it 'parses damage dice with positive modifier' do
      segment = described_class.new(damage_dice: '2d8+5')
      result = segment.parsed_damage_dice

      expect(result[:count]).to eq(2)
      expect(result[:sides]).to eq(8)
      expect(result[:modifier]).to eq(5)
    end

    it 'parses damage dice with negative modifier' do
      segment = described_class.new(damage_dice: '4d4-2')
      result = segment.parsed_damage_dice

      expect(result[:count]).to eq(4)
      expect(result[:sides]).to eq(4)
      expect(result[:modifier]).to eq(-2)
    end

    it 'returns default values when damage_dice is nil' do
      segment = described_class.new(damage_dice: nil)
      result = segment.parsed_damage_dice

      expect(result[:count]).to eq(2)
      expect(result[:sides]).to eq(8)
      expect(result[:modifier]).to eq(0)
    end

    it 'returns default values for invalid format' do
      segment = described_class.new(damage_dice: 'invalid')
      result = segment.parsed_damage_dice

      expect(result[:count]).to eq(2)
      expect(result[:sides]).to eq(8)
      expect(result[:modifier]).to eq(0)
    end
  end

  describe '#roll_damage' do
    it 'returns a value within expected range' do
      segment = described_class.new(damage_dice: '2d6')

      # Roll many times and check bounds
      results = 100.times.map { segment.roll_damage }

      expect(results.min).to be >= 2  # Minimum: 2 * 1 = 2
      expect(results.max).to be <= 12 # Maximum: 2 * 6 = 12
    end

    it 'applies modifier to roll' do
      segment = described_class.new(damage_dice: '1d6+3')

      results = 100.times.map { segment.roll_damage }

      expect(results.min).to be >= 4  # 1 + 3 = 4
      expect(results.max).to be <= 9  # 6 + 3 = 9
    end
  end

  describe '#parsed_attack_effects' do
    let(:segment) do
      described_class.create(
        monster_template_id: monster_template.id,
        name: 'Test',
        hp_percent: 20,
        attacks_per_round: 2,
        attack_speed: 3,
        reach: 1
      )
    end

    it 'returns empty array when attack_effects is nil' do
      expect(segment.parsed_attack_effects).to eq([])
    end

    it 'parses array attack effects' do
      segment.update(attack_effects: Sequel.pg_jsonb_wrap([{ 'type' => 'knockback', 'distance' => 2 }]))
      expect(segment.parsed_attack_effects).to eq([{ 'type' => 'knockback', 'distance' => 2 }])
    end

    it 'parses string attack effects' do
      segment.values[:attack_effects] = '[{"type": "knockback"}]'
      expect(segment.parsed_attack_effects).to eq([{ 'type' => 'knockback' }])
    end

    it 'handles invalid JSON gracefully' do
      segment.values[:attack_effects] = 'invalid'
      expect(segment.parsed_attack_effects).to eq([])
    end
  end

  describe '#has_effect?' do
    let(:segment) do
      described_class.create(
        monster_template_id: monster_template.id,
        name: 'Test',
        hp_percent: 20,
        attacks_per_round: 2,
        attack_speed: 3,
        reach: 1,
        attack_effects: Sequel.pg_jsonb_wrap([{ 'type' => 'knockback' }, { 'type' => 'grab' }])
      )
    end

    it 'returns true when effect is present' do
      expect(segment.has_effect?('knockback')).to be true
    end

    it 'returns false when effect is not present' do
      expect(segment.has_effect?('stun')).to be false
    end
  end

  describe '#position_at' do
    let(:segment) do
      described_class.new(
        hex_offset_x: 1,
        hex_offset_y: 2
      )
    end

    it 'calculates position without rotation' do
      x, y = segment.position_at(10, 10, 0)
      expect(x).to eq(11)
      expect(y).to eq(12)
    end

    it 'handles zero offsets' do
      zero_segment = described_class.new(hex_offset_x: 0, hex_offset_y: 0)
      x, y = zero_segment.position_at(5, 5, 3)
      expect(x).to eq(5)
      expect(y).to eq(5)
    end

    it 'handles nil offsets' do
      nil_segment = described_class.new
      x, y = nil_segment.position_at(5, 5, 0)
      expect(x).to eq(5)
      expect(y).to eq(5)
    end

    it 'applies rotation' do
      # Rotate once: new_dx = -dy = -2, new_dy = dx + dy = 3
      x, y = segment.position_at(10, 10, 1)
      expect(x).to eq(8)  # 10 + (-2)
      expect(y).to eq(13) # 10 + 3
    end
  end
end
