# frozen_string_literal: true

require 'spec_helper'

RSpec.describe MonsterCombatService do
  let(:fight) { double('Fight', id: 1) }
  let(:service) { described_class.new(fight) }

  describe '#initialize' do
    it 'accepts a fight parameter' do
      expect(service.instance_variable_get(:@fight)).to eq(fight)
    end

    it 'initializes segment_events hash' do
      events_hash = service.instance_variable_get(:@segment_events)
      expect(events_hash).to be_a(Hash)
    end
  end

  describe '#schedule_monster_attacks' do
    let(:monster) { double('LargeMonsterInstance', id: 1, display_name: 'Dragon') }
    let(:ai_service) { double('MonsterAIService') }
    let(:segment) do
      double('MonsterSegmentInstance',
        id: 10,
        monster_segment_template: double(attack_segments: [25, 50, 75])
      )
    end
    let(:target) { double('FightParticipant', id: 100) }

    before do
      allow(MonsterAIService).to receive(:new).with(monster).and_return(ai_service)
      allow(ai_service).to receive(:decide_actions).and_return({
        should_turn: false,
        should_move: false,
        should_shake_off: false,
        attacking_segments: []
      })
    end

    it 'creates an AI service for the monster' do
      expect(MonsterAIService).to receive(:new).with(monster).and_return(ai_service)

      service.schedule_monster_attacks(monster)
    end

    context 'when monster should turn' do
      before do
        allow(ai_service).to receive(:decide_actions).and_return({
          should_turn: true,
          turn_direction: 90,
          movement_segment: 30,
          should_move: false,
          should_shake_off: false,
          attacking_segments: []
        })
      end

      it 'schedules a turn event' do
        events = service.schedule_monster_attacks(monster)

        turn_event = events[25]&.find { |e| e[:type] == :monster_turn }
        expect(turn_event).not_to be_nil
        expect(turn_event[:direction]).to eq(90)
      end
    end

    context 'when monster should move' do
      before do
        allow(ai_service).to receive(:decide_actions).and_return({
          should_turn: false,
          should_move: true,
          move_target: [5, 10],
          movement_segment: 40,
          should_shake_off: false,
          attacking_segments: []
        })
      end

      it 'schedules a move event' do
        events = service.schedule_monster_attacks(monster)

        move_event = events[40]&.find { |e| e[:type] == :monster_move }
        expect(move_event).not_to be_nil
        expect(move_event[:target_x]).to eq(5)
        expect(move_event[:target_y]).to eq(10)
      end
    end

    context 'when monster should shake off' do
      before do
        allow(ai_service).to receive(:decide_actions).and_return({
          should_turn: false,
          should_move: false,
          should_shake_off: true,
          shake_off_segment: 60,
          attacking_segments: []
        })
      end

      it 'schedules a shake-off event' do
        events = service.schedule_monster_attacks(monster)

        shake_event = events[60]&.find { |e| e[:type] == :monster_shake_off }
        expect(shake_event).not_to be_nil
      end
    end

    context 'with attacking segments' do
      before do
        allow(ai_service).to receive(:decide_actions).and_return({
          should_turn: false,
          should_move: false,
          should_shake_off: false,
          attacking_segments: [segment]
        })
        allow(ai_service).to receive(:select_target_for_segment).with(segment).and_return(target)
      end

      it 'schedules segment attacks' do
        events = service.schedule_monster_attacks(monster)

        attack_events = events.values.flatten.select { |e| e[:type] == :monster_attack }
        expect(attack_events).not_to be_empty
        expect(attack_events.first[:segment_id]).to eq(10)
        expect(attack_events.first[:target_id]).to eq(100)
      end
    end
  end

  describe '#process_monster_attack' do
    let(:monster) { double('LargeMonsterInstance', id: 1, status: 'active', active?: true, display_name: 'Dragon', monster_template: monster_template) }
    let(:monster_template) { double('MonsterTemplate', npc_archetype: archetype) }
    let(:archetype) { double('NpcArchetype', combat_stats: { damage_bonus: 5 }) }
    let(:segment) do
      double('MonsterSegmentInstance',
        id: 10,
        name: 'Claw',
        can_attack: true,
        damage_type: 'slashing'
      )
    end
    let(:target) { double('FightParticipant', id: 100, character_name: 'Hero', is_knocked_out: false) }
    let(:ai_service) { double('MonsterAIService') }
    let(:event) { { monster_id: 1, segment_id: 10, target_id: 100 } }

    before do
      allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
      allow(MonsterSegmentInstance).to receive(:[]).with(10).and_return(segment)
      allow(FightParticipant).to receive(:[]).with(100).and_return(target)
      allow(MonsterAIService).to receive(:new).with(monster).and_return(ai_service)
      allow(ai_service).to receive(:segment_can_hit?).with(segment, target).and_return(true)
      allow(segment).to receive(:roll_damage).and_return(20)
      allow(segment).to receive(:record_attack!)
      allow(segment).to receive(:respond_to?).with(:damage_type).and_return(true)
      allow(StatusEffectService).to receive(:damage_type_multiplier).and_return(1.0)
      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(0)
      allow(StatusEffectService).to receive(:absorb_damage_with_shields).and_return(25)
      allow(target).to receive(:accumulate_damage!)
    end

    it 'returns nil when monster is not found' do
      allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(nil)

      result = service.process_monster_attack(event, 50)
      expect(result).to be_nil
    end

    it 'returns nil when monster is not active' do
      allow(monster).to receive(:status).and_return('defeated')
      allow(monster).to receive(:active?).and_return(false)

      result = service.process_monster_attack(event, 50)
      expect(result).to be_nil
    end

    it 'returns nil when segment cannot attack' do
      allow(segment).to receive(:can_attack).and_return(false)

      result = service.process_monster_attack(event, 50)
      expect(result).to be_nil
    end

    it 'returns nil when target is knocked out' do
      allow(target).to receive(:is_knocked_out).and_return(true)

      result = service.process_monster_attack(event, 50)
      expect(result).to be_nil
    end

    it 'returns miss result when out of range' do
      allow(ai_service).to receive(:segment_can_hit?).and_return(false)

      result = service.process_monster_attack(event, 50)

      expect(result[:type]).to eq('monster_attack_miss')
      expect(result[:reason]).to eq('out_of_range')
    end

    it 'rolls damage and applies to target' do
      expect(segment).to receive(:roll_damage).and_return(20)
      expect(target).to receive(:accumulate_damage!).with(25)

      service.process_monster_attack(event, 50)
    end

    it 'records the attack' do
      expect(segment).to receive(:record_attack!).with(50)

      service.process_monster_attack(event, 50)
    end

    it 'returns attack result' do
      result = service.process_monster_attack(event, 50)

      expect(result[:type]).to eq('monster_attack')
      expect(result[:segment_name]).to eq('Claw')
      expect(result[:monster_name]).to eq('Dragon')
      expect(result[:target_name]).to eq('Hero')
      expect(result[:damage]).to eq(25)
      expect(result[:segment_number]).to eq(50)
    end
  end

  describe '#process_monster_turn' do
    let(:monster) { double('LargeMonsterInstance', id: 1, status: 'active', active?: true, display_name: 'Dragon', facing_direction: 0) }
    let(:event) { { monster_id: 1, direction: 90 } }

    before do
      allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
      allow(monster).to receive(:turn_to)
    end

    it 'returns nil when monster is not found or not active' do
      allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(nil)

      result = service.process_monster_turn(event)
      expect(result).to be_nil
    end

    it 'turns the monster' do
      expect(monster).to receive(:turn_to).with(90)

      service.process_monster_turn(event)
    end

    it 'returns turn result' do
      result = service.process_monster_turn(event)

      expect(result[:type]).to eq('monster_turn')
      expect(result[:monster_name]).to eq('Dragon')
      expect(result[:old_direction]).to eq(0)
      expect(result[:new_direction]).to eq(90)
    end
  end

  describe '#process_monster_move' do
    let(:monster) do
      double('LargeMonsterInstance',
        id: 1,
        status: 'active',
        active?: true,
        display_name: 'Dragon',
        collapsed?: false,
        center_hex_x: 5,
        center_hex_y: 5
      )
    end
    let(:hex_service) { double('MonsterHexService') }
    let(:event) { { monster_id: 1, target_x: 10, target_y: 15 } }

    before do
      allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
      allow(MonsterHexService).to receive(:new).with(monster).and_return(hex_service)
      allow(hex_service).to receive(:move_monster)
    end

    it 'returns nil when monster is collapsed' do
      allow(monster).to receive(:collapsed?).and_return(true)

      result = service.process_monster_move(event)
      expect(result).to be_nil
    end

    it 'moves the monster via hex service' do
      expect(hex_service).to receive(:move_monster).with(10, 15)

      service.process_monster_move(event)
    end

    it 'returns move result' do
      result = service.process_monster_move(event)

      expect(result[:type]).to eq('monster_move')
      expect(result[:monster_name]).to eq('Dragon')
      expect(result[:from_x]).to eq(5)
      expect(result[:from_y]).to eq(5)
      expect(result[:to_x]).to eq(10)
      expect(result[:to_y]).to eq(15)
    end
  end

  describe '#process_shake_off' do
    let(:monster) { double('LargeMonsterInstance', id: 1, status: 'active', active?: true, display_name: 'Dragon') }
    let(:mounting_service) { double('MonsterMountingService') }
    let(:event) { { monster_id: 1 } }

    before do
      allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
      allow(MonsterMountingService).to receive(:new).with(fight).and_return(mounting_service)
      allow(mounting_service).to receive(:process_shake_off).and_return({
        thrown_count: 2,
        results: [{ character: 'Hero', success: true }]
      })
      allow(mounting_service).to receive(:apply_thrown_positions)
    end

    it 'returns nil when monster is not found or not active' do
      allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(nil)

      result = service.process_shake_off(event)
      expect(result).to be_nil
    end

    it 'processes shake-off via mounting service' do
      expect(mounting_service).to receive(:process_shake_off).with(monster)

      service.process_shake_off(event)
    end

    it 'applies thrown positions' do
      expect(mounting_service).to receive(:apply_thrown_positions).with(monster)

      service.process_shake_off(event)
    end

    it 'returns shake-off result' do
      result = service.process_shake_off(event)

      expect(result[:type]).to eq('monster_shake_off')
      expect(result[:monster_name]).to eq('Dragon')
      expect(result[:thrown_count]).to eq(2)
    end
  end

  describe '#process_attack_on_monster' do
    let(:attacker) { double('FightParticipant', character_name: 'Hero') }
    let(:monster) { double('LargeMonsterInstance', id: 1) }
    let(:mounting_service) { double('MonsterMountingService') }
    let(:damage_service) { double('MonsterDamageService') }
    let(:target_segment) { double('MonsterSegmentInstance', name: 'Body') }

    before do
      allow(MonsterMountingService).to receive(:new).with(fight).and_return(mounting_service)
      allow(MonsterDamageService).to receive(:new).with(monster).and_return(damage_service)
    end

    context 'when attacker is at weak point' do
      before do
        allow(mounting_service).to receive(:at_weak_point?).with(attacker, monster).and_return(true)
        allow(damage_service).to receive(:apply_weak_point_attack).and_return({
          total_damage: 30,
          events: [{ type: 'weak_point_attack' }]
        })
      end

      it 'applies weak point attack' do
        expect(damage_service).to receive(:apply_weak_point_attack).with(10, attacker)

        service.process_attack_on_monster(attacker, monster, 10)
      end
    end

    context 'when attacker targets specific segment' do
      before do
        allow(mounting_service).to receive(:at_weak_point?).and_return(false)
        allow(mounting_service).to receive(:target_segment).and_return(target_segment)
        allow(damage_service).to receive(:apply_damage_to_segment).and_return({
          segment_hp_lost: 10,
          segment_status: 'damaged',
          monster_hp: 90,
          monster_hp_percent: 90,
          events: []
        })
      end

      it 'applies damage to target segment' do
        expect(damage_service).to receive(:apply_damage_to_segment).with(target_segment, 15)

        service.process_attack_on_monster(attacker, monster, 15)
      end

      it 'returns success result' do
        result = service.process_attack_on_monster(attacker, monster, 15)

        expect(result[:success]).to be true
        expect(result[:segment_name]).to eq('Body')
      end
    end

    context 'when no target segment found' do
      before do
        allow(mounting_service).to receive(:at_weak_point?).and_return(false)
        allow(mounting_service).to receive(:target_segment).and_return(nil)
      end

      it 'returns failure result' do
        result = service.process_attack_on_monster(attacker, monster, 15)

        expect(result[:success]).to be false
        expect(result[:reason]).to eq('no_target_segment')
      end
    end
  end

  describe '#monsters_in_fight' do
    let(:monster1) { double('LargeMonsterInstance') }
    let(:monster2) { double('LargeMonsterInstance') }
    let(:monsters_dataset) { double('Dataset') }

    before do
      allow(LargeMonsterInstance).to receive(:where).with(fight_id: 1, status: 'active').and_return(monsters_dataset)
      allow(monsters_dataset).to receive(:all).and_return([monster1, monster2])
    end

    it 'returns active monsters for the fight' do
      result = service.monsters_in_fight

      expect(result).to contain_exactly(monster1, monster2)
    end
  end

  describe '#has_active_monsters?' do
    let(:monsters_dataset) { double('Dataset') }

    context 'when there are active monsters' do
      before do
        allow(LargeMonsterInstance).to receive(:where).with(fight_id: 1, status: 'active').and_return(monsters_dataset)
        allow(monsters_dataset).to receive(:all).and_return([double('LargeMonsterInstance')])
      end

      it 'returns true' do
        expect(service.has_active_monsters?).to be true
      end
    end

    context 'when there are no active monsters' do
      before do
        allow(LargeMonsterInstance).to receive(:where).with(fight_id: 1, status: 'active').and_return(monsters_dataset)
        allow(monsters_dataset).to receive(:all).and_return([])
      end

      it 'returns false' do
        expect(service.has_active_monsters?).to be false
      end
    end
  end

  describe '#reset_monsters_for_new_round' do
    let(:monster1) { double('LargeMonsterInstance') }
    let(:monster2) { double('LargeMonsterInstance') }
    let(:monsters_dataset) { double('Dataset') }

    before do
      allow(LargeMonsterInstance).to receive(:where).with(fight_id: 1, status: 'active').and_return(monsters_dataset)
      allow(monsters_dataset).to receive(:all).and_return([monster1, monster2])
      allow(monster1).to receive(:reset_for_new_round!)
      allow(monster2).to receive(:reset_for_new_round!)
    end

    it 'resets each monster for new round' do
      expect(monster1).to receive(:reset_for_new_round!)
      expect(monster2).to receive(:reset_for_new_round!)

      service.reset_monsters_for_new_round
    end
  end
end
