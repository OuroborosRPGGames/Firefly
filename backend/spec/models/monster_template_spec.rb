# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MonsterTemplate do
  describe 'constants' do
    it 'defines MONSTER_TYPES' do
      expect(described_class::MONSTER_TYPES).to eq(%w[colossus dragon behemoth titan golem hydra serpent])
    end
  end

  describe 'validations' do
    it 'requires name' do
      template = described_class.new(total_hp: 1000, hex_width: 3, hex_height: 3, climb_distance: 2, defeat_threshold_percent: 50)
      expect(template.valid?).to be false
      expect(template.errors[:name]).to include('is not present')
    end

    it 'requires total_hp' do
      template = described_class.new(name: 'Dragon', hex_width: 3, hex_height: 3, climb_distance: 2, defeat_threshold_percent: 50)
      expect(template.valid?).to be false
      expect(template.errors[:total_hp]).to include('is not present')
    end

    it 'requires hex_width' do
      template = described_class.new(name: 'Dragon', total_hp: 1000, hex_height: 3, climb_distance: 2, defeat_threshold_percent: 50)
      expect(template.valid?).to be false
      expect(template.errors[:hex_width]).to include('is not present')
    end

    it 'requires hex_height' do
      template = described_class.new(name: 'Dragon', total_hp: 1000, hex_width: 3, climb_distance: 2, defeat_threshold_percent: 50)
      expect(template.valid?).to be false
      expect(template.errors[:hex_height]).to include('is not present')
    end

    it 'requires climb_distance' do
      template = described_class.new(name: 'Dragon', total_hp: 1000, hex_width: 3, hex_height: 3, defeat_threshold_percent: 50)
      expect(template.valid?).to be false
      expect(template.errors[:climb_distance]).to include('is not present')
    end

    it 'requires defeat_threshold_percent' do
      template = described_class.new(name: 'Dragon', total_hp: 1000, hex_width: 3, hex_height: 3, climb_distance: 2)
      expect(template.valid?).to be false
      expect(template.errors[:defeat_threshold_percent]).to include('is not present')
    end

    it 'validates unique name' do
      described_class.create(name: 'Unique Dragon', total_hp: 1000, hex_width: 3, hex_height: 3, climb_distance: 2, defeat_threshold_percent: 50)

      duplicate = described_class.new(name: 'Unique Dragon', total_hp: 500, hex_width: 2, hex_height: 2, climb_distance: 1, defeat_threshold_percent: 40)
      expect(duplicate.valid?).to be false
      expect(duplicate.errors[:name]).to include('is already taken')
    end

    it 'validates name max length' do
      template = described_class.new(name: 'A' * 101, total_hp: 1000, hex_width: 3, hex_height: 3, climb_distance: 2, defeat_threshold_percent: 50)
      expect(template.valid?).to be false
      expect(template.errors[:name]).not_to be_empty
    end

    it 'validates monster_type is in MONSTER_TYPES' do
      template = described_class.new(
        name: 'Test',
        total_hp: 1000,
        hex_width: 3,
        hex_height: 3,
        climb_distance: 2,
        defeat_threshold_percent: 50,
        monster_type: 'invalid'
      )
      expect(template.valid?).to be false
      expect(template.errors[:monster_type]).not_to be_empty
    end

    it 'accepts valid monster_type' do
      described_class::MONSTER_TYPES.each do |type|
        template = described_class.new(
          name: "Test #{type}",
          total_hp: 1000,
          hex_width: 3,
          hex_height: 3,
          climb_distance: 2,
          defeat_threshold_percent: 50,
          monster_type: type
        )
        expect(template).to be_valid, "Expected monster_type '#{type}' to be valid"
      end
    end

    it 'accepts nil monster_type' do
      template = described_class.new(
        name: 'Test No Type',
        total_hp: 1000,
        hex_width: 3,
        hex_height: 3,
        climb_distance: 2,
        defeat_threshold_percent: 50,
        monster_type: nil
      )
      expect(template.valid?).to be true
    end
  end

  describe '#weak_point_segment' do
    let(:template) do
      described_class.create(
        name: 'Dragon With Weak Point',
        total_hp: 1000,
        hex_width: 3,
        hex_height: 3,
        climb_distance: 2,
        defeat_threshold_percent: 50
      )
    end

    it 'returns nil when no weak point segment exists' do
      expect(template.weak_point_segment).to be_nil
    end

    it 'returns weak point segment when one exists' do
      MonsterSegmentTemplate.create(
        monster_template_id: template.id,
        name: 'Heart',
        hp_percent: 20,
        attacks_per_round: 0,
        attack_speed: 0,
        reach: 1,
        is_weak_point: true
      )

      expect(template.weak_point_segment.name).to eq('Heart')
    end
  end

  describe '#mobility_segments' do
    let(:template) do
      described_class.create(
        name: 'Mobile Monster',
        total_hp: 1000,
        hex_width: 3,
        hex_height: 3,
        climb_distance: 2,
        defeat_threshold_percent: 50
      )
    end

    it 'returns segments required for mobility' do
      MonsterSegmentTemplate.create(
        monster_template_id: template.id,
        name: 'Left Leg',
        hp_percent: 15,
        attacks_per_round: 1,
        attack_speed: 5,
        reach: 1,
        required_for_mobility: true
      )
      MonsterSegmentTemplate.create(
        monster_template_id: template.id,
        name: 'Head',
        hp_percent: 20,
        attacks_per_round: 2,
        attack_speed: 3,
        reach: 1,
        required_for_mobility: false
      )

      mobility = template.mobility_segments
      expect(mobility.map(&:name)).to eq(['Left Leg'])
    end
  end

  describe '#limb_segments' do
    let(:template) do
      described_class.create(
        name: 'Limbed Monster',
        total_hp: 1000,
        hex_width: 3,
        hex_height: 3,
        climb_distance: 2,
        defeat_threshold_percent: 50
      )
    end

    it 'returns limb-type segments' do
      MonsterSegmentTemplate.create(
        monster_template_id: template.id,
        name: 'Arm',
        hp_percent: 15,
        attacks_per_round: 1,
        attack_speed: 5,
        reach: 1,
        segment_type: 'limb'
      )
      MonsterSegmentTemplate.create(
        monster_template_id: template.id,
        name: 'Head',
        hp_percent: 20,
        attacks_per_round: 2,
        attack_speed: 3,
        reach: 1,
        segment_type: 'head'
      )

      limbs = template.limb_segments
      expect(limbs.map(&:name)).to eq(['Arm'])
    end
  end

  describe '#calculate_segment_hp' do
    let(:template) do
      described_class.create(
        name: 'HP Calc Test',
        total_hp: 1000,
        hex_width: 3,
        hex_height: 3,
        climb_distance: 2,
        defeat_threshold_percent: 50
      )
    end

    it 'calculates HP based on percentage' do
      segment = MonsterSegmentTemplate.new(hp_percent: 25)
      expect(template.calculate_segment_hp(segment)).to eq(250)
    end

    it 'rounds HP values' do
      segment = MonsterSegmentTemplate.new(hp_percent: 33)
      expect(template.calculate_segment_hp(segment)).to eq(330)
    end
  end

  describe '#total_segment_hp_percent' do
    let(:template) do
      described_class.create(
        name: 'Segment Total Test',
        total_hp: 1000,
        hex_width: 3,
        hex_height: 3,
        climb_distance: 2,
        defeat_threshold_percent: 50
      )
    end

    it 'sums HP percentages of all segments' do
      MonsterSegmentTemplate.create(
        monster_template_id: template.id,
        name: 'Head',
        hp_percent: 30,
        attacks_per_round: 2,
        attack_speed: 3,
        reach: 1
      )
      MonsterSegmentTemplate.create(
        monster_template_id: template.id,
        name: 'Body',
        hp_percent: 50,
        attacks_per_round: 1,
        attack_speed: 5,
        reach: 1
      )

      expect(template.total_segment_hp_percent).to eq(80)
    end
  end

  describe '#parsed_behavior_config' do
    let(:template) do
      described_class.create(
        name: 'Behavior Test',
        total_hp: 1000,
        hex_width: 3,
        hex_height: 3,
        climb_distance: 2,
        defeat_threshold_percent: 50
      )
    end

    it 'returns empty hash when behavior_config is nil' do
      expect(template.parsed_behavior_config).to eq({})
    end

    it 'parses hash behavior config' do
      template.update(behavior_config: Sequel.pg_jsonb_wrap({ 'shake_off_threshold' => 3 }))
      expect(template.parsed_behavior_config).to eq({ 'shake_off_threshold' => 3 })
    end

    it 'parses string behavior config' do
      template.values[:behavior_config] = '{"shake_off_threshold": 3}'
      expect(template.parsed_behavior_config).to eq({ 'shake_off_threshold' => 3 })
    end

    it 'handles invalid JSON gracefully' do
      template.values[:behavior_config] = 'invalid json'
      expect(template.parsed_behavior_config).to eq({})
    end
  end

  describe '#shake_off_threshold' do
    let(:template) do
      described_class.create(
        name: 'Shake Test',
        total_hp: 1000,
        hex_width: 3,
        hex_height: 3,
        climb_distance: 2,
        defeat_threshold_percent: 50
      )
    end

    it 'returns default value when not configured' do
      expect(template.shake_off_threshold).to eq(2)
    end

    it 'returns configured value' do
      template.update(behavior_config: Sequel.pg_jsonb_wrap({ 'shake_off_threshold' => 5 }))
      expect(template.shake_off_threshold).to eq(5)
    end
  end

  describe '#segment_attack_count_range' do
    let(:template) do
      described_class.create(
        name: 'Attack Range Test',
        total_hp: 1000,
        hex_width: 3,
        hex_height: 3,
        climb_distance: 2,
        defeat_threshold_percent: 50
      )
    end

    it 'returns default range when not configured' do
      expect(template.segment_attack_count_range).to eq([2, 3])
    end

    it 'returns configured range' do
      template.update(behavior_config: Sequel.pg_jsonb_wrap({ 'segment_attack_count' => [1, 4] }))
      expect(template.segment_attack_count_range).to eq([1, 4])
    end

    it 'returns default for invalid range' do
      template.update(behavior_config: Sequel.pg_jsonb_wrap({ 'segment_attack_count' => 'invalid' }))
      expect(template.segment_attack_count_range).to eq([2, 3])
    end
  end

  describe '#occupied_hexes_at' do
    let(:template) do
      described_class.create(
        name: 'Hex Test',
        total_hp: 1000,
        hex_width: 3,
        hex_height: 3,
        climb_distance: 2,
        defeat_threshold_percent: 50
      )
    end

    it 'returns hex coordinates for monster footprint' do
      hexes = template.occupied_hexes_at(5, 5)

      expect(hexes).to be_an(Array)
      expect(hexes).not_to be_empty
      expect(hexes).to all(be_an(Array))
    end

    it 'centers hexes around given position' do
      hexes = template.occupied_hexes_at(10, 10)

      # With hex_width=3, half_width=1, so x ranges from 9 to 11
      x_values = hexes.map(&:first)
      expect(x_values.min).to be >= 9
      expect(x_values.max).to be <= 11
    end
  end

  describe '#spawn_in_fight' do
    let(:template) do
      described_class.create(
        name: 'Spawn Test',
        total_hp: 1000,
        hex_width: 3,
        hex_height: 3,
        climb_distance: 2,
        defeat_threshold_percent: 50
      )
    end
    let(:fight) { create(:fight) }

    before do
      MonsterSegmentTemplate.create(
        monster_template_id: template.id,
        name: 'Head',
        hp_percent: 30,
        attacks_per_round: 2,
        attack_speed: 3,
        reach: 1
      )
    end

    it 'creates a monster instance' do
      instance = template.spawn_in_fight(fight, 5, 5)

      expect(instance.id).not_to be_nil
      expect(instance.monster_template_id).to eq(template.id)
      expect(instance.fight_id).to eq(fight.id)
      expect(instance.current_hp).to eq(1000)
      expect(instance.max_hp).to eq(1000)
    end

    it 'sets center hex position' do
      instance = template.spawn_in_fight(fight, 10, 12)

      expect(instance.center_hex_x).to eq(10)
      expect(instance.center_hex_y).to eq(12)
    end

    it 'creates segment instances' do
      instance = template.spawn_in_fight(fight, 5, 5)

      segment_instances = MonsterSegmentInstance.where(large_monster_instance_id: instance.id).all
      expect(segment_instances.count).to eq(1)
      expect(segment_instances.first.current_hp).to eq(300) # 30% of 1000
    end

    it 'marks fight as having a monster' do
      template.spawn_in_fight(fight, 5, 5)

      expect(fight.reload.has_monster).to be true
    end
  end

  describe 'associations' do
    let(:template) do
      described_class.create(
        name: 'Association Test',
        total_hp: 1000,
        hex_width: 3,
        hex_height: 3,
        climb_distance: 2,
        defeat_threshold_percent: 50
      )
    end

    it 'has many monster_segment_templates' do
      expect(template.monster_segment_templates).to eq([])
    end

    it 'has many large_monster_instances' do
      expect(template.large_monster_instances).to eq([])
    end
  end
end
