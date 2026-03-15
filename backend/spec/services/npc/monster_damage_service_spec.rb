# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MonsterDamageService do
  let(:monster_template) { double('MonsterTemplate') }
  let(:monster_instance) do
    double('LargeMonsterInstance',
      id: 1,
      monster_template: monster_template,
      display_name: 'Dragon',
      current_hp: 100,
      current_hp_percent: 75,
      defeated?: false,
      collapsed?: false
    )
  end
  let(:service) { described_class.new(monster_instance) }

  describe '#initialize' do
    it 'accepts a monster_instance' do
      expect(service.instance_variable_get(:@monster)).to eq(monster_instance)
      expect(service.instance_variable_get(:@template)).to eq(monster_template)
    end
  end

  describe '#apply_damage_to_segment' do
    let(:segment) do
      double('MonsterSegmentInstance',
        name: 'Left Wing',
        segment_type: 'wing',
        required_for_mobility?: false
      )
    end
    let(:damage_result) { { segment_hp_lost: 15, new_status: 'damaged' } }

    before do
      allow(segment).to receive(:apply_damage!).and_return(damage_result)
      allow(monster_instance).to receive(:apply_damage!)
    end

    it 'applies damage to the segment' do
      expect(segment).to receive(:apply_damage!).with(20)

      service.apply_damage_to_segment(segment, 20)
    end

    it 'applies damage to the monster total HP' do
      expect(monster_instance).to receive(:apply_damage!).with(20)

      service.apply_damage_to_segment(segment, 20)
    end

    it 'returns damage result with segment info' do
      result = service.apply_damage_to_segment(segment, 20)

      expect(result[:segment_damage]).to eq(15)
      expect(result[:total_damage]).to eq(20)
      expect(result[:segment_status]).to eq('damaged')
      expect(result[:monster_hp]).to eq(100)
      expect(result[:monster_hp_percent]).to eq(75)
    end

    context 'when segment is destroyed' do
      let(:destroyed_result) { { segment_hp_lost: 50, new_status: 'destroyed' } }

      before do
        allow(segment).to receive(:apply_damage!).and_return(destroyed_result)
      end

      it 'includes segment_destroyed event' do
        result = service.apply_damage_to_segment(segment, 50)

        event = result[:events].find { |e| e[:type] == 'segment_destroyed' }
        expect(event).not_to be_nil
        expect(event[:segment_name]).to eq('Left Wing')
        expect(event[:segment_type]).to eq('wing')
      end
    end

    context 'when mobility segment is destroyed' do
      let(:mobility_segment) do
        double('MonsterSegmentInstance',
          name: 'Left Leg',
          segment_type: 'leg',
          required_for_mobility?: true
        )
      end
      let(:destroyed_result) { { segment_hp_lost: 30, new_status: 'destroyed' } }

      before do
        allow(mobility_segment).to receive(:apply_damage!).and_return(destroyed_result)
        allow(service).to receive(:check_collapse_condition).and_return({
          collapsed: true,
          events: [{ type: 'monster_collapsed', monster_name: 'Dragon' }]
        })
      end

      it 'checks for collapse condition' do
        expect(service).to receive(:check_collapse_condition)

        service.apply_damage_to_segment(mobility_segment, 30)
      end

      it 'includes collapse event if triggered' do
        result = service.apply_damage_to_segment(mobility_segment, 30)

        collapse_event = result[:events].find { |e| e[:type] == 'monster_collapsed' }
        expect(collapse_event).not_to be_nil
      end
    end

    context 'when monster is defeated' do
      before do
        allow(monster_instance).to receive(:defeated?).and_return(true)
      end

      it 'includes monster_defeated event' do
        result = service.apply_damage_to_segment(segment, 200)

        event = result[:events].find { |e| e[:type] == 'monster_defeated' }
        expect(event).not_to be_nil
        expect(event[:monster_name]).to eq('Dragon')
      end
    end
  end

  describe '#apply_weak_point_attack' do
    let(:segment1) do
      double('MonsterSegmentInstance',
        name: 'Body',
        segment_type: 'body',
        required_for_mobility?: false
      )
    end
    let(:segment2) do
      double('MonsterSegmentInstance',
        name: 'Head',
        segment_type: 'head',
        required_for_mobility?: false
      )
    end
    let(:attacker) { double('FightParticipant', id: 1, character_name: 'Hero') }
    let(:hex_service) { double('MonsterHexService') }
    let(:mount_state) { double('MonsterMountState') }

    before do
      allow(monster_instance).to receive(:active_segments).and_return([segment1, segment2])
      allow(segment1).to receive(:apply_damage!).and_return({ segment_hp_lost: 15, new_status: 'damaged' })
      allow(segment2).to receive(:apply_damage!).and_return({ segment_hp_lost: 15, new_status: 'damaged' })
      allow(monster_instance).to receive(:apply_damage!)
      allow(MonsterMountState).to receive(:first).and_return(mount_state)
      allow(MonsterHexService).to receive(:new).and_return(hex_service)
      allow(hex_service).to receive(:calculate_scatter_position).and_return([5, 5])
      allow(hex_service).to receive(:check_hazard_at).and_return(nil)
      allow(mount_state).to receive(:fling_after_weak_point_attack!)
    end

    it 'triples the base damage' do
      result = service.apply_weak_point_attack(10, attacker)

      expect(result[:total_damage]).to eq(30)
    end

    it 'distributes damage across all active segments' do
      result = service.apply_weak_point_attack(10, attacker)

      expect(result[:damage_per_segment].keys).to contain_exactly('Body', 'Head')
    end

    it 'flings the attacker to a scatter position' do
      result = service.apply_weak_point_attack(10, attacker)

      expect(result[:scatter_position]).to eq([5, 5])
    end

    it 'includes weak_point_attack event' do
      result = service.apply_weak_point_attack(10, attacker)

      event = result[:events].find { |e| e[:type] == 'weak_point_attack' }
      expect(event).not_to be_nil
      expect(event[:base_damage]).to eq(10)
      expect(event[:total_damage]).to eq(30)
    end

    context 'when no active segments' do
      before do
        allow(monster_instance).to receive(:active_segments).and_return([])
      end

      it 'returns zero damage' do
        result = service.apply_weak_point_attack(10, attacker)

        expect(result[:total_damage]).to eq(0)
        expect(result[:damage_per_segment]).to eq({})
        expect(result[:events]).to eq([])
      end
    end

    context 'when attacker lands in hazard' do
      let(:hazard) { double('Hazard', hazard_type: 'fire') }

      before do
        allow(hex_service).to receive(:check_hazard_at).and_return(hazard)
      end

      it 'includes hazard information in flung event' do
        result = service.apply_weak_point_attack(10, attacker)

        flung_event = result[:events].find { |e| e[:type] == 'attacker_flung' }
        expect(flung_event[:landed_in_hazard]).to be true
        expect(flung_event[:hazard_type]).to eq('fire')
      end
    end
  end

  describe '#check_collapse_condition' do
    let(:mobility_segment_ok) do
      double('MonsterSegmentInstance',
        required_for_mobility?: true,
        status: 'normal'
      )
    end
    let(:mobility_segment_destroyed) do
      double('MonsterSegmentInstance',
        required_for_mobility?: true,
        status: 'destroyed'
      )
    end

    context 'when monster is already collapsed' do
      before do
        allow(monster_instance).to receive(:collapsed?).and_return(true)
      end

      it 'returns collapsed: false' do
        result = service.check_collapse_condition
        expect(result[:collapsed]).to be false
      end
    end

    context 'when no mobility segments exist' do
      before do
        allow(monster_instance).to receive(:collapsed?).and_return(false)
        allow(monster_instance).to receive(:monster_segment_instances).and_return([])
      end

      it 'returns collapsed: false' do
        result = service.check_collapse_condition
        expect(result[:collapsed]).to be false
      end
    end

    context 'when threshold not met' do
      before do
        allow(monster_instance).to receive(:collapsed?).and_return(false)
        allow(monster_instance).to receive(:monster_segment_instances).and_return([
          mobility_segment_ok,
          mobility_segment_ok,
          mobility_segment_destroyed
        ])
      end

      it 'returns collapsed: false' do
        result = service.check_collapse_condition
        expect(result[:collapsed]).to be false
      end
    end

    context 'when threshold is met' do
      let(:room) { double('Room', id: 1) }
      let(:fight) { double('Fight', arena_width: 20, arena_height: 20, room: room) }

      before do
        allow(monster_instance).to receive(:collapsed?).and_return(false)
        allow(monster_instance).to receive(:monster_segment_instances).and_return([
          mobility_segment_destroyed,
          mobility_segment_destroyed,
          mobility_segment_ok
        ])
        allow(monster_instance).to receive(:collapse!)
        allow(monster_instance).to receive(:monster_mount_states).and_return([])
        allow(monster_instance).to receive(:fight).and_return(fight)
        allow(monster_instance).to receive(:center_hex_x).and_return(5)
        allow(monster_instance).to receive(:center_hex_y).and_return(5)
      end

      it 'returns collapsed: true with event' do
        result = service.check_collapse_condition

        expect(result[:collapsed]).to be true
        event = result[:events].first
        expect(event[:type]).to eq('monster_collapsed')
        expect(event[:monster_name]).to eq('Dragon')
      end

      it 'triggers collapse' do
        expect(monster_instance).to receive(:collapse!)

        service.check_collapse_condition
      end
    end
  end

  describe '#trigger_collapse' do
    let(:mount_state) do
      double('MonsterMountState',
        mount_status: 'mounted'
      )
    end
    let(:hex_service) { double('MonsterHexService') }

    before do
      allow(monster_instance).to receive(:collapse!)
      allow(monster_instance).to receive(:monster_mount_states).and_return([mount_state])
      allow(MonsterHexService).to receive(:new).and_return(hex_service)
      allow(hex_service).to receive(:calculate_scatter_position).and_return([3, 4])
      allow(mount_state).to receive(:dismount!)
    end

    it 'collapses the monster' do
      expect(monster_instance).to receive(:collapse!)

      service.trigger_collapse
    end

    it 'dismounts all mounted players' do
      expect(mount_state).to receive(:dismount!).with(3, 4)

      service.trigger_collapse
    end

    context 'when mount state is already dismounted' do
      let(:dismounted_state) do
        double('MonsterMountState', mount_status: 'dismounted')
      end

      before do
        allow(monster_instance).to receive(:monster_mount_states).and_return([dismounted_state])
      end

      it 'skips already dismounted states' do
        expect(dismounted_state).not_to receive(:dismount!)

        service.trigger_collapse
      end
    end
  end

  describe '#check_monster_defeat' do
    it 'returns true when monster is defeated' do
      allow(monster_instance).to receive(:defeated?).and_return(true)
      expect(service.check_monster_defeat).to be true
    end

    it 'returns false when monster is not defeated' do
      allow(monster_instance).to receive(:defeated?).and_return(false)
      expect(service.check_monster_defeat).to be false
    end
  end

  describe '#update_segment_status' do
    let(:segment) { double('MonsterSegmentInstance') }

    it 'calls update_status_from_hp! on segment' do
      expect(segment).to receive(:update_status_from_hp!)

      service.update_segment_status(segment)
    end
  end

  describe 'private #fling_attacker' do
    let(:attacker) { double('FightParticipant', id: 1, character_name: 'Hero') }
    let(:mount_state) { double('MonsterMountState') }
    let(:hex_service) { double('MonsterHexService') }

    context 'when attacker is not mounted' do
      before do
        allow(MonsterMountState).to receive(:first).and_return(nil)
      end

      it 'returns nil position and event' do
        result = service.send(:fling_attacker, attacker)

        expect(result[:position]).to be_nil
        expect(result[:event]).to be_nil
      end
    end

    context 'when attacker is mounted' do
      before do
        allow(MonsterMountState).to receive(:first).and_return(mount_state)
        allow(MonsterHexService).to receive(:new).and_return(hex_service)
        allow(hex_service).to receive(:calculate_scatter_position).and_return([7, 8])
        allow(hex_service).to receive(:check_hazard_at).and_return(nil)
        allow(mount_state).to receive(:fling_after_weak_point_attack!)
      end

      it 'flings attacker to scatter position' do
        expect(mount_state).to receive(:fling_after_weak_point_attack!).with(7, 8)

        service.send(:fling_attacker, attacker)
      end

      it 'returns position and event' do
        result = service.send(:fling_attacker, attacker)

        expect(result[:position]).to eq([7, 8])
        expect(result[:event][:type]).to eq('attacker_flung')
        expect(result[:event][:landing_x]).to eq(7)
        expect(result[:event][:landing_y]).to eq(8)
      end
    end
  end
end
