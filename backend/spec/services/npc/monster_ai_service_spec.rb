# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MonsterAIService do
  # Mock objects for testing
  let(:monster_template) do
    instance_double(
      MonsterTemplate,
      shake_off_threshold: 3,
      segment_attack_count_range: [1, 3],
      npc_archetype: nil
    )
  end

  let(:fight) do
    instance_double(
      Fight,
      fight_participants: [],
      arena_width: 50,
      arena_height: 50
    )
  end

  let(:monster_instance) do
    instance_double(
      LargeMonsterInstance,
      monster_template: monster_template,
      fight: fight,
      monster_mount_states: [],
      segments_that_can_attack: [],
      monster_segment_instances: [],
      collapsed?: false,
      facing_direction: 0,
      center_hex_x: 25,
      center_hex_y: 25,
      direction_to: 0
    )
  end

  subject(:service) { described_class.new(monster_instance) }

  # ============================================
  # Class Structure
  # ============================================

  describe 'class structure' do
    it 'defines a class' do
      expect(described_class).to be_a(Class)
    end

    it 'initializes with monster_instance' do
      expect(service).to be_a(described_class)
    end
  end

  # ============================================
  # Assess Threats
  # ============================================

  describe '#assess_threats' do
    context 'with no mount states' do
      it 'returns empty threat categories' do
        result = service.assess_threats

        expect(result[:at_weak_point]).to eq([])
        expect(result[:climbing]).to eq([])
        expect(result[:mounted]).to eq([])
        expect(result[:total_mounted]).to eq(0)
      end
    end

    context 'with mount states at different positions' do
      let(:weak_point_state) { instance_double(MonsterMountState, mount_status: 'at_weak_point') }
      let(:climbing_state) { instance_double(MonsterMountState, mount_status: 'climbing') }
      let(:mounted_state) { instance_double(MonsterMountState, mount_status: 'mounted') }
      let(:thrown_state) { instance_double(MonsterMountState, mount_status: 'thrown') }

      before do
        allow(monster_instance).to receive(:monster_mount_states)
          .and_return([weak_point_state, climbing_state, mounted_state, thrown_state])
      end

      it 'categorizes at_weak_point correctly' do
        result = service.assess_threats
        expect(result[:at_weak_point]).to eq([weak_point_state])
      end

      it 'categorizes climbing correctly' do
        result = service.assess_threats
        expect(result[:climbing]).to eq([climbing_state])
      end

      it 'categorizes mounted correctly' do
        result = service.assess_threats
        expect(result[:mounted]).to eq([mounted_state])
      end

      it 'counts total_mounted excluding thrown/dismounted' do
        result = service.assess_threats
        expect(result[:total_mounted]).to eq(3) # weak_point + climbing + mounted
      end
    end
  end

  # ============================================
  # Should Shake Off?
  # ============================================

  describe '#should_shake_off?' do
    context 'when someone is at the weak point' do
      before do
        weak_point_state = instance_double(MonsterMountState, mount_status: 'at_weak_point')
        allow(monster_instance).to receive(:monster_mount_states)
          .and_return([weak_point_state])
      end

      it 'returns true (urgent)' do
        expect(service.should_shake_off?).to be true
      end
    end

    context 'when total mounted >= threshold' do
      before do
        states = 3.times.map { instance_double(MonsterMountState, mount_status: 'mounted') }
        allow(monster_instance).to receive(:monster_mount_states).and_return(states)
      end

      it 'returns true' do
        expect(service.should_shake_off?).to be true
      end
    end

    context 'when total mounted < threshold' do
      before do
        states = 2.times.map { instance_double(MonsterMountState, mount_status: 'mounted') }
        allow(monster_instance).to receive(:monster_mount_states).and_return(states)
      end

      it 'returns false' do
        expect(service.should_shake_off?).to be false
      end
    end

    context 'when climbers reduce effective threshold' do
      before do
        # 2 mounted + 1 climbing = 3 total, but climbing reduces threshold from 3 to 2
        states = [
          instance_double(MonsterMountState, mount_status: 'mounted'),
          instance_double(MonsterMountState, mount_status: 'mounted'),
          instance_double(MonsterMountState, mount_status: 'climbing')
        ]
        allow(monster_instance).to receive(:monster_mount_states).and_return(states)
      end

      it 'triggers shake off at lower count due to climbing threat' do
        # threshold = 3, climbing_count = 1, adjusted = 2
        # total_mounted = 3 >= adjusted_threshold = 2
        expect(service.should_shake_off?).to be true
      end
    end
  end

  # ============================================
  # Shake Off Segment Number
  # ============================================

  describe '#shake_off_segment_number' do
    context 'when should not shake off' do
      before do
        allow(monster_instance).to receive(:monster_mount_states).and_return([])
      end

      it 'returns nil' do
        expect(service.shake_off_segment_number).to be_nil
      end
    end

    context 'when weak point is threatened (urgent)' do
      before do
        weak_point_state = instance_double(MonsterMountState, mount_status: 'at_weak_point')
        allow(monster_instance).to receive(:monster_mount_states)
          .and_return([weak_point_state])
      end

      it 'returns early segment number (15-25)' do
        result = service.shake_off_segment_number
        expect(result).to be_between(15, 25)
      end
    end

    context 'when normal shake off' do
      before do
        states = 3.times.map { instance_double(MonsterMountState, mount_status: 'mounted') }
        allow(monster_instance).to receive(:monster_mount_states).and_return(states)
      end

      it 'returns mid-round segment number (45-55)' do
        result = service.shake_off_segment_number
        expect(result).to be_between(45, 55)
      end
    end
  end

  # ============================================
  # Select Attacking Segments
  # ============================================

  describe '#select_attacking_segments' do
    let(:segment1) { instance_double(MonsterSegmentInstance, id: 1) }
    let(:segment2) { instance_double(MonsterSegmentInstance, id: 2) }
    let(:segment3) { instance_double(MonsterSegmentInstance, id: 3) }

    before do
      allow(monster_instance).to receive(:segments_that_can_attack)
        .and_return([segment1, segment2, segment3])
    end

    context 'with no available segments' do
      before do
        allow(monster_instance).to receive(:segments_that_can_attack).and_return([])
      end

      it 'returns empty array' do
        expect(service.select_attacking_segments).to eq([])
      end
    end

    context 'with weak point threat' do
      before do
        weak_point_state = instance_double(
          MonsterMountState,
          mount_status: 'at_weak_point',
          current_segment_id: nil
        )
        allow(monster_instance).to receive(:monster_mount_states).and_return([weak_point_state])
      end

      it 'returns all available segments (emergency response)' do
        result = service.select_attacking_segments
        expect(result).to eq([segment1, segment2, segment3])
      end
    end

    context 'with normal combat (no threats)' do
      before do
        allow(monster_instance).to receive(:monster_mount_states).and_return([])
      end

      it 'returns subset of available segments' do
        result = service.select_attacking_segments
        expect(result.length).to be_between(1, 3)
        result.each do |seg|
          expect([segment1, segment2, segment3]).to include(seg)
        end
      end
    end
  end

  # ============================================
  # Segment Can Hit?
  # ============================================

  describe '#segment_can_hit?' do
    let(:segment_template) { instance_double(MonsterSegmentTemplate, reach: 2) }
    let(:segment) do
      instance_double(
        MonsterSegmentInstance,
        monster_segment_template: segment_template,
        hex_position: [25, 25]
      )
    end

    context 'when target is mounted on this monster' do
      let(:target) do
        instance_double(
          FightParticipant,
          is_mounted: true,
          targeting_monster_id: monster_instance.object_id,
          hex_x: 50,
          hex_y: 50
        )
      end

      before do
        allow(monster_instance).to receive(:id).and_return(monster_instance.object_id)
      end

      it 'always returns true (mounted targets are always hittable)' do
        expect(service.segment_can_hit?(segment, target)).to be true
      end
    end

    context 'when target is within reach' do
      let(:target) do
        instance_double(
          FightParticipant,
          is_mounted: false,
          targeting_monster_id: nil,
          hex_x: 26,
          hex_y: 26
        )
      end

      it 'returns true' do
        expect(service.segment_can_hit?(segment, target)).to be true
      end
    end

    context 'when target is out of reach' do
      let(:target) do
        instance_double(
          FightParticipant,
          is_mounted: false,
          targeting_monster_id: nil,
          hex_x: 50,
          hex_y: 50
        )
      end

      it 'returns false' do
        expect(service.segment_can_hit?(segment, target)).to be false
      end
    end
  end

  # ============================================
  # Select Target For Segment
  # ============================================

  describe '#select_target_for_segment' do
    let(:segment_template) { instance_double(MonsterSegmentTemplate, reach: 10) }
    let(:segment) do
      instance_double(
        MonsterSegmentInstance,
        id: 1,
        monster_segment_template: segment_template,
        hex_position: [25, 25]
      )
    end

    context 'when there are no targets' do
      before do
        allow(fight).to receive(:fight_participants).and_return([])
        allow(monster_instance).to receive(:monster_mount_states).and_return([])
      end

      it 'returns nil' do
        expect(service.select_target_for_segment(segment)).to be_nil
      end
    end

    context 'when there is a weak point attacker' do
      let(:weak_point_participant) do
        instance_double(
          FightParticipant,
          id: 1,
          is_knocked_out: false,
          is_mounted: true,
          targeting_monster_id: monster_instance.object_id,
          hex_x: 26,
          hex_y: 26
        )
      end

      let(:weak_point_state) do
        instance_double(
          MonsterMountState,
          mount_status: 'at_weak_point',
          fight_participant_id: 1
        )
      end

      before do
        allow(fight).to receive(:fight_participants).and_return([weak_point_participant])
        allow(monster_instance).to receive(:monster_mount_states).and_return([weak_point_state])
        allow(monster_instance).to receive(:id).and_return(monster_instance.object_id)
      end

      it 'prioritizes the weak point attacker' do
        result = service.select_target_for_segment(segment)
        expect(result).to eq(weak_point_participant)
      end
    end
  end

  # ============================================
  # Decide Actions
  # ============================================

  describe '#decide_actions' do
    before do
      allow(monster_instance).to receive(:monster_mount_states).and_return([])
      allow(monster_instance).to receive(:segments_that_can_attack).and_return([])
      allow(fight).to receive(:fight_participants).and_return([])
    end

    it 'returns a hash with all required keys' do
      result = service.decide_actions

      expect(result).to have_key(:attacking_segments)
      expect(result).to have_key(:should_shake_off)
      expect(result).to have_key(:shake_off_segment)
      expect(result).to have_key(:should_turn)
      expect(result).to have_key(:turn_direction)
      expect(result).to have_key(:should_move)
      expect(result).to have_key(:move_target)
      expect(result).to have_key(:movement_segment)
    end

    it 'returns attacking_segments as array' do
      result = service.decide_actions
      expect(result[:attacking_segments]).to be_an(Array)
    end

    it 'returns boolean for should_shake_off' do
      result = service.decide_actions
      expect([true, false]).to include(result[:should_shake_off])
    end

    it 'returns movement_segment in expected range' do
      result = service.decide_actions
      expect(result[:movement_segment]).to be_between(35, 50)
    end
  end

  # ============================================
  # Instance Methods Existence
  # ============================================

  describe 'instance methods' do
    %i[
      decide_actions
      assess_threats
      select_attacking_segments
      should_shake_off?
      shake_off_segment_number
      select_target_for_segment
      segment_can_hit?
    ].each do |method|
      it "defines #{method}" do
        expect(described_class.instance_methods).to include(method)
      end
    end
  end
end
