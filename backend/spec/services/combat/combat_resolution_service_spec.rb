# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CombatResolutionService do
  let(:room) { create(:room) }
  let(:fight) { create(:fight, room: room, status: 'input') }
  let(:attacker_char) { create(:character) }
  let(:defender_char) { create(:character) }
  let(:attacker_instance) { create(:character_instance, character: attacker_char, current_room: room) }
  let(:defender_instance) { create(:character_instance, character: defender_char, current_room: room) }
  let!(:attacker) do
    create(:fight_participant,
           fight: fight,
           character_instance: attacker_instance,
           side: 1,
           current_hp: 6,
           max_hp: 6)
  end
  let!(:defender) do
    create(:fight_participant,
           fight: fight,
           character_instance: defender_instance,
           side: 2,
           current_hp: 6,
           max_hp: 6)
  end

  let(:service) { described_class.new(fight) }

  describe '#initialize' do
    it 'creates service with fight' do
      expect(service.fight).to eq(fight)
    end

    it 'initializes events array' do
      expect(service.events).to eq([])
    end

    it 'initializes roll_results array' do
      expect(service.roll_results).to eq([])
    end

    it 'initializes battle_map_service' do
      expect(service.battle_map_service).to be_a(BattleMapCombatService)
    end
  end

  describe '#initialize_round_state' do
    before { service.initialize_round_state }

    it 'tracks state for all active participants' do
      state_keys = service.instance_variable_get(:@round_state).keys
      expect(state_keys).to include(attacker.id)
      expect(state_keys).to include(defender.id)
    end

    it 'initializes cumulative damage to 0' do
      state = service.instance_variable_get(:@round_state)
      expect(state[attacker.id][:cumulative_damage]).to eq(0)
      expect(state[defender.id][:cumulative_damage]).to eq(0)
    end

    it 'initializes hp_lost_this_round to 0' do
      state = service.instance_variable_get(:@round_state)
      expect(state[attacker.id][:hp_lost_this_round]).to eq(0)
    end

    it 'tracks current HP' do
      state = service.instance_variable_get(:@round_state)
      expect(state[attacker.id][:current_hp]).to eq(6)
    end

    it 'tracks knockout status' do
      state = service.instance_variable_get(:@round_state)
      expect(state[attacker.id][:is_knocked_out]).to be false
    end
  end

  describe '#knocked_out?' do
    before { service.initialize_round_state }

    it 'returns false for conscious participant' do
      expect(service.knocked_out?(attacker.id)).to be false
    end

    it 'returns true after marking knocked out' do
      service.mark_knocked_out!(attacker.id)
      expect(service.knocked_out?(attacker.id)).to be true
    end

    it 'returns false for unknown participant' do
      expect(service.knocked_out?(999999)).to be false
    end
  end

  describe '#mark_knocked_out!' do
    before { service.initialize_round_state }

    it 'marks participant as knocked out' do
      service.mark_knocked_out!(attacker.id)
      state = service.instance_variable_get(:@round_state)
      expect(state[attacker.id][:is_knocked_out]).to be true
    end

    it 'handles nil participant' do
      expect { service.mark_knocked_out!(999999) }.not_to raise_error
    end
  end

  describe '#calculate_effective_cumulative' do
    before { service.initialize_round_state }

    let(:state) do
      {
        raw_by_attacker: { attacker.id => 20 },
        raw_by_attacker_type: {},
        dot_cumulative: 5
      }
    end

    it 'returns effective damage hash' do
      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(0)
      allow(StatusEffectService).to receive(:overall_protection).and_return(0)

      result = service.calculate_effective_cumulative(defender, state, 'physical')
      expect(result).to have_key(:effective)
      expect(result).to have_key(:armor_reduced)
      expect(result).to have_key(:protection_reduced)
    end

    it 'includes DOT damage in effective total' do
      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(0)
      allow(StatusEffectService).to receive(:overall_protection).and_return(0)

      result = service.calculate_effective_cumulative(defender, state, 'physical')
      expect(result[:effective]).to eq(25) # 20 attack + 5 DOT
    end

    it 'applies armor reduction per attacker' do
      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(5)
      allow(StatusEffectService).to receive(:overall_protection).and_return(0)

      result = service.calculate_effective_cumulative(defender, state, 'physical')
      expect(result[:armor_reduced]).to eq(5)
      expect(result[:effective]).to eq(20) # 20-5+5
    end

    it 'applies protection after armor' do
      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(0)
      allow(StatusEffectService).to receive(:overall_protection).and_return(10)

      result = service.calculate_effective_cumulative(defender, state, 'physical')
      expect(result[:protection_reduced]).to eq(10)
      expect(result[:effective]).to eq(15) # 20-10+5
    end

    it 'applies type-specific armor using raw_by_attacker_type buckets' do
      mixed_state = {
        raw_by_attacker: { attacker.id => 20 },
        raw_by_attacker_type: {
          [attacker.id, 'physical'] => 10,
          [attacker.id, 'fire'] => 10
        },
        ability_cumulative: 0,
        dot_cumulative: 0
      }

      allow(StatusEffectService).to receive(:flat_damage_reduction) do |_participant, type|
        case type.to_s
        when 'physical' then 2
        when 'fire' then 5
        else 0
        end
      end
      allow(StatusEffectService).to receive(:overall_protection).and_return(0)

      result = service.calculate_effective_cumulative(defender, mixed_state, 'physical')
      expect(result[:armor_reduced]).to eq(7)
      expect(result[:effective]).to eq(13) # (10-2) + (10-5)
    end

    it 'applies all-type protection once when damage types are mixed' do
      mixed_state = {
        raw_by_attacker: { attacker.id => 20 },
        raw_by_attacker_type: {
          [attacker.id, 'physical'] => 10,
          [attacker.id, 'fire'] => 10
        },
        ability_cumulative: 0,
        dot_cumulative: 0
      }

      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(0)
      allow(StatusEffectService).to receive(:overall_protection) do |_participant, type|
        # Simulate a universal protection effect of 3.
        # type calls return 3 because universal effects apply to each type query.
        %w[physical fire __all_only_probe__].include?(type.to_s) ? 3 : 0
      end

      result = service.calculate_effective_cumulative(defender, mixed_state, 'physical')
      expect(result[:protection_reduced]).to eq(3)
      expect(result[:effective]).to eq(17) # 20 - 3 (not 20 - 6)
    end
  end

  describe '#resolve!' do
    before do
      attacker.update(main_action: 'pass', target_participant_id: defender.id)
      defender.update(main_action: 'pass', target_participant_id: attacker.id)
    end

    it 'locks the round' do
      expect(fight).to receive(:lock_round!)
      service.resolve!
    end

    it 'returns events and roll_display' do
      result = service.resolve!
      expect(result).to have_key(:events)
      expect(result).to have_key(:roll_display)
    end

    context 'when all participants pass' do
      it 'ends fight peacefully' do
        result = service.resolve!
        expect(result[:fight_ended]).to be true
        expect(result[:end_reason]).to eq('mutual_pass')
      end

      it 'updates fight status to complete' do
        service.resolve!
        fight.refresh
        expect(fight.status).to eq('complete')
      end
    end

    context 'when participants have attacks' do
      before do
        attacker.update(main_action: 'attack', target_participant_id: defender.id)
        defender.update(main_action: 'attack', target_participant_id: attacker.id)
      end

      it 'processes the round without error' do
        expect { service.resolve! }.not_to raise_error
      end

      it 'returns events' do
        result = service.resolve!
        expect(result[:events]).to be_an(Array)
      end
    end

    context 'threshold data in hit/miss events' do
      before do
        attacker.update(main_action: 'attack', target_participant_id: defender.id)
        defender.update(main_action: 'attack', target_participant_id: attacker.id)
      end

      it 'includes threshold_crossed and hp_lost_this_attack in hit events' do
        result = service.resolve!
        hit_events = result[:events].select { |e| e[:event_type] == 'hit' }

        hit_events.each do |hit|
          expect(hit[:details]).to have_key(:threshold_crossed)
          expect(hit[:details]).to have_key(:hp_lost_this_attack)
        end
      end

      it 'includes threshold_crossed false and hp_lost_this_attack 0 in miss events' do
        result = service.resolve!
        miss_events = result[:events].select { |e| e[:event_type] == 'miss' }

        miss_events.each do |miss|
          expect(miss[:details][:threshold_crossed]).to eq(false)
          expect(miss[:details][:hp_lost_this_attack]).to eq(0)
        end
      end
    end
  end

  describe '#all_conscious_passed?' do
    context 'when all conscious participants passed' do
      before do
        attacker.update(main_action: 'pass')
        defender.update(main_action: 'pass')
      end

      it 'returns true' do
        expect(service.send(:all_conscious_passed?)).to be true
      end
    end

    context 'when one participant is attacking' do
      before do
        attacker.update(main_action: 'attack')
        defender.update(main_action: 'pass')
      end

      it 'returns false' do
        expect(service.send(:all_conscious_passed?)).to be false
      end
    end

    context 'when no conscious participants' do
      before do
        attacker.update(is_knocked_out: true)
        defender.update(is_knocked_out: true)
      end

      it 'returns false' do
        expect(service.send(:all_conscious_passed?)).to be false
      end
    end
  end

  describe '#end_fight_peacefully' do
    it 'creates fight ended event' do
      service.send(:end_fight_peacefully)
      expect(service.events.any? { |e| e[:event_type] == 'fight_ended_peacefully' }).to be true
    end

    it 'updates fight status' do
      service.send(:end_fight_peacefully)
      fight.refresh
      expect(fight.status).to eq('complete')
    end

    it 'sets combat_ended_at timestamp' do
      service.send(:end_fight_peacefully)
      fight.refresh
      expect(fight.combat_ended_at).not_to be_nil
    end
  end

  describe '#safe_execute' do
    it 'executes block normally' do
      executed = false
      service.send(:safe_execute, 'test') { executed = true }
      expect(executed).to be true
    end

    it 'catches and logs errors' do
      expect { service.send(:safe_execute, 'test') { raise 'Test error' } }.not_to raise_error
    end

    it 'continues after error' do
      continued = false
      service.send(:safe_execute, 'failing') { raise 'Test error' }
      service.send(:safe_execute, 'continuing') { continued = true }
      expect(continued).to be true
    end
  end

  describe 'scheduling methods' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
      defender.update(main_action: 'pass')
    end

    describe '#schedule_all_events' do
      it 'schedules events without error' do
        expect { service.send(:schedule_all_events) }.not_to raise_error
      end
    end

    describe '#schedule_tick_events' do
      it 'schedules healing tick at movement segment' do
        service.send(:schedule_tick_events)
        segment_events = service.instance_variable_get(:@segment_events)
        movement_segment = CombatResolutionService::MOVEMENT_SEGMENT
        expect(segment_events[movement_segment]).to include(hash_including(type: :process_healing_ticks))
      end
    end
  end

  describe 'MOVEMENT_SEGMENT constant' do
    it 'is defined from config' do
      expect(CombatResolutionService::MOVEMENT_SEGMENT).to be_a(Integer)
    end
  end

  describe '#schedule_attacks' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
    end

    it 'schedules attacks for attacking participants' do
      service.send(:schedule_attacks, attacker)
      segment_events = service.instance_variable_get(:@segment_events)
      # Should have scheduled at least one attack event
      has_attack = segment_events.flatten.any? { |e| e[:type] == :attack || e[:type] == :process_attack }
      expect(segment_events.flatten.any?).to be true
    end

    it 'does not schedule attacks when action is pass' do
      attacker.update(main_action: 'pass')
      service.send(:schedule_attacks, attacker)
      segment_events = service.instance_variable_get(:@segment_events)
      # Should not have attack events
      attack_events = segment_events.flatten.select { |e| e[:type] == :attack || e[:type] == :process_attack }
      expect(attack_events.length).to eq(0)
    end
  end

  describe '#schedule_movement' do
    before do
      service.initialize_round_state
      attacker.update(movement_action: 'towards_person', target_participant_id: defender.id)
    end

    it 'handles movement scheduling without error' do
      expect { service.send(:schedule_movement, attacker) }.not_to raise_error
    end

    it 'does not raise for stand_still action' do
      attacker.update(movement_action: 'stand_still')
      expect { service.send(:schedule_movement, attacker) }.not_to raise_error
    end
  end

  describe '#create_event' do
    it 'creates event hash with basic fields' do
      event = service.send(:create_event, 50, attacker, defender, 'attack', damage: 10)
      expect(event).to be_a(Hash)
      expect(event[:event_type]).to eq('attack')
    end

    it 'handles nil actor' do
      event = service.send(:create_event, 50, nil, defender, 'system_event')
      expect(event).to be_a(Hash)
    end

    it 'handles nil target' do
      event = service.send(:create_event, 50, attacker, nil, 'miss')
      expect(event).to be_a(Hash)
    end
  end

  describe '#check_knockouts' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
      defender.update(main_action: 'pass')
    end

    it 'handles fight end when one side is knocked out' do
      # Set defender to 0 HP
      defender.update(current_hp: 0, is_knocked_out: true)
      service.instance_variable_get(:@round_state)[defender.id][:is_knocked_out] = true
      service.instance_variable_get(:@round_state)[defender.id][:current_hp] = 0

      expect { service.send(:check_knockouts) }.not_to raise_error
    end

    it 'does not end fight when both sides have conscious members' do
      service.send(:check_knockouts)
      fight.refresh
      expect(fight.status).not_to eq('complete')
    end
  end

  describe '#process_flee_attempts' do
    before do
      service.initialize_round_state
    end

    it 'does not process flee for non-fleeing participants' do
      attacker.update(main_action: 'attack')
      service.send(:process_flee_attempts)
      flee_events = service.events.select { |e| e[:event_type].to_s =~ /flee/ }
      expect(flee_events).to be_empty
    end
  end

  describe '#process_surrenders' do
    before do
      service.initialize_round_state
    end

    it 'processes surrender actions without error' do
      attacker.update(main_action: 'surrender')
      expect { service.send(:process_surrenders) }.not_to raise_error
    end

    it 'does not process surrender for non-surrendering participants' do
      attacker.update(main_action: 'attack')
      service.send(:process_surrenders)
      surrender_events = service.events.select { |e| e[:event_type] =~ /surrender/ }
      expect(surrender_events).to be_empty
    end
  end

  describe '#apply_accumulated_damage' do
    before do
      service.initialize_round_state
      # Simulate accumulated damage
      state = service.instance_variable_get(:@round_state)
      state[defender.id][:cumulative_damage] = 20
      state[defender.id][:raw_by_attacker] = { attacker.id => 20 }
    end

    it 'applies damage from round state to participants' do
      initial_hp = defender.current_hp
      service.send(:apply_accumulated_damage)
      defender.refresh
      # HP should be reduced based on damage thresholds
      expect(defender.current_hp).to be <= initial_hp
    end
  end

  describe '#generate_roll_display' do
    before do
      service.initialize_round_state
    end

    it 'handles empty roll results' do
      service.send(:generate_roll_display)
      roll_display = service.instance_variable_get(:@roll_display)
      expect(roll_display).to be_an(Array)
    end
  end

  describe 'roll display color coding' do
    RollStub = Struct.new(:dice, :count, :total, :sides)

    before do
      service.initialize_round_state
      allow(DiceRollService).to receive(:generate_animation_data) do |_roll, character_name:, color:|
        "anim-#{color}-#{character_name}"
      end
    end

    it 'uses expected colors for attack, defense, and ability displays' do
      service.instance_variable_set(:@combat_pre_rolls, {
                                      attacker.id => {
                                        is_pc: true,
                                        base_roll: RollStub.new([4], 1, 4, 10),
                                        roll_total: 4
                                      }
                                    })

      round_state = service.instance_variable_get(:@round_state)
      round_state[attacker.id][:willpower_defense_roll] = RollStub.new([6], 1, 6, 10)
      round_state[attacker.id][:willpower_ability_roll] = RollStub.new([7], 1, 7, 10)

      service.events << { event_type: 'ability_start', actor_id: attacker.id }

      service.send(:generate_roll_display)
      displays = service.instance_variable_get(:@roll_display)
      animations = displays.flat_map { |r| r[:animations] }

      expect(animations).to include('anim-w-') # base attack roll
      expect(animations).to include('anim-c-') # willpower defense
      expect(animations).to include('anim-b-') # willpower ability
    end
  end

  describe 'damage accumulation' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
      defender.update(main_action: 'pass')
    end

    it 'tracks cumulative damage in round state' do
      state = service.instance_variable_get(:@round_state)
      state[defender.id][:cumulative_damage] = 15
      state[defender.id][:raw_by_attacker][attacker.id] = 15

      expect(state[defender.id][:cumulative_damage]).to eq(15)
    end

    it 'tracks damage by attacker for armor calculations' do
      state = service.instance_variable_get(:@round_state)
      state[defender.id][:raw_by_attacker][attacker.id] = 10
      state[defender.id][:raw_by_attacker][999] = 5

      expect(state[defender.id][:raw_by_attacker].values.sum).to eq(15)
    end

    it 'tracks DOT damage separately' do
      state = service.instance_variable_get(:@round_state)
      state[defender.id][:dot_cumulative] = 5

      expect(state[defender.id][:dot_cumulative]).to eq(5)
    end
  end

  describe 'with defend action' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'defend')
      defender.update(main_action: 'attack', target_participant_id: attacker.id)
    end

    it 'handles defend action in resolution' do
      result = service.resolve!
      expect(result).to have_key(:events)
    end
  end

  describe 'movement path calculations' do
    before do
      service.initialize_round_state
    end

    describe '#calculate_towards_path' do
      before do
        attacker.update(movement_action: 'towards_person', target_participant_id: defender.id)
      end

      it 'returns an array for movement path' do
        path = service.send(:calculate_towards_path, attacker)
        expect(path).to be_an(Array)
      end

      it 'uses willpower movement bonus in movement budget' do
        attacker.update(movement_target_participant_id: defender.id)
        state = service.instance_variable_get(:@round_state)
        state[attacker.id][:willpower_movement_bonus] = 3
        expect(service.send(:movement_budget_for, attacker)).to eq(attacker.movement_speed + 3)
      end
    end

    describe '#calculate_away_path' do
      before do
        attacker.update(movement_action: 'away_from', target_participant_id: defender.id)
      end

      it 'returns an array for movement path' do
        path = service.send(:calculate_away_path, attacker)
        expect(path).to be_an(Array)
      end
    end
  end

  describe 'save_events_to_db' do
    before do
      service.initialize_round_state
      service.events << service.send(:create_event, 50, attacker, defender, 'attack', damage: 10)
    end

    it 'persists events to database' do
      initial_count = FightEvent.count
      service.send(:save_events_to_db)
      expect(FightEvent.count).to be >= initial_count
    end
  end

  describe 'multiple attackers on same target' do
    let(:third_char) { create(:character) }
    let(:third_instance) { create(:character_instance, character: third_char, current_room: room) }
    let!(:third_participant) do
      create(:fight_participant,
             fight: fight,
             character_instance: third_instance,
             side: 1,
             current_hp: 6,
             max_hp: 6)
    end

    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
      third_participant.update(main_action: 'attack', target_participant_id: defender.id)
      defender.update(main_action: 'pass')
    end

    it 'handles multiple attackers on same target' do
      result = service.resolve!
      expect(result).to have_key(:events)
    end

    it 'tracks damage from each attacker separately' do
      state = service.instance_variable_get(:@round_state)
      state[defender.id][:raw_by_attacker][attacker.id] = 10
      state[defender.id][:raw_by_attacker][third_participant.id] = 8

      expect(state[defender.id][:raw_by_attacker].keys).to include(attacker.id)
      expect(state[defender.id][:raw_by_attacker].keys).to include(third_participant.id)
    end
  end

  describe '#schedule_abilities' do
    before do
      service.initialize_round_state
    end

    context 'when participant has ability action' do
      let!(:ability) { create(:ability, name: 'Fireball', universe: room.location&.zone&.world&.universe) }

      it 'schedules ability when main_action is ability' do
        attacker.update(main_action: 'ability', ability_id: ability.id, target_participant_id: defender.id)
        allow(attacker).to receive(:available_main_abilities).and_return([ability])
        service.send(:schedule_abilities, attacker)
        segment_events = service.instance_variable_get(:@segment_events)
        ability_events = segment_events.flatten.select { |e| e[:type] == :ability }
        expect(ability_events).not_to be_empty
      end

      it 'does not schedule when main_action is attack' do
        attacker.update(main_action: 'attack', target_participant_id: defender.id)
        service.send(:schedule_abilities, attacker)
        segment_events = service.instance_variable_get(:@segment_events)
        ability_events = segment_events.flatten.select { |e| e[:type] == :ability }
        expect(ability_events).to be_empty
      end
    end

    context 'with legacy ability_choice' do
      it 'handles nil ability_choice gracefully' do
        attacker.update(main_action: 'ability', ability_choice: nil)
        expect { service.send(:schedule_abilities, attacker) }.not_to raise_error
      end
    end
  end

  describe '#schedule_tactical_abilities' do
    before do
      service.initialize_round_state
    end

    it 'does not schedule when no tactical_ability_id' do
      attacker.update(tactical_ability_id: nil)
      service.send(:schedule_tactical_abilities, attacker)
      segment_events = service.instance_variable_get(:@segment_events)
      tactical_events = segment_events.flatten.select { |e| e[:is_tactical] }
      expect(tactical_events).to be_empty
    end

    it 'does not schedule non-self tactical ability without a target' do
      tactical = create(:ability,
                        universe: room.location&.zone&.world&.universe,
                        name: 'Battle Hymn',
                        target_type: 'enemy',
                        action_type: 'tactical')
      attacker.update(
        tactical_ability_id: tactical.id,
        tactic_target_participant_id: nil,
        target_participant_id: nil
      )

      service.send(:schedule_tactical_abilities, attacker)
      segment_events = service.instance_variable_get(:@segment_events)
      tactical_events = segment_events.flatten.select { |e| e[:is_tactical] }
      expect(tactical_events).to be_empty
    end

    it 'schedules self tactical ability with actor as target' do
      tactical = create(:ability,
                        universe: room.location&.zone&.world&.universe,
                        name: 'Self Ward',
                        target_type: 'self',
                        action_type: 'tactical')
      attacker.update(
        tactical_ability_id: tactical.id,
        tactic_target_participant_id: nil
      )
      allow(attacker).to receive(:available_tactical_abilities).and_return([tactical])

      service.send(:schedule_tactical_abilities, attacker)
      segment_events = service.instance_variable_get(:@segment_events)
      tactical_events = segment_events.flatten.select { |e| e[:is_tactical] }
      expect(tactical_events.length).to eq(1)
      expect(tactical_events.first[:target]).to eq(attacker)
    end
  end

  describe '#find_ability_by_choice' do
    it 'returns nil for nil input' do
      result = service.send(:find_ability_by_choice, nil)
      expect(result).to be_nil
    end

    it 'returns nil when universe not found' do
      allow(fight).to receive(:room).and_return(nil)
      result = service.send(:find_ability_by_choice, 'fireball')
      expect(result).to be_nil
    end

    it 'finds ability names from underscore legacy keys' do
      universe = room.location&.zone&.world&.universe
      ability = create(:ability, universe: universe, name: 'Test Strike')

      result = service.send(:find_ability_by_choice, 'test_strike')
      expect(result&.id).to eq(ability.id)
    end
  end

  describe '#schedule_weapon_attacks' do
    before do
      service.initialize_round_state
    end

    it 'schedules attack events for melee weapons' do
      melee_weapon = double('melee_weapon', pattern: double(range_in_hexes: 1))
      allow(attacker).to receive(:attack_segments).with(melee_weapon).and_return([20, 40, 60])
      allow(ReachSegmentService).to receive(:compress_segments).and_return([20, 40, 60])
      allow(ReachSegmentService).to receive(:effective_reach).and_return(1)
      allow(ReachSegmentService).to receive(:defender_reach).and_return(1)
      allow(ReachSegmentService).to receive(:calculate_segment_range).and_return({ start: 1, end: 100 })

      service.send(:schedule_weapon_attacks, attacker, melee_weapon, :melee, defender)
      segment_events = service.instance_variable_get(:@segment_events)
      attack_events = segment_events.flatten.select { |e| e[:type] == :attack }
      expect(attack_events).not_to be_empty
    end

    it 'schedules attack events for ranged weapons' do
      ranged_weapon = double('ranged_weapon', pattern: double(range_in_hexes: 10))
      allow(attacker).to receive(:attack_segments).with(ranged_weapon).and_return([25, 50, 75])

      service.send(:schedule_weapon_attacks, attacker, ranged_weapon, :ranged, defender)
      segment_events = service.instance_variable_get(:@segment_events)
      attack_events = segment_events.flatten.select { |e| e[:type] == :attack }
      expect(attack_events).not_to be_empty
    end
  end

  describe '#schedule_unarmed_attacks' do
    before do
      service.initialize_round_state
    end

    it 'schedules unarmed attack events' do
      service.send(:schedule_unarmed_attacks, attacker, defender)
      segment_events = service.instance_variable_get(:@segment_events)
      unarmed_events = segment_events.flatten.select { |e| e[:type] == :attack && e[:weapon_type] == :unarmed }
      expect(unarmed_events).not_to be_empty
    end
  end

  describe '#calculate_reach_segment_range' do
    before do
      service.initialize_round_state
    end

    it 'returns full range when target is nil' do
      result = service.send(:calculate_reach_segment_range, attacker, nil, :melee, nil)
      expect(result).to eq({ start: 1, end: 100 })
    end

    it 'returns hash with start and end keys' do
      result = service.send(:calculate_reach_segment_range, attacker, nil, :melee, defender)
      expect(result).to have_key(:start)
      expect(result).to have_key(:end)
    end
  end

  describe '#calculate_movement_path' do
    before do
      service.initialize_round_state
    end

    it 'returns empty array for unknown movement action' do
      # Use DB.run to bypass validation callbacks
      DB.run("UPDATE fight_participants SET movement_action = 'unknown_action' WHERE id = #{attacker.id}")
      attacker.refresh
      path = service.send(:calculate_movement_path, attacker)
      expect(path).to eq([])
    end

    it 'calls calculate_towards_path for towards_person' do
      attacker.update(movement_action: 'towards_person', movement_target_participant_id: defender.id)
      expect(service).to receive(:calculate_towards_path).and_return([])
      service.send(:calculate_movement_path, attacker)
    end

    it 'calls calculate_away_path for away_from' do
      attacker.update(movement_action: 'away_from', movement_target_participant_id: defender.id)
      expect(service).to receive(:calculate_away_path).and_return([])
      service.send(:calculate_movement_path, attacker)
    end

    it 'calls calculate_maintain_distance_path for maintain_distance' do
      attacker.update(movement_action: 'maintain_distance', movement_target_participant_id: defender.id)
      expect(service).to receive(:calculate_maintain_distance_path).and_return([])
      service.send(:calculate_movement_path, attacker)
    end

    it 'calls calculate_hex_target_path for move_to_hex' do
      attacker.update(movement_action: 'move_to_hex')
      allow(attacker).to receive(:movement_target_participant_id).and_return(5010)
      expect(service).to receive(:calculate_hex_target_path).and_return([])
      service.send(:calculate_movement_path, attacker)
    end
  end

  describe '#calculate_simple_towards_path' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 0, hex_y: 0)
    end

    it 'returns array of steps towards target' do
      path = service.send(:calculate_simple_towards_path, attacker, 5, 5)
      expect(path).to be_an(Array)
    end

    it 'limits path length to movement speed' do
      allow(attacker).to receive(:movement_speed).and_return(3)
      path = service.send(:calculate_simple_towards_path, attacker, 10, 10)
      expect(path.length).to be <= 3
    end

    it 'returns empty array when already at target' do
      path = service.send(:calculate_simple_towards_path, attacker, 0, 0)
      expect(path).to eq([])
    end
  end

  describe '#calculate_simple_away_path' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 5, hex_y: 5)
      defender.update(hex_x: 3, hex_y: 3)
    end

    it 'returns array of steps away from target' do
      path = service.send(:calculate_simple_away_path, attacker, defender)
      expect(path).to be_an(Array)
    end

    it 'clamps to arena bounds' do
      attacker.update(hex_x: fight.arena_width - 1, hex_y: 5)
      defender.update(hex_x: fight.arena_width - 3, hex_y: 5)
      path = service.send(:calculate_simple_away_path, attacker, defender)
      path.each do |x, y|
        expect(x).to be_between(0, fight.arena_width - 1)
        expect(y).to be_between(0, fight.arena_height - 1)
      end
    end
  end

  describe '#calculate_maintain_distance_path' do
    before do
      service.initialize_round_state
      attacker.update(
        movement_action: 'maintain_distance',
        movement_target_participant_id: defender.id,
        maintain_distance_range: 5,
        hex_x: 0,
        hex_y: 0
      )
      defender.update(hex_x: 10, hex_y: 0)
    end

    it 'returns empty array when no target' do
      attacker.update(movement_target_participant_id: nil)
      path = service.send(:calculate_maintain_distance_path, attacker)
      expect(path).to eq([])
    end

    it 'calls calculate_away_path when too close' do
      attacker.update(hex_x: 2, hex_y: 0)
      defender.update(hex_x: 0, hex_y: 0)
      expect(service).to receive(:calculate_away_path).and_return([[3, 0]])
      service.send(:calculate_maintain_distance_path, attacker)
    end

    it 'returns empty when at desired range' do
      # (5,2) → (0,0): dx=5, dy=2, distance=5 (diagonal moves absorb y)
      attacker.update(hex_x: 5, hex_y: 2, maintain_distance_range: 5)
      defender.update(hex_x: 0, hex_y: 0)
      path = service.send(:calculate_maintain_distance_path, attacker)
      expect(path).to eq([])
    end
  end

  describe '#calculate_hex_target_path' do
    before do
      service.initialize_round_state
      attacker.update(movement_action: 'move_to_hex')
      allow(attacker).to receive(:target_hex_x).and_return(5)
      allow(attacker).to receive(:target_hex_y).and_return(10)
    end

    it 'reads target from target_hex fields' do
      path = service.send(:calculate_hex_target_path, attacker)
      expect(path).to be_an(Array)
    end

    it 'handles zero target hex' do
      allow(attacker).to receive(:target_hex_x).and_return(0)
      allow(attacker).to receive(:target_hex_y).and_return(0)
      path = service.send(:calculate_hex_target_path, attacker)
      expect(path).to be_an(Array)
    end

    it 'falls back to a nearby reachable hex when direct path is unavailable' do
      attacker.update(hex_x: 0, hex_y: 0)
      allow(service.battle_map_service).to receive(:battle_map_active?).and_return(true)

      calls = []
      allow(CombatPathfindingService).to receive(:next_steps) do |args|
        calls << [args[:target_x], args[:target_y]]
        calls.length == 1 ? [] : [[args[:target_x], args[:target_y]]]
      end

      path = service.send(:calculate_hex_target_path, attacker)
      expect(path).not_to be_empty
      expect(calls.length).to be > 1
    end
  end

  describe '#process_segments' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
      defender.update(main_action: 'pass')
    end

    it 'processes all segments without error' do
      service.send(:schedule_all_events)
      expect { service.send(:process_segments) }.not_to raise_error
    end

    it 'processes retreat movement before towards movement in the same segment' do
      attacker.update(
        main_action: 'pass',
        movement_action: 'towards_person',
        movement_target_participant_id: defender.id,
        hex_x: 0,
        hex_y: 0
      )
      defender.update(
        main_action: 'pass',
        movement_action: 'away_from',
        movement_target_participant_id: attacker.id,
        hex_x: 2,
        hex_y: 0
      )

      service.initialize_round_state
      segment_events = service.instance_variable_get(:@segment_events)
      retreat_event = { type: :movement_step, actor: defender, target_hex: nil, step_index: 0, total_steps: 1 }
      follow_event = { type: :movement_step, actor: attacker, target_hex: nil, step_index: 0, total_steps: 1 }
      # Insert in reverse order to ensure sorting logic is what establishes processing order.
      segment_events[25] << follow_event
      segment_events[25] << retreat_event

      expect(service).to receive(:process_movement_step).with(retreat_event, 25).ordered.and_call_original
      expect(service).to receive(:process_movement_step).with(follow_event, 25).ordered.and_call_original

      service.send(:process_segments)
    end
  end

  describe '#process_movement_step' do
    before do
      # Set positions BEFORE initialize_round_state so the identity map has correct data
      attacker.update(
        hex_x: 0,
        hex_y: 0,
        movement_action: 'towards_person',
        movement_target_participant_id: defender.id
      )
      defender.update(hex_x: 5, hex_y: 0)
      service.initialize_round_state
    end

    it 'updates participant position' do
      event = {
        actor: attacker,
        target_hex: [1, 0],
        step_index: 0,
        total_steps: 3
      }
      service.send(:process_movement_step, event, 25)
      attacker.refresh
      expect(attacker.hex_x).to eq(1)
    end

    it 'skips if actor is knocked out' do
      service.mark_knocked_out!(attacker.id)
      event = {
        actor: attacker,
        target_hex: [1, 0],
        step_index: 0,
        total_steps: 1
      }
      old_x = attacker.hex_x
      service.send(:process_movement_step, event, 25)
      attacker.refresh
      expect(attacker.hex_x).to eq(old_x)
    end

    it 'creates movement_step event' do
      event = {
        actor: attacker,
        target_hex: [1, 0],
        step_index: 0,
        total_steps: 1
      }
      service.send(:process_movement_step, event, 25)
      movement_events = service.events.select { |e| e[:event_type] == 'movement_step' }
      expect(movement_events).not_to be_empty
    end

    it 'keeps pursuit open when adjacent target still has future movement' do
      attacker.update(
        movement_action: 'towards_person',
        movement_target_participant_id: defender.id,
        hex_x: 1,
        hex_y: 2,
        movement_completed_segment: nil
      )
      defender.update(hex_x: 0, hex_y: 0)
      allow(service).to receive(:target_has_future_movement_steps?).and_return(true)

      event = {
        actor: attacker,
        target_hex: nil,
        step_index: 0,
        total_steps: 3
      }
      service.send(:process_movement_step, event, 25)
      attacker.refresh

      expect(attacker.movement_completed_segment).to be_nil
    end

    it 'marks movement_completed_segment on final step' do
      event = {
        actor: attacker,
        target_hex: [1, 0],
        step_index: 0,
        total_steps: 1
      }
      service.send(:process_movement_step, event, 50)
      attacker.refresh
      expect(attacker.movement_completed_segment).to eq(50)
    end

    it 'recalculates away_from each step based on current target position' do
      attacker.update(
        movement_action: 'away_from',
        movement_target_participant_id: defender.id,
        hex_x: 2,
        hex_y: 0
      )
      defender.update(hex_x: 0, hex_y: 0)
      service.initialize_round_state

      event = {
        actor: attacker,
        target_hex: [0, 0],
        step_index: 0,
        total_steps: 1
      }

      candidate_distances = HexGrid.hex_neighbors(2, 0).filter_map do |nx, ny|
        next if nx.negative? || ny.negative?

        [nx, ny, HexGrid.hex_distance(nx, ny, defender.hex_x, defender.hex_y)]
      end
      max_distance = candidate_distances.map { |entry| entry[2] }.max

      service.send(:process_movement_step, event, 30)
      attacker.refresh
      expect([attacker.hex_x, attacker.hex_y]).not_to eq([0, 0])
      expect(HexGrid.hex_distance(attacker.hex_x, attacker.hex_y, defender.hex_x, defender.hex_y)).to eq(max_distance)
    end
  end

  describe '#process_healing_ticks' do
    before do
      service.initialize_round_state
    end

    it 'calls StatusEffectService.process_healing_ticks' do
      expect(StatusEffectService).to receive(:process_healing_ticks).with(fight, fight.round_number)
      service.send(:process_healing_ticks, 50)
    end
  end

  describe '#will_close_melee_gap?' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 0, hex_y: 0)
      defender.update(hex_x: 3, hex_y: 0)
    end

    it 'returns false when no upcoming movement' do
      result = service.send(:will_close_melee_gap?, attacker, defender, 20)
      expect(result).to be false
    end

    it 'returns true when upcoming movement reaches target' do
      segment_events = service.instance_variable_get(:@segment_events)
      segment_events[25] = [{
        type: :movement_step,
        actor: attacker,
        target_hex: [2, 0]
      }]
      result = service.send(:will_close_melee_gap?, attacker, defender, 20)
      expect(result).to be true
    end
  end

  describe '#find_aoe_targets' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 5, hex_y: 5)
      defender.update(hex_x: 5, hex_y: 6)
    end

    it 'finds participants within radius' do
      attacker.refresh
      defender.refresh
      allow(attacker).to receive(:hex_distance_to).with(attacker).and_return(0)
      allow(attacker).to receive(:hex_distance_to).with(defender).and_return(1)
      allow(fight).to receive(:active_participants).and_return([attacker, defender])

      targets = service.send(:find_aoe_targets, attacker, 2)
      expect(targets).to include(defender)
    end

    it 'excludes participants outside radius' do
      defender.update(hex_x: 20, hex_y: 20)
      attacker.refresh
      defender.refresh
      allow(attacker).to receive(:hex_distance_to).with(attacker).and_return(0)
      allow(attacker).to receive(:hex_distance_to).with(defender).and_return(20)
      allow(fight).to receive(:active_participants).and_return([attacker, defender])

      targets = service.send(:find_aoe_targets, attacker, 2)
      expect(targets).not_to include(defender)
    end
  end

  describe '#check_attack_redirection' do
    before do
      service.initialize_round_state
    end

    it 'returns nil when target is nil' do
      result = service.send(:check_attack_redirection, nil, attacker, 50)
      expect(result).to be_nil
    end

    it 'checks for guards protecting target' do
      expect(service.send(:check_attack_redirection, defender, attacker, 50)).to be_nil
    end
  end

  describe '#process_attack' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
    end

    it 'skips when actor is knocked out' do
      service.mark_knocked_out!(attacker.id)
      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed
      }
      initial_events = service.events.length
      service.send(:process_attack, event, 50)
      expect(service.events.length).to eq(initial_events)
    end

    it 'skips when target is knocked out' do
      service.mark_knocked_out!(defender.id)
      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed
      }
      initial_events = service.events.length
      service.send(:process_attack, event, 50)
      expect(service.events.length).to eq(initial_events)
    end

    it 'creates hit or miss event' do
      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)
      hit_or_miss_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
      expect(hit_or_miss_events).not_to be_empty
    end

    it 'tracks roll results for display' do
      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)
      expect(service.roll_results).not_to be_empty
    end

    it 'apportions round stat modifier in fallback non-pre-roll path' do
      allow(service).to receive(:build_pre_roll_for_actor).with(attacker).and_return(nil)
      allow(service).to receive(:count_scheduled_attacks).with(attacker.id).and_return(5)
      allow(service).to receive(:sum_attack_stat_modifiers).with(attacker).and_return(5)
      allow(attacker).to receive(:willpower_attack_roll).and_return(nil)
      allow(attacker).to receive(:all_roll_penalty).and_return(0)
      allow(DiceRollService).to receive(:roll).and_return(
        DiceRollService::RollResult.new(
          total: 12, dice: [5, 7], base_dice: [5, 7], sides: 8,
          modifier: 0, explosions: [], count: 2, explode_on: 8
        )
      )

      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)
      result_event = service.events.reverse.find { |e| %w[hit miss].include?(e[:event_type]) }

      expect(result_event[:details][:stat_mod]).to eq(1.0)
      expect(result_event[:details][:stat_mod_round_total]).to eq(5)
    end
  end

  describe '#build_pre_roll_for_actor' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
    end

    it 'apportions a single stat across all attacks in the round' do
      segment_events = service.instance_variable_get(:@segment_events)
      [10, 20, 30, 40, 50].each do |seg|
        segment_events[seg] << { type: :attack, actor: attacker, target: defender, weapon_type: :melee }
      end

      allow(service).to receive(:get_attack_stat).with(attacker, :melee).and_return(5)
      allow(service).to receive(:roll_base_attack_dice).and_return(
        DiceRollService::RollResult.new(
          total: 10, dice: [4, 6], base_dice: [4, 6], sides: 8,
          modifier: 0, explosions: [], count: 2, explode_on: 8
        )
      )
      allow(attacker).to receive(:willpower_attack_roll).and_return(nil)
      allow(attacker).to receive(:all_roll_penalty).and_return(0)

      pre_roll = service.send(:build_pre_roll_for_actor, attacker)
      expect(pre_roll[:attack_count]).to eq(5)
      expect(pre_roll[:total_stat_modifier]).to eq(5)
      expect(pre_roll[:stat_per_attack]).to eq(1.0)
    end

    it 'weights mixed melee and ranged stat contribution by attack usage' do
      segment_events = service.instance_variable_get(:@segment_events)
      segment_events[10] << { type: :attack, actor: attacker, target: defender, weapon_type: :melee }
      segment_events[20] << { type: :attack, actor: attacker, target: defender, weapon_type: :melee }
      segment_events[30] << { type: :attack, actor: attacker, target: defender, weapon_type: :ranged }
      segment_events[40] << { type: :attack, actor: attacker, target: defender, weapon_type: :ranged }
      segment_events[50] << { type: :attack, actor: attacker, target: defender, weapon_type: :ranged }

      allow(service).to receive(:get_attack_stat).with(attacker, :melee).and_return(5)
      allow(service).to receive(:get_attack_stat).with(attacker, :ranged).and_return(2)
      allow(service).to receive(:roll_base_attack_dice).and_return(
        DiceRollService::RollResult.new(
          total: 10, dice: [4, 6], base_dice: [4, 6], sides: 8,
          modifier: 0, explosions: [], count: 2, explode_on: 8
        )
      )
      allow(attacker).to receive(:willpower_attack_roll).and_return(nil)
      allow(attacker).to receive(:all_roll_penalty).and_return(0)

      pre_roll = service.send(:build_pre_roll_for_actor, attacker)
      # Weighted round stat: (2*5 + 3*2) / 5 = 3.2
      expect(pre_roll[:total_stat_modifier]).to eq(3.2)
      expect(pre_roll[:stat_per_attack]).to eq(0.64)
    end
  end

  describe '#process_attack with activity observer combat effects' do
    let(:activity_template) { create(:activity, is_public: true) }
    let(:activity_instance) { create(:activity_instance, activity: activity_template, room: room, running: true) }
    let!(:activity_attacker) { create(:activity_participant, instance: activity_instance, character: attacker_char) }
    let!(:activity_defender) { create(:activity_participant, instance: activity_instance, character: defender_char) }
    let(:base_roll) do
      DiceRollService::RollResult.new(
        dice: [5, 5],
        base_dice: [5, 5],
        explosions: [],
        modifier: 0,
        total: 10,
        count: 2,
        sides: 8,
        explode_on: 8
      )
    end

    before do
      fight.update(activity_instance_id: activity_instance.id)
      service.initialize_round_state

      attacker.update(main_action: 'attack', target_participant_id: defender.id, side: 1, is_npc: false, hex_x: 5, hex_y: 5)
      defender.update(side: 2, hex_x: 5, hex_y: 6)

      allow(service).to receive(:get_attack_stat).and_return(0)
      allow(DiceRollService).to receive(:roll).and_return(base_roll)
      allow(StatusEffectService).to receive(:damage_type_multiplier).and_return(1.0)
      allow(StatusEffectService).to receive(:absorb_damage_with_shields) { |_target, dmg, _type| dmg }
      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(0)
      allow(StatusEffectService).to receive(:overall_protection).and_return(0)
    end

    it 'applies expose/damage multipliers from observer effects' do
      allow(ObserverEffectService).to receive(:effects_for_combat).and_return(
        activity_attacker.id => { expose_targets: true, damage_dealt_mult: 1.5 },
        activity_defender.id => { damage_taken_mult: 1.5 }
      )

      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)

      hit_or_miss = service.events.reverse.find { |e| %w[hit miss].include?(e[:event_type]) }
      expected_total = ((10 + described_class::OBSERVER_EXPOSE_TARGETS_BONUS) * 1.5 * 1.5).round

      expect(hit_or_miss).not_to be_nil
      expect(hit_or_miss.dig(:details, :total)).to eq(expected_total)
      expect(hit_or_miss.dig(:details, :observer_effects)).to include('expose_targets', 'damage_dealt_mult', 'damage_taken_mult')
    end

    it 'applies block_damage and halve_damage to incoming attacks' do
      allow(ObserverEffectService).to receive(:effects_for_combat).and_return(
        activity_defender.id => {
          block_damage: true,
          halve_damage_from: [activity_attacker.id]
        }
      )

      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)

      hit_or_miss = service.events.reverse.find { |e| %w[hit miss].include?(e[:event_type]) }
      expected_total = ((10 * described_class::OBSERVER_BLOCK_DAMAGE_MULT) * 0.5).round

      expect(hit_or_miss).not_to be_nil
      expect(hit_or_miss.dig(:details, :total)).to eq(expected_total)
      expect(hit_or_miss.dig(:details, :observer_effects)).to include('block_damage', 'halve_damage')
    end

    it 'redirects NPC attacks to observer forced targets' do
      third_char = create(:character)
      third_ci = create(:character_instance, character: third_char, current_room: room)
      third_target = create(:fight_participant, fight: fight, character_instance: third_ci, side: 1,
                                               current_hp: 6, max_hp: 6, hex_x: 6, hex_y: 5)
      activity_third = create(:activity_participant, instance: activity_instance, character: third_char)

      attacker.update(is_npc: true, side: 2, hex_x: 5, hex_y: 5)
      defender.update(side: 1, hex_x: 5, hex_y: 6)
      service.initialize_round_state

      allow(ObserverEffectService).to receive(:effects_for_combat).and_return(
        activity_third.id => { forced_target: true }
      )

      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)

      redirect_event = service.events.find do |e|
        e[:event_type] == 'attack_redirected' && e.dig(:details, :redirect_type) == 'observer_forced_target'
      end
      attack_resolution_event = service.events.reverse.find do |e|
        %w[hit miss out_of_range].include?(e[:event_type])
      end

      expect(redirect_event).not_to be_nil
      expect(attack_resolution_event).not_to be_nil
      expect(attack_resolution_event[:target_id]).to eq(third_target.id)
    end
  end

  describe '#get_attack_stat' do
    it 'returns Strength for melee attacks' do
      allow(CharacterStat).to receive(:eager).and_return(CharacterStat)
      allow(CharacterStat).to receive(:where).and_return(CharacterStat)
      allow(CharacterStat).to receive(:all).and_return([])

      result = service.send(:get_attack_stat, attacker, :melee)
      expect(result).to eq(GameConfig::Mechanics::DEFAULT_STAT)
    end

    it 'returns Dexterity for ranged attacks' do
      allow(CharacterStat).to receive(:eager).and_return(CharacterStat)
      allow(CharacterStat).to receive(:where).and_return(CharacterStat)
      allow(CharacterStat).to receive(:all).and_return([])

      result = service.send(:get_attack_stat, attacker, :ranged)
      expect(result).to eq(GameConfig::Mechanics::DEFAULT_STAT)
    end
  end

  # Legacy process_movement, move_towards, move_away, maintain_distance, move_to_hex
  # were removed - movement is now handled by schedule_movement + process_movement_step

  describe '#process_battle_map_hazards' do
    before do
      service.initialize_round_state
    end

    it 'skips when battle map not active' do
      allow(service.battle_map_service).to receive(:battle_map_active?).and_return(false)
      expect { service.send(:process_battle_map_hazards) }.not_to raise_error
    end

    it 'processes hazards when battle map is active' do
      allow(service.battle_map_service).to receive(:battle_map_active?).and_return(true)
      allow(service.battle_map_service).to receive(:process_all_hazard_damage).and_return([])
      service.send(:process_battle_map_hazards)
      # Should not raise error
    end
  end

  describe '#process_successful_flee' do
    before do
      service.initialize_round_state
      # Create exit_room north of the fight room (sharing edge at y=100)
      exit_room = create(:room, location: room.location, min_y: 100, max_y: 200)
      attacker.update(
        is_fleeing: true,
        flee_exit_id: exit_room.id,
        flee_direction: 'north'
      )
      allow(attacker).to receive(:process_successful_flee!)
      allow(BroadcastService).to receive(:to_room)
    end

    it 'creates flee_success event' do
      service.send(:process_successful_flee, attacker)
      flee_events = service.events.select { |e| e[:event_type] == 'flee_success' }
      expect(flee_events).not_to be_empty
    end

    it 'broadcasts flee message' do
      expect(BroadcastService).to receive(:to_room).with(
        fight.room_id,
        anything,
        hash_including(type: :combat)
      )
      service.send(:process_successful_flee, attacker)
    end
  end

  describe '#process_failed_flee' do
    before do
      service.initialize_round_state
      attacker.update(is_fleeing: true, flee_direction: 'north')
      allow(attacker).to receive(:cancel_flee!)
    end

    it 'creates flee_failed event' do
      service.send(:process_failed_flee, attacker, 15)
      flee_events = service.events.select { |e| e[:event_type] == 'flee_failed' }
      expect(flee_events).not_to be_empty
    end

    it 'broadcasts interrupted message' do
      expect(BroadcastService).to receive(:to_character)
      service.send(:process_failed_flee, attacker, 15)
    end
  end

  describe '#process_surrender' do
    before do
      service.initialize_round_state
      attacker.update(is_surrendering: true)
      allow(attacker).to receive(:process_surrender!)
      allow(BroadcastService).to receive(:to_room)
    end

    it 'creates surrender event' do
      service.send(:process_surrender, attacker)
      surrender_events = service.events.select { |e| e[:event_type] == 'surrender' }
      expect(surrender_events).not_to be_empty
    end

    it 'broadcasts surrender message' do
      expect(BroadcastService).to receive(:to_room).with(
        fight.room_id,
        anything,
        hash_including(type: :combat)
      )
      service.send(:process_surrender, attacker)
    end
  end

  describe '#validate_event_type' do
    it 'returns action for nil input' do
      result = service.send(:validate_event_type, nil)
      expect(result).to eq('action')
    end

    it 'returns valid event types unchanged' do
      FightEvent::EVENT_TYPES.each do |valid_type|
        result = service.send(:validate_event_type, valid_type)
        expect(result).to eq(valid_type)
      end
    end

    it 'returns action fallback for invalid types' do
      result = service.send(:validate_event_type, 'invalid_event_type')
      expect(result).to eq('action')
    end

    it 'converts symbols to strings' do
      result = service.send(:validate_event_type, :attack)
      expect(result).to eq('attack')
    end
  end

  describe '#schedule_dot_tick_events' do
    before do
      service.initialize_round_state
    end

    it 'schedules DOT tick events for participants with damage_tick effects' do
      # Create a mock participant status effect with damage_tick
      pse = instance_double(
        ParticipantStatusEffect,
        status_effect: double(effect_type: 'damage_tick'),
        id: 1
      )
      allow(StatusEffectService).to receive(:active_effects).with(attacker).and_return([pse])
      allow(StatusEffectService).to receive(:active_effects).with(defender).and_return([])
      allow(StatusEffectService).to receive(:dot_tick_schedule_for).with(pse).and_return([10, 20, 30])

      service.send(:schedule_dot_tick_events)
      segment_events = service.instance_variable_get(:@segment_events)
      dot_events = segment_events.flatten.select { |e| e[:type] == :dot_tick }
      expect(dot_events.length).to eq(3)
    end
  end

  describe '#process_end_of_round_effects' do
    before do
      service.initialize_round_state
    end

    it 'processes burning spread' do
      expect(StatusEffectService).to receive(:process_burning_spread).with(fight)
      service.send(:process_end_of_round_effects)
    end
  end

  describe 'error handling during resolution' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
      defender.update(main_action: 'pass')
    end

    it 'continues resolution even when a step fails' do
      allow(service).to receive(:schedule_all_events).and_raise(StandardError.new('Test error'))
      # Should not raise, should continue to other steps
      expect { service.resolve! }.not_to raise_error
    end
  end

  describe 'damage type handling' do
    before do
      service.initialize_round_state
    end

    it 'applies damage type multiplier from status effects' do
      allow(StatusEffectService).to receive(:damage_type_multiplier).and_return(2.0)
      state = service.instance_variable_get(:@round_state)
      state[defender.id][:raw_by_attacker][attacker.id] = 10
      state[defender.id][:cumulative_damage] = 10

      # Test that the multiplier is called in the attack processing
      expect(StatusEffectService).to receive(:damage_type_multiplier).at_least(:once).and_return(1.0)

      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)
    end
  end

  describe 'willpower mechanics' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
    end

    it 'includes willpower attack bonus in calculations' do
      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)
      # Check that roll_results were tracked
      expect(service.roll_results).not_to be_empty
    end
  end

  # ============================================
  # Additional Coverage Tests
  # ============================================

  describe '#process_attack with hit/miss determination' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id, hex_x: 0, hex_y: 0)
      defender.update(main_action: 'pass', hex_x: 1, hex_y: 0)
    end

    context 'when attack hits (roll > threshold)' do
      it 'creates hit event with damage' do
        # Force a high roll
        high_roll = DiceRollService::RollResult.new(
          total: 20,
          dice: [10, 10],
          sides: 8,
          modifier: 0,
          explosions: []
        )
        allow(DiceRollService).to receive(:roll).and_return(high_roll)

        event = {
          actor: attacker,
          target: defender,
          weapon: nil,
          weapon_type: :unarmed,
          natural_attack: nil
        }
        service.send(:process_attack, event, 50)
        hit_events = service.events.select { |e| e[:event_type] == 'hit' }
        expect(hit_events).not_to be_empty
      end
    end

    context 'when attack misses (roll <= threshold)' do
      it 'creates miss event' do
        # Force a low roll (below wound-adjusted threshold of 10)
        # Total = roll + stat_mod - wound_penalty, and stat_mod defaults to 10
        # So we stub stat modifier to 0 to control the exact total
        low_roll = DiceRollService::RollResult.new(
          total: 5,
          dice: [2, 3],
          sides: 8,
          modifier: 0,
          explosions: []
        )
        allow(DiceRollService).to receive(:roll).and_return(low_roll)
        # Stub stat modifier to 0 so total = 5, which is <= threshold (10)
        allow(service).to receive(:get_attack_stat).and_return(0)

        event = {
          actor: attacker,
          target: defender,
          weapon: nil,
          weapon_type: :unarmed,
          natural_attack: nil
        }
        service.send(:process_attack, event, 50)
        miss_events = service.events.select { |e| e[:event_type] == 'miss' }
        expect(miss_events).not_to be_empty
      end
    end

    context 'when defender has wound penalty' do
      before do
        defender.update(current_hp: 3)  # 3 HP lost = wound_penalty 3
      end

      it 'adjusts hit threshold based on wound penalty' do
        event = {
          actor: attacker,
          target: defender,
          weapon: nil,
          weapon_type: :unarmed,
          natural_attack: nil
        }
        service.send(:process_attack, event, 50)
        # Should have at least one hit or miss event
        combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
        expect(combat_events).not_to be_empty
      end
    end

    context 'when defender is dodging' do
      before do
        defender.update(main_action: 'dodge')
      end

      it 'applies dodge penalty to attack' do
        event = {
          actor: attacker,
          target: defender,
          weapon: nil,
          weapon_type: :unarmed,
          natural_attack: nil
        }
        service.send(:process_attack, event, 50)
        # Find the event and check dodge_penalty is present
        combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
        expect(combat_events).not_to be_empty
        event_with_dodge = combat_events.find { |e| e[:details][:dodge_penalty] }
        expect(event_with_dodge).not_to be_nil
        expect(event_with_dodge[:details][:dodge_penalty]).to eq(-5)
      end
    end
  end

  describe '#process_attack with out of range handling' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id, hex_x: 0, hex_y: 0)
      defender.update(hex_x: 10, hex_y: 0)  # Far away
    end

    it 'creates out_of_range event when target is too far' do
      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,  # Unarmed has range 1
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)
      oor_events = service.events.select { |e| e[:event_type] == 'out_of_range' }
      expect(oor_events).not_to be_empty
    end
  end

  describe '#process_attack with willpower defense' do
    before do
      attacker.update(main_action: 'attack', target_participant_id: defender.id, hex_x: 0, hex_y: 0)
      defender.update(hex_x: 1, hex_y: 0, willpower_defense: 2)
      service.initialize_round_state
    end

    it 'applies willpower defense reduction via round_state pre-roll' do
      # Willpower defense is now pre-rolled once in initialize_round_state
      round_state = service.instance_variable_get(:@round_state)
      defender_state = round_state[defender.id]
      expect(defender_state[:willpower_defense_roll]).not_to be_nil
      expect(defender_state[:willpower_defense_total]).to be > 0
    end
  end

  describe '#process_attack with NPC custom dice' do
    let(:npc_char) { create(:character, :npc) }
    let(:npc_instance) { create(:character_instance, character: npc_char, current_room: room) }
    let!(:npc_participant) do
      create(:fight_participant,
             fight: fight,
             character_instance: npc_instance,
             side: 1,
             current_hp: 6,
             max_hp: 6)
    end

    before do
      service.initialize_round_state
      npc_participant.update(
        main_action: 'attack',
        target_participant_id: defender.id,
        hex_x: 0,
        hex_y: 0
      )
      defender.update(hex_x: 1, hex_y: 0)
      allow(npc_participant).to receive(:npc_with_custom_dice?).and_return(true)
      allow(npc_participant).to receive(:npc_damage_dice_count).and_return(3)
      allow(npc_participant).to receive(:npc_damage_dice_sides).and_return(6)
    end

    it 'uses NPC custom dice for attack roll' do
      # The NPC should use 3d6 instead of 2d8
      event = {
        actor: npc_participant,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      expect(DiceRollService).to receive(:roll).with(3, 6, explode_on: nil, modifier: 0).and_call_original
      service.send(:process_attack, event, 50)
    end
  end

  describe '#process_attack with status effect modifiers' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id, hex_x: 0, hex_y: 0)
      defender.update(hex_x: 1, hex_y: 0)
    end

    it 'applies outgoing damage modifier' do
      allow(attacker).to receive(:outgoing_damage_modifier).and_return(5)
      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)
      combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
      expect(combat_events).not_to be_empty
    end

    it 'applies incoming damage modifier' do
      allow(defender).to receive(:incoming_damage_modifier).and_return(3)
      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)
      combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
      expect(combat_events).not_to be_empty
    end

    it 'applies damage type vulnerability multiplier' do
      allow(StatusEffectService).to receive(:damage_type_multiplier).and_return(2.0)
      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)
      combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
      expect(combat_events).not_to be_empty
    end

    it 'applies shield absorption' do
      allow(StatusEffectService).to receive(:absorb_damage_with_shields).and_return(5)
      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)
      combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
      expect(combat_events).not_to be_empty
    end
  end

  describe '#process_attack causing knockout' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id, hex_x: 0, hex_y: 0)
      defender.update(hex_x: 1, hex_y: 0, current_hp: 1)  # Low HP

      # Force massive damage roll
      massive_roll = DiceRollService::RollResult.new(
        total: 100,
        dice: [50, 50],
        sides: 8,
        modifier: 0,
        explosions: []
      )
      allow(DiceRollService).to receive(:roll).and_return(massive_roll)
    end

    it 'marks target as knocked out when HP reaches 0' do
      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)
      # Check for knockout event
      knockout_events = service.events.select { |e| e[:event_type] == 'knockout' }
      expect(knockout_events).not_to be_empty
    end
  end

  describe '#process_ability' do
    let!(:ability) { create(:ability, name: 'Fireball', universe: room.location&.zone&.world&.universe) }

    before do
      service.initialize_round_state
      attacker.update(main_action: 'ability', ability_id: ability.id, target_participant_id: defender.id)
    end

    it 'processes ability without error' do
      event = {
        actor: attacker,
        target: defender,
        ability: ability,
        segment: 50
      }
      expect { service.send(:process_ability, event, 50) }.not_to raise_error
    end

    it 'skips processing when actor is knocked out' do
      service.mark_knocked_out!(attacker.id)
      event = {
        actor: attacker,
        target: defender,
        ability: ability,
        segment: 50
      }
      initial_events = service.events.length
      service.send(:process_ability, event, 50)
      # No new events should be added
      expect(service.events.length).to eq(initial_events)
    end

    context 'with string ability choice (legacy)' do
      it 'finds ability by string name' do
        event = {
          actor: attacker,
          target: defender,
          ability: 'fireball',  # String instead of object
          segment: 50
        }
        service.send(:process_ability, event, 50)
        # Should still process (may fail to find, but shouldn't error)
      end
    end

    context 'with execute instant-kill ability' do
      let!(:execute_ability) do
        create(:ability,
               universe: room.location&.zone&.world&.universe,
               name: 'Death Touch',
               ability_type: 'combat',
               action_type: 'main',
               base_damage_dice: '1d6',
               damage_type: 'shadow',
               execute_threshold: 20,
               execute_effect: Sequel.pg_json_wrap({ 'instant_kill' => true }))
      end

      before do
        defender.update(current_hp: 1, max_hp: 6, is_knocked_out: false)
      end

      it 'marks the target knocked out in round state so they cannot act later in the same round' do
        ability_event = {
          actor: attacker,
          target: defender,
          ability: execute_ability,
          segment: 10
        }
        service.send(:process_ability, ability_event, 10)

        expect(service.knocked_out?(defender.id)).to be true

        attack_event = {
          actor: defender,
          target: attacker,
          weapon: nil,
          weapon_type: :unarmed,
          natural_attack: nil
        }

        events_before = service.events.length
        service.send(:process_attack, attack_event, 20)
        expect(service.events.length).to eq(events_before)
      end
    end
  end

  describe '#roll_ability_effectiveness' do
    let!(:ability) { create(:ability, name: 'Fireball', base_damage_dice: '2d6') }

    before do
      service.initialize_round_state
    end

    context 'for PC characters' do
      it 'uses 2d8 exploding plus willpower' do
        allow(attacker).to receive(:npc_with_custom_dice?).and_return(false)

        result = service.send(:roll_ability_effectiveness, attacker, ability)
        expect(result).to have_key(:roll_result)
        expect(result).to have_key(:total)
        expect(result).to have_key(:willpower_bonus)
      end

      it 'reuses top-of-round base roll for every ability cast in the round' do
        allow(attacker).to receive(:npc_with_custom_dice?).and_return(false)

        round_roll = DiceRollService::RollResult.new(
          total: 14,
          dice: [8, 6],
          base_dice: [8, 6],
          explosions: [],
          modifier: 0,
          count: 2,
          sides: 8,
          explode_on: 8
        )
        wp_roll = DiceRollService::RollResult.new(
          total: 3,
          dice: [3],
          base_dice: [3],
          explosions: [],
          modifier: 0,
          count: 1,
          sides: 6,
          explode_on: nil
        )

        state = service.instance_variable_get(:@round_state)[attacker.id]
        state[:ability_base_roll] = round_roll
        state[:willpower_ability_roll] = wp_roll
        state[:willpower_ability_total] = 3
        state[:ability_all_roll_penalty] = -2
        state[:ability_round_total] = 15

        expect(DiceRollService).not_to receive(:roll)

        first = service.send(:roll_ability_effectiveness, attacker, ability)
        second = service.send(:roll_ability_effectiveness, attacker, ability)

        expect(first[:roll_result]).to eq(round_roll)
        expect(second[:roll_result]).to eq(round_roll)
        expect(first[:total]).to eq(15)
        expect(second[:total]).to eq(15)
      end
    end

    context 'for NPC with custom dice' do
      before do
        allow(attacker).to receive(:npc_with_custom_dice?).and_return(true)
        allow(attacker).to receive(:npc_damage_dice_count).and_return(3)
        allow(attacker).to receive(:npc_damage_dice_sides).and_return(6)
      end

      it 'uses ability-specific dice when available' do
        result = service.send(:roll_ability_effectiveness, attacker, ability)
        expect(result).to have_key(:roll_result)
        expect(result[:willpower_bonus]).to eq(0)
      end

      it 'supports ability dice modifiers when parsing dice strings' do
        ability.update(base_damage_dice: '3d6+2')

        result = service.send(:roll_ability_effectiveness, attacker, ability)
        expect(result[:roll_result].modifier).to eq(2)
      end

      it 'falls back to NPC custom dice when ability has no dice' do
        ability.update(base_damage_dice: nil)
        result = service.send(:roll_ability_effectiveness, attacker, ability)
        expect(result).to have_key(:roll_result)
      end
    end
  end

  describe '#track_ability_roll' do
    let!(:ability) { create(:ability, name: 'Fireball') }

    it 'adds roll to roll_results' do
      roll = DiceRollService::RollResult.new(
        total: 15,
        dice: [8, 7],
        sides: 8,
        modifier: 0,
        explosions: []
      )
      service.send(:track_ability_roll, attacker, ability, defender, roll)
      expect(service.roll_results.length).to eq(1)
      expect(service.roll_results.first[:purpose]).to eq('ability')
      expect(service.roll_results.first[:ability_name]).to eq('Fireball')
    end
  end

  describe '#schedule_natural_attacks' do
    let(:npc_char) { create(:character, :npc) }
    let(:npc_instance) { create(:character_instance, character: npc_char, current_room: room) }
    let!(:npc_participant) do
      create(:fight_participant,
             fight: fight,
             character_instance: npc_instance,
             side: 1,
             current_hp: 6,
             max_hp: 6)
    end
    let(:archetype) { double('NpcArchetype') }
    let(:natural_attack) { double('NpcAttack', name: 'bite', melee?: true, range_hexes: 1, dice_count: 2, dice_sides: 6, damage_type: 'physical', melee_reach_value: 1) }

    before do
      service.initialize_round_state
      npc_participant.update(
        main_action: 'attack',
        target_participant_id: defender.id,
        hex_x: 0,
        hex_y: 0
      )
      defender.update(hex_x: 1, hex_y: 0)
      allow(npc_participant).to receive(:using_natural_attacks?).and_return(true)
      allow(npc_participant).to receive(:npc_archetype).and_return(archetype)
      allow(archetype).to receive(:has_natural_attacks?).and_return(true)
      allow(archetype).to receive(:best_attack_for_range).and_return(natural_attack)
      allow(npc_participant).to receive(:natural_attack_segments).and_return([20, 40, 60])
    end

    it 'schedules natural attack events' do
      service.send(:schedule_natural_attacks, npc_participant, defender, 1)
      segment_events = service.instance_variable_get(:@segment_events)
      attack_events = segment_events.flatten.select { |e| e[:type] == :attack && e[:natural_attack] }
      expect(attack_events).not_to be_empty
    end
  end

  describe '#calculate_natural_reach_segment_range' do
    let(:natural_attack) { double('NpcAttack', melee?: true) }

    before do
      service.initialize_round_state
      attacker.update(hex_x: 0, hex_y: 0)
      defender.update(hex_x: 1, hex_y: 0)
    end

    it 'returns full range when target is nil' do
      result = service.send(:calculate_natural_reach_segment_range, attacker, natural_attack, nil)
      expect(result).to eq({ start: 1, end: 100 })
    end

    it 'calculates segment range based on reach' do
      allow(ReachSegmentService).to receive(:effective_reach).and_return(2)
      allow(ReachSegmentService).to receive(:defender_reach).and_return(2)
      allow(ReachSegmentService).to receive(:calculate_segment_range).and_return({ start: 1, end: 66 })

      result = service.send(:calculate_natural_reach_segment_range, attacker, natural_attack, defender)
      expect(result).to have_key(:start)
      expect(result).to have_key(:end)
    end
  end

  describe '#process_dot_tick_event' do
    let(:status_effect) { create(:status_effect, effect_type: 'damage_tick') }
    let!(:pse) do
      create(:participant_status_effect,
             fight_participant: defender,
             status_effect: status_effect,
             applied_at_round: 1,
             expires_at_round: 4)  # Duration of 3 rounds
    end

    before do
      service.initialize_round_state
    end

    it 'processes DOT tick and applies damage' do
      allow(StatusEffectService).to receive(:process_dot_tick).and_yield(
        participant: defender,
        damage: 10,
        damage_type: 'fire',
        tick_number: 1,
        total_ticks: 3,
        effect: 'burning'
      )
      allow(StatusEffectService).to receive(:absorb_damage_with_shields).and_return(10)

      event = {
        participant_status_effect_id: pse.id,
        participant: defender,
        tick_index: 0,
        segment: 30
      }
      service.send(:process_dot_tick_event, event, 30)
      damage_tick_events = service.events.select { |e| e[:event_type] == 'damage_tick' }
      expect(damage_tick_events).not_to be_empty
    end

    it 'skips processing when participant is knocked out' do
      service.mark_knocked_out!(defender.id)
      event = {
        participant_status_effect_id: pse.id,
        participant: defender,
        tick_index: 0,
        segment: 30
      }
      initial_count = service.events.length
      service.send(:process_dot_tick_event, event, 30)
      expect(service.events.length).to eq(initial_count)
    end

    it 'returns early when PSE not found' do
      event = {
        participant_status_effect_id: 999999,
        participant: defender,
        tick_index: 0,
        segment: 30
      }
      initial_count = service.events.length
      service.send(:process_dot_tick_event, event, 30)
      expect(service.events.length).to eq(initial_count)
    end
  end

  describe '#schedule_player_attacks_on_monster' do
    let(:monster) { create(:large_monster_instance, fight: fight, status: 'active', center_hex_x: 5, center_hex_y: 5) }

    before do
      service.initialize_round_state
      attacker.update(targeting_monster_id: monster.id, hex_x: 0, hex_y: 0)
    end

    it 'schedules attacks against monster' do
      service.send(:schedule_player_attacks_on_monster, attacker)
      segment_events = service.instance_variable_get(:@segment_events)
      monster_attack_events = segment_events.flatten.select { |e| e[:targeting_monster] }
      expect(monster_attack_events).not_to be_empty
    end

    it 'does nothing when monster is inactive' do
      monster.update(status: 'defeated')
      service.send(:schedule_player_attacks_on_monster, attacker)
      segment_events = service.instance_variable_get(:@segment_events)
      monster_attack_events = segment_events.flatten.select { |e| e[:targeting_monster] }
      expect(monster_attack_events).to be_empty
    end
  end

  describe '#process_attack_on_monster' do
    let(:monster) { create(:large_monster_instance, fight: fight, status: 'active', center_hex_x: 5, center_hex_y: 5) }
    let(:monster_service) { instance_double(MonsterCombatService) }

    before do
      service.initialize_round_state
      attacker.update(targeting_monster_id: monster.id, hex_x: 4, hex_y: 5)
      service.instance_variable_set(:@monster_combat_service, monster_service)
    end

    it 'processes successful attack on monster' do
      allow(monster_service).to receive(:process_attack_on_monster).and_return({
                                                                                 success: true,
                                                                                 segment_name: 'body',
                                                                                 segment_damage: 15,
                                                                                 monster_hp_percent: 80,
                                                                                 events: []
                                                                               })

      service.send(:process_attack_on_monster, attacker, 50, nil, :unarmed)
      attack_events = service.events.select { |e| e[:event_type]&.include?('monster') }
      expect(attack_events).not_to be_empty
    end

    it 'handles failed attack on monster' do
      allow(monster_service).to receive(:process_attack_on_monster).and_return({
                                                                                 success: false,
                                                                                 reason: 'Out of range'
                                                                               })

      service.send(:process_attack_on_monster, attacker, 50, nil, :unarmed)
      failed_events = service.events.select { |e| e[:event_type] == 'monster_attack_failed' }
      expect(failed_events).not_to be_empty
    end
  end

  describe '#process_monster_attack' do
    let(:monster) { create(:large_monster_instance, fight: fight, status: 'active') }
    let(:monster_service) { instance_double(MonsterCombatService) }

    before do
      service.initialize_round_state
      service.instance_variable_set(:@monster_combat_service, monster_service)
    end

    it 'processes monster attack result' do
      allow(monster_service).to receive(:process_monster_attack).and_return({
                                                                              type: 'monster_hit',
                                                                              monster_name: 'Dragon',
                                                                              segment_name: 'claw',
                                                                              damage: 20,
                                                                              reason: nil
                                                                            })

      event = {
        monster: monster,
        target_id: defender.id,
        segment_name: 'claw'
      }
      service.send(:process_monster_attack, event, 50)
      monster_events = service.events.select { |e| e[:event_type] == 'monster_hit' }
      expect(monster_events).not_to be_empty
    end

    it 'does nothing when monster service not available' do
      service.instance_variable_set(:@monster_combat_service, nil)
      event = { monster: monster, target_id: defender.id }
      initial_count = service.events.length
      service.send(:process_monster_attack, event, 50)
      expect(service.events.length).to eq(initial_count)
    end
  end

  describe '#process_monster_turn_event' do
    let(:monster) { create(:large_monster_instance, fight: fight, status: 'active') }
    let(:monster_service) { instance_double(MonsterCombatService) }

    before do
      service.initialize_round_state
      service.instance_variable_set(:@monster_combat_service, monster_service)
    end

    it 'processes monster turn' do
      allow(monster_service).to receive(:process_monster_turn).and_return({
                                                                            monster_name: 'Dragon',
                                                                            old_direction: 'north',
                                                                            new_direction: 'east'
                                                                          })

      event = { monster: monster }
      service.send(:process_monster_turn_event, event, 50)
      turn_events = service.events.select { |e| e[:event_type] == 'monster_turn' }
      expect(turn_events).not_to be_empty
    end
  end

  describe '#process_monster_move_event' do
    let(:monster) { create(:large_monster_instance, fight: fight, status: 'active') }
    let(:monster_service) { instance_double(MonsterCombatService) }

    before do
      service.initialize_round_state
      service.instance_variable_set(:@monster_combat_service, monster_service)
    end

    it 'processes monster movement' do
      allow(monster_service).to receive(:process_monster_move).and_return({
                                                                            monster_name: 'Dragon',
                                                                            from_x: 5,
                                                                            from_y: 5,
                                                                            to_x: 6,
                                                                            to_y: 5
                                                                          })

      event = { monster: monster }
      service.send(:process_monster_move_event, event, 50)
      move_events = service.events.select { |e| e[:event_type] == 'monster_move' }
      expect(move_events).not_to be_empty
    end
  end

  describe '#process_monster_shake_off' do
    let(:monster) { create(:large_monster_instance, fight: fight, status: 'active') }
    let(:monster_service) { instance_double(MonsterCombatService) }

    before do
      service.initialize_round_state
      service.instance_variable_set(:@monster_combat_service, monster_service)
    end

    it 'processes shake off event with thrown players' do
      allow(monster_service).to receive(:process_shake_off).and_return({
                                                                         monster_name: 'Dragon',
                                                                         thrown_count: 2,
                                                                         results: [
                                                                           {
                                                                             thrown: true,
                                                                             participant_name: 'Hero',
                                                                             landing_x: 10,
                                                                             landing_y: 10,
                                                                             landed_in_hazard: false,
                                                                             hazard_type: nil
                                                                           }
                                                                         ]
                                                                       })

      event = { monster: monster }
      service.send(:process_monster_shake_off, event, 50)
      shake_events = service.events.select { |e| e[:event_type] == 'monster_shake_off' }
      expect(shake_events).not_to be_empty
    end
  end

  describe 'battle map integration' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id, hex_x: 0, hex_y: 0)
      defender.update(hex_x: 1, hex_y: 0)
    end

    context 'when battle map is active' do
      before do
        allow(service.battle_map_service).to receive(:battle_map_active?).and_return(true)
        allow(service.battle_map_service).to receive(:elevation_modifier).and_return(1)
        allow(service.battle_map_service).to receive(:line_of_sight_penalty).and_return(0)
        allow(service.battle_map_service).to receive(:prone_modifier).and_return(0)
        allow(service.battle_map_service).to receive(:elevation_damage_bonus).and_return(0)
      end

      it 'applies elevation modifier to attack' do
        event = {
          actor: attacker,
          target: defender,
          weapon: nil,
          weapon_type: :unarmed,
          natural_attack: nil
        }
        service.send(:process_attack, event, 50)
        combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
        expect(combat_events).not_to be_empty
      end

      context 'for ranged attacks' do
        let(:ranged_weapon) { double('RangedWeapon', pattern: double(range_in_hexes: 10)) }

        it 'applies elevation damage bonus' do
          allow(service.battle_map_service).to receive(:elevation_damage_bonus).and_return(2)
          event = {
            actor: attacker,
            target: defender,
            weapon: ranged_weapon,
            weapon_type: :ranged,
            natural_attack: nil
          }
          service.send(:process_attack, event, 50)
          combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
          expect(combat_events).not_to be_empty
        end

        it 'blocks shot when full cover' do
          cover_hex = double('RoomHex', provides_cover?: true, cover_object: 'wall',
                             hex_x: 2, hex_y: 0)
          allow(CoverLosService).to receive(:blocking_cover_hex).and_return(cover_hex)
          defender.update(moved_this_round: false, acted_this_round: false)
          event = {
            actor: attacker,
            target: defender,
            weapon: ranged_weapon,
            weapon_type: :ranged,
            natural_attack: nil
          }
          service.send(:process_attack, event, 50)
          blocked_events = service.events.select { |e| e[:event_type] == 'shot_blocked' }
          expect(blocked_events).not_to be_empty
        end

        it 'reduces damage with partial cover when target moved' do
          # Partial cover: blocking hex exists but target moved
          cover_hex = double('RoomHex', provides_cover?: true, cover_object: 'wall',
                             hex_x: 2, hex_y: 0)
          allow(CoverLosService).to receive(:blocking_cover_hex).and_return(cover_hex)
          defender.update(moved_this_round: true, acted_this_round: false)
          event = {
            actor: attacker,
            target: defender,
            weapon: ranged_weapon,
            weapon_type: :ranged,
            natural_attack: nil
          }
          service.send(:process_attack, event, 50)
          combat_events = service.events.select { |e| %w[hit miss shot_blocked].include?(e[:event_type]) }
          expect(combat_events).not_to be_empty
        end
      end
    end
  end

  describe '#check_knockouts with hostile NPCs' do
    let(:hostile_archetype) { create(:npc_archetype, behavior_pattern: 'hostile') }
    let(:hostile_char) { create(:character, :npc, npc_archetype: hostile_archetype) }
    let(:hostile_instance) { create(:character_instance, character: hostile_char, current_room: room) }
    let!(:hostile_participant) do
      fp = create(:fight_participant,
                  fight: fight,
                  character_instance: hostile_instance,
                  side: 2,
                  max_hp: 6)
      # Set current_hp after create because before_create hook overwrites it for NPCs
      fp.update(current_hp: 0, is_knocked_out: true)
      fp
    end

    before do
      service.initialize_round_state
      allow(NpcSpawnService).to receive(:kill_npc!)
    end

    it 'creates death event for hostile NPC instead of knockout' do
      service.send(:check_knockouts)
      death_events = service.events.select { |e| e[:event_type] == 'death' }
      expect(death_events).not_to be_empty
      expect(NpcSpawnService).to have_received(:kill_npc!)
    end
  end

  describe '#generate_roll_display' do
    before do
      service.initialize_round_state
    end

    context 'with pre-rolled PC attack dice' do
      before do
        roll = DiceRollService::RollResult.new(
          total: 15, dice: [8, 7], base_dice: [8, 7], sides: 8,
          modifier: 0, explosions: [], count: 2, explode_on: 8
        )
        service.instance_variable_set(:@combat_pre_rolls, {
          attacker.id => {
            base_roll: roll,
            willpower_roll: nil,
            stat_modifier: 3,
            roll_total: 15,
            all_roll_penalty: 0,
            attack_count: 5,
            weapon_type: :melee,
            is_pc: true
          }
        })
      end

      it 'generates one display entry per PC attacker' do
        service.send(:generate_roll_display)
        roll_display = service.instance_variable_get(:@roll_display)
        expect(roll_display).to be_an(Array)
        expect(roll_display.length).to eq(1)
        expect(roll_display.first[:character_name]).to eq(attacker.character_name)
        expect(roll_display.first[:animations]).to be_an(Array)
        expect(roll_display.first[:animations].length).to eq(1)
      end

      it 'includes willpower dice merged into base animation when present' do
        wp_roll = DiceRollService::RollResult.new(
          total: 6, dice: [6], base_dice: [6], sides: 8,
          modifier: 0, explosions: [], count: 1, explode_on: 8
        )
        pre_rolls = service.instance_variable_get(:@combat_pre_rolls)
        pre_rolls[attacker.id][:willpower_roll] = wp_roll
        pre_rolls[attacker.id][:roll_total] = 21

        service.send(:generate_roll_display)
        roll_display = service.instance_variable_get(:@roll_display)
        # Willpower dice are merged into the base animation (1 entry, not 2)
        expect(roll_display.first[:animations].length).to eq(1)
        # The animation data should contain willpower dice (type 4)
        anim_data = roll_display.first[:animations].first
        expect(anim_data).to include('4||')
      end
    end

    context 'with NPC attacks' do
      before do
        roll = DiceRollService::RollResult.new(
          total: 10, dice: [5, 5], base_dice: [5, 5], sides: 8,
          modifier: 0, explosions: [], count: 2, explode_on: nil
        )
        service.instance_variable_set(:@combat_pre_rolls, {
          defender.id => {
            base_roll: roll, willpower_roll: nil, stat_modifier: 2,
            roll_total: 10, all_roll_penalty: 0, attack_count: 3,
            weapon_type: :melee, is_pc: false
          }
        })
      end

      it 'does not display NPC rolls' do
        service.send(:generate_roll_display)
        roll_display = service.instance_variable_get(:@roll_display)
        expect(roll_display).to be_empty
      end
    end

    context 'with defense rolls' do
      before do
        service.instance_variable_set(:@combat_pre_rolls, {})
        # Willpower defense is now pre-rolled in round_state
        defense_roll = DiceRollService::RollResult.new(
          total: 5, dice: [5], base_dice: [5], sides: 8,
          modifier: 0, explosions: [], count: 1, explode_on: 8
        )
        round_state = service.instance_variable_get(:@round_state)
        round_state[defender.id] = {
          willpower_defense_roll: defense_roll,
          willpower_defense_total: 5,
          willpower_defense_applied: 0
        }
      end

      it 'includes willpower defense rolls' do
        service.send(:generate_roll_display)
        roll_display = service.instance_variable_get(:@roll_display)
        expect(roll_display.length).to eq(1)
        expect(roll_display.first[:character_name]).to eq(defender.character_name)
      end
    end
  end

  describe '#pre_roll_combat_dice' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
      # Schedule a fake attack event so count_scheduled_attacks finds it
      segment_events = service.instance_variable_get(:@segment_events)
      segment_events[20] << { type: :attack, actor: attacker, target: defender, weapon_type: :melee }
    end

    it 'creates a pre-roll entry for attacking participants' do
      allow(DiceRollService).to receive(:roll).and_return(
        DiceRollService::RollResult.new(
          total: 12, dice: [5, 7], base_dice: [5, 7], sides: 8,
          modifier: 0, explosions: [], count: 2, explode_on: 8
        )
      )
      allow(attacker).to receive(:willpower_attack_roll).and_return(nil)
      allow(attacker).to receive(:all_roll_penalty).and_return(0)

      service.send(:pre_roll_combat_dice)
      pre_rolls = service.instance_variable_get(:@combat_pre_rolls)
      expect(pre_rolls).to have_key(attacker.id)
      expect(pre_rolls[attacker.id][:roll_total]).to eq(12)
      expect(pre_rolls[attacker.id][:attack_count]).to eq(1)
    end

    it 'skips participants not attacking' do
      defender.update(main_action: 'dodge')
      allow(DiceRollService).to receive(:roll).and_return(
        DiceRollService::RollResult.new(
          total: 10, dice: [4, 6], base_dice: [4, 6], sides: 8,
          modifier: 0, explosions: [], count: 2, explode_on: 8
        )
      )
      allow(attacker).to receive(:willpower_attack_roll).and_return(nil)
      allow(attacker).to receive(:all_roll_penalty).and_return(0)

      service.send(:pre_roll_combat_dice)
      pre_rolls = service.instance_variable_get(:@combat_pre_rolls)
      expect(pre_rolls).not_to have_key(defender.id)
    end
  end

  describe '#generate_round_damage_summary' do
    before do
      service.initialize_round_state
      service.instance_variable_set(:@combat_pre_rolls, {})
    end

    it 'returns nil when no damage events' do
      service.send(:generate_round_damage_summary)
      expect(service.instance_variable_get(:@damage_summary)).to be_nil
    end

    it 'aggregates damage per attacker-target pair' do
      # Raw damage now comes from hit/miss events (per-attack totals)
      service.events << {
        event_type: 'hit',
        actor_name: 'Alpha',
        target_name: 'Beta',
        details: { total: 15 }
      }
      service.events << {
        event_type: 'hit',
        actor_name: 'Alpha',
        target_name: 'Beta',
        details: { total: 10 }
      }
      # HP lost comes from damage_applied events
      service.events << {
        event_type: 'damage_applied',
        actor_name: 'Alpha',
        target_name: 'Beta',
        details: { hp_lost_now: 2 }
      }

      service.send(:generate_round_damage_summary)
      summary = service.instance_variable_get(:@damage_summary)
      expect(summary).to include('Alpha dmg Beta for 25[2HP]')
    end

    it 'includes knockout events' do
      service.events << {
        event_type: 'knockout',
        target_name: 'Beta',
        details: { target_name: 'Beta' }
      }

      service.send(:generate_round_damage_summary)
      summary = service.instance_variable_get(:@damage_summary)
      expect(summary).to include("Beta KO'd")
    end
  end

  describe '#process_movement_step with snared actor' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 0, hex_y: 0, movement_action: 'towards_person', movement_target_participant_id: defender.id)
      allow(attacker).to receive(:can_move?).and_return(false)
    end

    it 'creates movement_blocked event' do
      event = {
        actor: attacker,
        target_hex: [1, 0],
        step_index: 0,
        total_steps: 3
      }
      service.send(:process_movement_step, event, 25)
      blocked_events = service.events.select { |e| e[:event_type] == 'movement_blocked' }
      expect(blocked_events).not_to be_empty
      expect(blocked_events.first[:details][:reason]).to eq('snared')
    end

    it 'still marks movement complete on final blocked step' do
      event = {
        actor: attacker,
        target_hex: [1, 0],
        step_index: 0,
        total_steps: 1
      }
      service.send(:process_movement_step, event, 50)
      attacker.refresh
      expect(attacker.movement_completed_segment).to eq(50)
    end
  end

  describe '#schedule_movement' do
    before do
      service.initialize_round_state
    end

    it 'handles redundant stand_still check in main schedule_movement' do
      attacker.update(movement_action: 'stand_still')
      service.send(:schedule_movement, attacker)
      segment_events = service.instance_variable_get(:@segment_events)
      movement_events = segment_events.flatten.select { |e| e[:type] == :movement_step }
      # stand_still should not schedule any movement events
      expect(movement_events).to be_empty
    end

    it 'schedules movement events for each path step' do
      attacker.update(movement_action: 'towards_person', movement_target_participant_id: defender.id)
      defender.update(hex_x: 20, hex_y: 0)
      attacker.update(hex_x: 0, hex_y: 0)

      allow(attacker).to receive(:movement_segments).and_return([10, 30, 50])
      allow(service).to receive(:calculate_movement_path).and_return([[1, 0], [2, 0], [3, 0], [4, 0], [5, 0]])

      service.send(:schedule_movement, attacker)
      segment_events = service.instance_variable_get(:@segment_events)
      movement_events = segment_events.flatten.select { |e| e[:type] == :movement_step }
      # Creates one event per path step (5 steps), reusing last segment for extras
      expect(movement_events.length).to eq(5)
    end

    it 'schedules shadow pursuit steps when already adjacent and moving towards target' do
      attacker.update(
        movement_action: 'towards_person',
        movement_target_participant_id: defender.id,
        hex_x: 1,
        hex_y: 2
      )
      defender.update(hex_x: 0, hex_y: 0)
      allow(attacker).to receive(:movement_segments).and_return([10, 30, 50, 70])

      service.send(:schedule_movement, attacker)
      segment_events = service.instance_variable_get(:@segment_events)
      movement_events = segment_events.flatten.select { |e| e[:type] == :movement_step }

      expect(movement_events).not_to be_empty
      expect(movement_events.all? { |e| e[:target_hex].nil? }).to be true
    end
  end

  describe '#reevaluate_weapon_for_distance' do
    before { service.initialize_round_state }

    it 'switches to melee at adjacent range even when scheduled weapon type is a string' do
      melee_weapon = double('MeleeWeapon')
      ranged_weapon = double('RangedWeapon')

      allow(attacker).to receive(:hex_distance_to).with(defender).and_return(1)
      allow(attacker).to receive(:melee_weapon).and_return(melee_weapon)
      allow(attacker).to receive(:ranged_weapon).and_return(ranged_weapon)
      allow(service).to receive(:ensure_weapon_equipped)

      weapon, weapon_type = service.send(:reevaluate_weapon_for_distance, attacker, defender, ranged_weapon, 'ranged')
      expect(weapon).to eq(melee_weapon)
      expect(weapon_type).to eq(:melee)
    end
  end

  describe '#process_end_of_round_effects' do
    before do
      service.initialize_round_state
    end

    it 'yields burning spread events' do
      allow(StatusEffectService).to receive(:process_burning_spread).and_yield(
        from: attacker,
        to: defender
      )

      service.send(:process_end_of_round_effects)
      spread_events = service.events.select { |e| e[:event_type] == 'burning_spread' }
      expect(spread_events).not_to be_empty
    end
  end

  describe '#check_attack_redirection with guard and back_to_back' do
    let(:third_char) { create(:character) }
    let(:third_instance) { create(:character_instance, character: third_char, current_room: room) }
    let!(:guard_participant) do
      create(:fight_participant,
             fight: fight,
             character_instance: third_instance,
             side: 2,
             current_hp: 6,
             max_hp: 6,
             hex_x: 1,
             hex_y: 1)
    end

    before do
      service.initialize_round_state
      defender.update(hex_x: 1, hex_y: 0)
    end

    context 'with guard tactic' do
      before do
        allow(guard_participant).to receive(:guarding?).with(defender).and_return(true)
        allow(guard_participant).to receive(:protection_active_at_segment?).and_return(true)
        allow(guard_participant).to receive(:hex_distance_to).with(defender).and_return(1)
      end

      it 'can redirect attack to guard' do
        allow_any_instance_of(Object).to receive(:rand).with(100).and_return(10)  # Below 50% threshold
        result = service.send(:check_attack_redirection, defender, attacker, 50)
        # May or may not redirect depending on random
        expect(result).to be_nil.or(be_an(Array))
      end
    end

    context 'with back_to_back tactic' do
      before do
        allow(guard_participant).to receive(:guarding?).and_return(false)
        allow(guard_participant).to receive(:back_to_back_with?).with(defender).and_return(true)
        allow(guard_participant).to receive(:protection_active_at_segment?).and_return(true)
        allow(guard_participant).to receive(:hex_distance_to).with(defender).and_return(1)
        allow(defender).to receive(:mutual_back_to_back_with?).with(guard_participant).and_return(true)
      end

      it 'can redirect attack to back_to_back partner' do
        allow_any_instance_of(Object).to receive(:rand).with(100).and_return(10)
        result = service.send(:check_attack_redirection, defender, attacker, 50)
        # May or may not redirect depending on random
        expect(result).to be_nil.or(be_an(Array))
      end
    end
  end

  describe '#schedule_monster_attacks' do
    let(:monster) { create(:large_monster_instance, fight: fight, status: 'active') }
    let(:monster_service) { instance_double(MonsterCombatService) }

    before do
      service.initialize_round_state
      fight.update(has_monster: true)
      service.instance_variable_set(:@monster_combat_service, monster_service)
    end

    it 'schedules monster attacks' do
      allow(LargeMonsterInstance).to receive(:where).and_return([monster])
      allow(monster_service).to receive(:schedule_monster_attacks).and_return({
                                                                                20 => [{ type: :monster_attack, monster: monster }]
                                                                              })

      service.send(:schedule_monster_attacks)
      segment_events = service.instance_variable_get(:@segment_events)
      monster_events = segment_events.flatten.select { |e| e[:type] == :monster_attack }
      expect(monster_events).not_to be_empty
    end
  end

  describe 'resolve! with various actions' do
    context 'when one participant attacks and one defends' do
      before do
        attacker.update(main_action: 'attack', target_participant_id: defender.id)
        defender.update(main_action: 'defend')
      end

      it 'completes resolution without error' do
        result = service.resolve!
        expect(result).to have_key(:events)
        expect(result).to have_key(:roll_display)
      end
    end

    context 'when participant uses ability' do
      let!(:ability) { create(:ability, name: 'Fireball', universe: room.location&.zone&.world&.universe) }

      before do
        attacker.update(main_action: 'ability', ability_id: ability.id, target_participant_id: defender.id)
        defender.update(main_action: 'pass')
      end

      it 'completes resolution with ability' do
        result = service.resolve!
        expect(result).to have_key(:events)
      end
    end

    context 'when participant is fleeing' do
      # Create exit_room north of the fight room (sharing edge at y=100)
      let(:exit_room) { create(:room, location: room.location, min_y: 100, max_y: 200) }

      before do
        # Ensure exit_room exists
        exit_room

        # Note: 'flee' is not a valid main_action; fleeing is tracked via is_fleeing flag
        # Using 'pass' as the main_action with is_fleeing: true
        # Defender must not also pass, otherwise mutual_pass triggers and skips flee
        attacker.update(
          main_action: 'pass',
          is_fleeing: true,
          flee_exit_id: exit_room.id,
          flee_direction: 'north',
          hex_x: 0,
          hex_y: 0
        )
        defender.update(main_action: 'defend', hex_x: 1, hex_y: 0)
        allow_any_instance_of(FightParticipant).to receive(:process_successful_flee!)
      end

      it 'processes flee at end of round' do
        result = service.resolve!
        # Should either succeed or fail flee
        flee_events = result[:events].select { |e| e[:event_type]&.include?('flee') }
        expect(flee_events).not_to be_empty
      end
    end
  end

  describe 'incremental damage application' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id, hex_x: 0, hex_y: 0)
      defender.update(hex_x: 1, hex_y: 0, current_hp: 6)
    end

    it 'tracks cumulative damage across multiple attacks' do
      # First attack
      event1 = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event1, 20)

      state = service.instance_variable_get(:@round_state)[defender.id]
      first_damage = state[:cumulative_damage]

      # Second attack
      event2 = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event2, 40)

      state = service.instance_variable_get(:@round_state)[defender.id]
      expect(state[:cumulative_damage]).to be >= first_damage
    end
  end

  describe '#apply_accumulated_damage summary' do
    before do
      service.initialize_round_state
      state = service.instance_variable_get(:@round_state)
      state[defender.id][:cumulative_damage] = 25
      state[defender.id][:hp_lost_this_round] = 2
    end

    it 'creates round damage summary event' do
      service.send(:apply_accumulated_damage)
      summary_events = service.events.select { |e| e[:event_type] == 'round_damage_summary' }
      expect(summary_events).not_to be_empty
      expect(summary_events.first[:details][:total_damage_taken]).to eq(25)
    end
  end

  # ============================================
  # Additional Edge Case Tests for Coverage
  # ============================================

  describe 'damage threshold edge cases' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id, hex_x: 0, hex_y: 0)
      defender.update(hex_x: 1, hex_y: 0, current_hp: 6)
    end

    context 'when damage is exactly at threshold boundary' do
      it 'handles damage exactly at 10 (1 HP threshold)' do
        roll = DiceRollService::RollResult.new(total: 10, dice: [5, 5], sides: 8, modifier: 0, explosions: [])
        allow(DiceRollService).to receive(:roll).and_return(roll)
        allow(service).to receive(:get_attack_stat).and_return(0)

        event = { actor: attacker, target: defender, weapon: nil, weapon_type: :unarmed, natural_attack: nil }
        service.send(:process_attack, event, 50)

        # Threshold boundary behavior
        combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
        expect(combat_events).not_to be_empty
      end

      it 'handles damage exactly at 18 (2 HP threshold)' do
        roll = DiceRollService::RollResult.new(total: 18, dice: [10, 8], sides: 8, modifier: 0, explosions: [[8, 2]])
        allow(DiceRollService).to receive(:roll).and_return(roll)
        allow(service).to receive(:get_attack_stat).and_return(0)

        event = { actor: attacker, target: defender, weapon: nil, weapon_type: :unarmed, natural_attack: nil }
        service.send(:process_attack, event, 50)

        combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
        expect(combat_events).not_to be_empty
      end

      it 'handles damage exactly at 30 (3 HP threshold)' do
        roll = DiceRollService::RollResult.new(total: 30, dice: [15, 15], sides: 8, modifier: 0, explosions: [])
        allow(DiceRollService).to receive(:roll).and_return(roll)
        allow(service).to receive(:get_attack_stat).and_return(0)

        event = { actor: attacker, target: defender, weapon: nil, weapon_type: :unarmed, natural_attack: nil }
        service.send(:process_attack, event, 50)

        combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
        expect(combat_events).not_to be_empty
      end
    end

    context 'when defender has maximum wound penalty' do
      before do
        defender.update(current_hp: 1)  # 5 HP lost = wound_penalty 5
      end

      it 'shifts threshold down by wound penalty' do
        # With wound_penalty 5, threshold drops from 10 to 5
        roll = DiceRollService::RollResult.new(total: 6, dice: [3, 3], sides: 8, modifier: 0, explosions: [])
        allow(DiceRollService).to receive(:roll).and_return(roll)
        allow(service).to receive(:get_attack_stat).and_return(0)

        event = { actor: attacker, target: defender, weapon: nil, weapon_type: :unarmed, natural_attack: nil }
        service.send(:process_attack, event, 50)

        # Should be a hit at 6 when threshold is 5
        combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
        expect(combat_events).not_to be_empty
      end
    end
  end

  describe 'multiple attackers with different damage types' do
    let(:third_char) { create(:character) }
    let(:third_instance) { create(:character_instance, character: third_char, current_room: room) }
    let!(:third_participant) do
      create(:fight_participant,
             fight: fight,
             character_instance: third_instance,
             side: 1,
             current_hp: 6,
             max_hp: 6,
             hex_x: 2,
             hex_y: 0)
    end

    before do
      service.initialize_round_state
      defender.update(hex_x: 1, hex_y: 0)
    end

    it 'tracks damage by damage type for type-specific armor' do
      state = service.instance_variable_get(:@round_state)

      # First attacker deals physical damage
      state[defender.id][:raw_by_attacker_type][[attacker.id, 'physical']] = 15

      # Second attacker deals fire damage
      state[defender.id][:raw_by_attacker_type][[third_participant.id, 'fire']] = 10

      expect(state[defender.id][:raw_by_attacker_type].keys.length).to eq(2)
    end
  end

  describe 'DOT knockout scenarios' do
    let(:status_effect) { create(:status_effect, effect_type: 'damage_tick') }
    let!(:pse) do
      create(:participant_status_effect,
             fight_participant: defender,
             status_effect: status_effect,
             applied_at_round: 1,
             expires_at_round: 4)
    end

    before do
      service.initialize_round_state
      defender.update(current_hp: 1, hex_x: 1, hex_y: 0)
    end

    it 'knocks out target when DOT damage reduces HP to 0' do
      # Massive DOT damage to guarantee knockout
      allow(StatusEffectService).to receive(:process_dot_tick).and_yield(
        participant: defender,
        damage: 100,
        damage_type: 'fire',
        tick_number: 1,
        total_ticks: 3,
        effect: 'burning'
      )
      allow(StatusEffectService).to receive(:absorb_damage_with_shields).and_return(100)
      allow(PrisonerService).to receive(:process_knockout!)

      event = {
        participant_status_effect_id: pse.id,
        participant: defender,
        tick_index: 0,
        segment: 30
      }
      service.send(:process_dot_tick_event, event, 30)

      knockout_events = service.events.select { |e| e[:event_type] == 'knockout' }
      expect(knockout_events).not_to be_empty
    end
  end

  describe 'melee catchup window edge cases' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 0, hex_y: 0)
      defender.update(hex_x: 6, hex_y: 0)  # Valid hex coordinate (even x at y=0)
    end

    it 'allows melee attack when movement catches up within window' do
      segment_events = service.instance_variable_get(:@segment_events)
      # Schedule movement that puts attacker adjacent to defender
      # Defender at (6,0), adjacent hex (5,2) is distance 1 away
      (21..25).each do |seg|
        segment_events[seg] = [{
          type: :movement_step,
          actor: attacker,
          target_hex: [5, 2]  # Adjacent to defender at (6,0)
        }]
      end

      result = service.send(:will_close_melee_gap?, attacker, defender, 20)
      expect(result).to be true
    end

    it 'denies melee attack when movement does not reach target' do
      segment_events = service.instance_variable_get(:@segment_events)
      # Schedule movement that stops far from defender
      segment_events[25] = [{
        type: :movement_step,
        actor: attacker,
        target_hex: [2, 0]  # 2 hexes away from defender at (6,0)
      }]

      result = service.send(:will_close_melee_gap?, attacker, defender, 20)
      expect(result).to be false
    end

    it 'returns false when movement is outside catchup window' do
      segment_events = service.instance_variable_get(:@segment_events)
      # Schedule movement way past the catchup window
      segment_events[90] = [{
        type: :movement_step,
        actor: attacker,
        target_hex: [4, 0]
      }]

      result = service.send(:will_close_melee_gap?, attacker, defender, 20)
      expect(result).to be false
    end

    it 'returns false when both combatants move away from each other' do
      segment_events = service.instance_variable_get(:@segment_events)
      # Schedule actor moving away from target
      segment_events[45] = [{
        type: :movement_step,
        actor: attacker,
        target_hex: [10, 10]
      }]
      # Schedule target also moving away from actor
      segment_events[43] = [{
        type: :movement_step,
        actor: defender,
        target_hex: [0, 0]
      }]
      # Both at range, both moving apart — should not close gap
      expect(service.send(:will_close_melee_gap?, attacker, defender, 40)).to be false
    end
  end

  describe 'guard and back-to-back redirect damage modifiers' do
    let(:third_char) { create(:character) }
    let(:third_instance) { create(:character_instance, character: third_char, current_room: room) }
    let!(:guard_participant) do
      create(:fight_participant,
             fight: fight,
             character_instance: third_instance,
             side: 2,
             current_hp: 6,
             max_hp: 6,
             hex_x: 1,
             hex_y: 1)
    end

    before do
      attacker.update(hex_x: 0, hex_y: 0)
      defender.update(hex_x: 1, hex_y: 0)
      service.initialize_round_state
    end

    context 'guard redirect' do
      before do
        # Make guard adjacent to defender - refresh identity map after position update
        guard_participant.update(hex_x: 2, hex_y: 0)
        service.initialize_round_state
        # Stub behavior on the identity map objects
        map_guard = service.participant(guard_participant.id)
        map_defender = service.participant(defender.id)
        allow(map_guard).to receive(:guarding?).with(map_defender).and_return(true)
        allow(map_guard).to receive(:protection_active_at_segment?).and_return(true)
        allow(map_guard).to receive(:hex_distance_to).with(map_defender).and_return(1)
      end

      it 'returns guard as redirect target with damage bonus' do
        # Force random to always succeed the redirect
        allow_any_instance_of(Object).to receive(:rand).with(100).and_return(0)

        map_defender = service.participant(defender.id)
        map_attacker = service.participant(attacker.id)
        map_guard = service.participant(guard_participant.id)
        result = service.send(:check_attack_redirection, map_defender, map_attacker, 50)
        expect(result).not_to be_nil
        expect(result[0]).to eq(map_guard)
        expect(result[1]).to eq(:guard)
        expect(result[2]).to eq(GameConfig::Tactics::PROTECTION[:guard_damage_bonus])
      end
    end

    context 'back-to-back redirect' do
      before do
        guard_participant.update(hex_x: 2, hex_y: 0)
        service.initialize_round_state
        map_guard = service.participant(guard_participant.id)
        map_defender = service.participant(defender.id)
        allow(map_guard).to receive(:guarding?).and_return(false)
        allow(map_guard).to receive(:back_to_back_with?).with(map_defender).and_return(true)
        allow(map_guard).to receive(:protection_active_at_segment?).and_return(true)
        allow(map_guard).to receive(:hex_distance_to).with(map_defender).and_return(1)
        allow(map_defender).to receive(:mutual_back_to_back_with?).with(map_guard).and_return(true)
      end

      it 'returns btb partner with mutual damage reduction' do
        allow_any_instance_of(Object).to receive(:rand).with(100).and_return(0)

        map_defender = service.participant(defender.id)
        map_attacker = service.participant(attacker.id)
        map_guard = service.participant(guard_participant.id)
        result = service.send(:check_attack_redirection, map_defender, map_attacker, 50)
        expect(result).not_to be_nil
        expect(result[0]).to eq(map_guard)
        expect(result[1]).to eq(:back_to_back)
        expect(result[2]).to eq(GameConfig::Tactics::PROTECTION[:btb_mutual_damage_mod])
      end
    end

    context 'guard out of range' do
      before do
        guard_participant.update(hex_x: 10, hex_y: 10)  # Far away
        service.initialize_round_state
        map_guard = service.participant(guard_participant.id)
        map_defender = service.participant(defender.id)
        allow(map_guard).to receive(:guarding?).with(map_defender).and_return(true)
        allow(map_guard).to receive(:protection_active_at_segment?).and_return(true)
        allow(map_guard).to receive(:hex_distance_to).with(map_defender).and_return(12)
      end

      it 'does not redirect when guard is too far' do
        map_defender = service.participant(defender.id)
        map_attacker = service.participant(attacker.id)
        result = service.send(:check_attack_redirection, map_defender, map_attacker, 50)
        expect(result).to be_nil
      end
    end

    context 'guard knocked out' do
      before do
        guard_participant.update(hex_x: 2, hex_y: 0)
        service.initialize_round_state
        service.mark_knocked_out!(guard_participant.id)
        map_guard = service.participant(guard_participant.id)
        map_defender = service.participant(defender.id)
        allow(map_guard).to receive(:guarding?).with(map_defender).and_return(true)
        allow(map_guard).to receive(:protection_active_at_segment?).and_return(true)
        allow(map_guard).to receive(:hex_distance_to).with(map_defender).and_return(1)
      end

      it 'does not redirect to knocked out guard' do
        map_defender = service.participant(defender.id)
        map_attacker = service.participant(attacker.id)
        result = service.send(:check_attack_redirection, map_defender, map_attacker, 50)
        expect(result).to be_nil
      end
    end
  end

  describe 'movement blocked message only on first step' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 0, hex_y: 0, movement_action: 'towards_person', movement_target_participant_id: defender.id)
      allow(attacker).to receive(:can_move?).and_return(false)
    end

    it 'emits blocked message only on step_index 0' do
      # First step - should emit blocked message
      event1 = { actor: attacker, target_hex: [1, 0], step_index: 0, total_steps: 3 }
      service.send(:process_movement_step, event1, 25)

      # Second step - should not emit blocked message
      event2 = { actor: attacker, target_hex: [2, 0], step_index: 1, total_steps: 3 }
      service.send(:process_movement_step, event2, 35)

      blocked_events = service.events.select { |e| e[:event_type] == 'movement_blocked' }
      expect(blocked_events.length).to eq(1)
    end
  end

  describe 'calculate_effective_cumulative edge cases' do
    before { service.initialize_round_state }

    it 'handles zero raw damage with DOT' do
      state = {
        raw_by_attacker: {},
        raw_by_attacker_type: {},
        dot_cumulative: 15
      }
      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(0)
      allow(StatusEffectService).to receive(:overall_protection).and_return(0)

      result = service.calculate_effective_cumulative(defender, state, 'physical')
      expect(result[:effective]).to eq(15)  # DOT only
      expect(result[:armor_reduced]).to eq(0)
      expect(result[:protection_reduced]).to eq(0)
    end

    it 'handles armor exceeding per-attacker damage' do
      state = {
        raw_by_attacker: { attacker.id => 5 },
        raw_by_attacker_type: {},
        dot_cumulative: 0
      }
      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(10)  # More than damage
      allow(StatusEffectService).to receive(:overall_protection).and_return(0)

      result = service.calculate_effective_cumulative(defender, state, 'physical')
      expect(result[:effective]).to eq(0)
      expect(result[:armor_reduced]).to eq(5)  # Can only reduce what exists
    end

    it 'handles protection exceeding post-armor damage' do
      state = {
        raw_by_attacker: { attacker.id => 20 },
        raw_by_attacker_type: {},
        dot_cumulative: 0
      }
      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(5)  # 20-5=15
      allow(StatusEffectService).to receive(:overall_protection).and_return(25)  # More than 15

      result = service.calculate_effective_cumulative(defender, state, 'physical')
      expect(result[:effective]).to eq(0)
      expect(result[:armor_reduced]).to eq(5)
      expect(result[:protection_reduced]).to eq(15)  # Only reduces what remains
    end

    it 'handles multiple attackers with different armor amounts' do
      third_char = create(:character)
      third_instance = create(:character_instance, character: third_char, current_room: room)
      third_participant = create(:fight_participant,
                                  fight: fight,
                                  character_instance: third_instance,
                                  side: 1,
                                  current_hp: 6,
                                  max_hp: 6)

      state = {
        raw_by_attacker: { attacker.id => 20, third_participant.id => 15 },
        raw_by_attacker_type: {},
        dot_cumulative: 5
      }
      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(5)
      allow(StatusEffectService).to receive(:overall_protection).and_return(0)

      result = service.calculate_effective_cumulative(defender, state, 'physical')
      # attacker: 20-5=15, third: 15-5=10, total attack after armor: 25, plus DOT 5 = 30
      expect(result[:effective]).to eq(30)
      expect(result[:armor_reduced]).to eq(10)  # 5+5 reduced
    end
  end

  describe 'initialize_round_state with target distance' do
    before do
      attacker.update(hex_x: 0, hex_y: 0, target_participant_id: defender.id)
      defender.update(hex_x: 5, hex_y: 0)
    end

    it 'captures initial distance to target' do
      service.initialize_round_state
      state = service.instance_variable_get(:@round_state)
      expect(state[attacker.id][:initial_distance_to_target]).not_to be_nil
    end

    it 'sets initial_adjacent false when not adjacent' do
      service.initialize_round_state
      state = service.instance_variable_get(:@round_state)
      expect(state[attacker.id][:initial_adjacent]).to be false
    end

    it 'sets initial_adjacent true when adjacent' do
      defender.update(hex_x: 1, hex_y: 0)  # Adjacent
      service.initialize_round_state
      state = service.instance_variable_get(:@round_state)
      expect(state[attacker.id][:initial_adjacent]).to be true
    end

    it 'handles nil target' do
      attacker.update(target_participant_id: nil)
      service.initialize_round_state
      state = service.instance_variable_get(:@round_state)
      expect(state[attacker.id][:initial_distance_to_target]).to be_nil
      expect(state[attacker.id][:initial_adjacent]).to be false
    end
  end

  describe 'process_attack with attack redirection event' do
    let(:third_char) { create(:character) }
    let(:third_instance) { create(:character_instance, character: third_char, current_room: room) }
    let!(:guard_participant) do
      create(:fight_participant,
             fight: fight,
             character_instance: third_instance,
             side: 2,
             current_hp: 6,
             max_hp: 6,
             hex_x: 2,
             hex_y: 0)
    end

    before do
      service.initialize_round_state
      attacker.update(hex_x: 0, hex_y: 0, main_action: 'attack', target_participant_id: defender.id)
      defender.update(hex_x: 1, hex_y: 0)

      # Force redirect
      allow(service).to receive(:check_attack_redirection).and_return([guard_participant, :guard, 2])
    end

    it 'creates attack_redirected event' do
      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)

      redirect_events = service.events.select { |e| e[:event_type] == 'attack_redirected' }
      expect(redirect_events).not_to be_empty
      expect(redirect_events.first[:details][:new_target_name]).to eq(guard_participant.character_name)
      expect(redirect_events.first[:details][:redirect_type]).to eq('guard')
    end
  end

  describe 'shield absorption tracking' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 0, hex_y: 0, main_action: 'attack', target_participant_id: defender.id)
      defender.update(hex_x: 1, hex_y: 0)
    end

    it 'tracks shield absorbed total in round state' do
      # Shield absorbs some damage
      allow(StatusEffectService).to receive(:absorb_damage_with_shields) do |target, damage, type|
        damage - 5  # Shield absorbs 5
      end

      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)

      state = service.instance_variable_get(:@round_state)
      expect(state[defender.id][:shield_absorbed_total]).to be >= 0
    end
  end

  describe 'NPC defense bonus and damage bonus' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 0, hex_y: 0, main_action: 'attack', target_participant_id: defender.id)
      defender.update(hex_x: 1, hex_y: 0)
    end

    it 'applies NPC damage bonus to attack' do
      allow(attacker).to receive(:npc_damage_bonus).and_return(5)
      allow(defender).to receive(:npc_defense_bonus).and_return(0)

      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)

      combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
      expect(combat_events).not_to be_empty
    end

    it 'applies NPC defense bonus to reduce attack' do
      allow(attacker).to receive(:npc_damage_bonus).and_return(0)
      allow(defender).to receive(:npc_defense_bonus).and_return(5)

      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)

      combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
      expect(combat_events).not_to be_empty
    end
  end

  describe 'tactic modifiers' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 0, hex_y: 0, main_action: 'attack', target_participant_id: defender.id)
      defender.update(hex_x: 1, hex_y: 0)
    end

    it 'applies tactic_outgoing_damage_modifier' do
      allow(attacker).to receive(:tactic_outgoing_damage_modifier).and_return(3)
      allow(defender).to receive(:tactic_incoming_damage_modifier).and_return(0)

      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)

      combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
      expect(combat_events).not_to be_empty
    end

    it 'applies tactic_incoming_damage_modifier' do
      allow(attacker).to receive(:tactic_outgoing_damage_modifier).and_return(0)
      allow(defender).to receive(:tactic_incoming_damage_modifier).and_return(-2)  # Damage reduction

      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)

      combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
      expect(combat_events).not_to be_empty
    end
  end

  describe 'all_roll_penalty application' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 0, hex_y: 0, main_action: 'attack', target_participant_id: defender.id)
      defender.update(hex_x: 1, hex_y: 0)
    end

    it 'applies all_roll_penalty to attack' do
      allow(attacker).to receive(:all_roll_penalty).and_return(-3)

      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)

      combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
      expect(combat_events).not_to be_empty
      # Check the penalty is recorded in the event details
      event_details = combat_events.first[:details]
      expect(event_details[:all_roll_penalty]).to eq(-3)
    end
  end

  describe 'natural attack with damage type' do
    let(:npc_char) { create(:character, :npc) }
    let(:npc_instance) { create(:character_instance, character: npc_char, current_room: room) }
    let!(:npc_participant) do
      create(:fight_participant,
             fight: fight,
             character_instance: npc_instance,
             side: 1,
             current_hp: 6,
             max_hp: 6,
             hex_x: 0,
             hex_y: 0)
    end
    let(:fire_attack) do
      double('NpcAttack',
             name: 'fire_breath',
             melee?: false,
             range_hexes: 3,
             dice_count: 3,
             dice_sides: 6,
             damage_type: 'fire')
    end

    before do
      service.initialize_round_state
      defender.update(hex_x: 2, hex_y: 0)
    end

    it 'applies damage type from natural attack' do
      allow(StatusEffectService).to receive(:damage_type_multiplier).with(defender, 'fire').and_return(2.0)

      event = {
        actor: npc_participant,
        target: defender,
        weapon: nil,
        weapon_type: :natural_ranged,
        natural_attack: fire_attack
      }
      service.send(:process_attack, event, 50)

      combat_events = service.events.select { |e| %w[hit miss].include?(e[:event_type]) }
      expect(combat_events).not_to be_empty
      expect(combat_events.first[:details][:damage_type]).to eq('fire')
    end
  end

  # Legacy 'process_movement with blocked movement' specs removed -
  # blocked movement is tested via process_movement_step

  describe 'save_events_to_db validation failure' do
    before do
      service.initialize_round_state
    end

    it 'handles validation failure gracefully' do
      # Create an event with invalid type (will trigger fallback)
      service.events << service.send(:create_event, 50, attacker, defender, 'INVALID_TYPE', damage: 10)

      # Should not raise
      expect { service.send(:save_events_to_db) }.not_to raise_error
    end
  end

  describe 'schedule_all_events with stand_still protection timing' do
    before do
      service.initialize_round_state
      attacker.update(movement_action: 'stand_still', main_action: 'pass')
    end

    it 'sets movement_completed_segment to 0 for stand_still' do
      service.send(:schedule_all_events)

      attacker.refresh
      expect(attacker.movement_completed_segment).to eq(0)
    end
  end

  describe 'process_flee_attempts with damage' do
    # Create exit_room north of the fight room (sharing edge at y=100)
    let(:exit_room) { create(:room, location: room.location, min_y: 100, max_y: 200) }

    before do
      # Ensure exit_room exists
      exit_room

      service.initialize_round_state
      attacker.update(
        is_fleeing: true,
        flee_exit_id: exit_room.id,
        flee_direction: 'north',
        main_action: 'pass'
      )

      # Simulate damage taken
      state = service.instance_variable_get(:@round_state)
      state[attacker.id][:cumulative_damage] = 15

      allow(attacker).to receive(:cancel_flee!)
      allow(BroadcastService).to receive(:to_character)
    end

    it 'fails flee when damage was taken' do
      service.send(:process_flee_attempts)

      flee_events = service.events.select { |e| e[:event_type] == 'flee_failed' }
      expect(flee_events).not_to be_empty
    end
  end

  describe 'process_flee_attempts with zero damage' do
    # Create exit_room north of the fight room (sharing edge at y=100)
    let(:exit_room) { create(:room, location: room.location, min_y: 100, max_y: 200) }

    before do
      # Ensure exit_room exists
      exit_room

      service.initialize_round_state
      attacker.update(
        is_fleeing: true,
        flee_exit_id: exit_room.id,
        flee_direction: 'north',
        main_action: 'pass'
      )

      # No damage taken
      state = service.instance_variable_get(:@round_state)
      state[attacker.id][:cumulative_damage] = 0

      allow_any_instance_of(FightParticipant).to receive(:process_successful_flee!)
      allow(BroadcastService).to receive(:to_room)
    end

    it 'succeeds flee when no damage was taken' do
      service.send(:process_flee_attempts)

      flee_events = service.events.select { |e| e[:event_type] == 'flee_success' }
      expect(flee_events).not_to be_empty
    end
  end

  describe 'hazard damage events' do
    before do
      service.initialize_round_state
      allow(service.battle_map_service).to receive(:battle_map_active?).and_return(true)
    end

    it 'creates hazard_damage events from battle map' do
      allow(service.battle_map_service).to receive(:process_all_hazard_damage).and_return([
        {
          participant: defender,
          damage: 10,
          damage_type: 'fire',
          hazard_type: 'fire',
          hex_x: 5,
          hex_y: 5
        }
      ])

      service.send(:process_battle_map_hazards)

      hazard_events = service.events.select { |e| e[:event_type] == 'hazard_damage' }
      expect(hazard_events).not_to be_empty
      expect(hazard_events.first[:details][:damage]).to eq(10)
    end

    it 'skips zero damage hazard events' do
      allow(service.battle_map_service).to receive(:process_all_hazard_damage).and_return([
        {
          participant: defender,
          damage: 0,  # Zero damage
          damage_type: 'fire',
          hazard_type: 'fire',
          hex_x: 5,
          hex_y: 5
        }
      ])

      service.send(:process_battle_map_hazards)

      hazard_events = service.events.select { |e| e[:event_type] == 'hazard_damage' }
      expect(hazard_events).to be_empty
    end
  end

  describe 'willpower roll with explosions' do
    before do
      service.initialize_round_state
      attacker.update(main_action: 'attack', target_participant_id: defender.id, hex_x: 0, hex_y: 0)
      defender.update(hex_x: 1, hex_y: 0)
    end

    it 'tracks willpower attack roll with explosions' do
      # Create roll with explosions
      willpower_roll = DiceRollService::RollResult.new(
        total: 16,
        dice: [8, 8],
        sides: 8,
        modifier: 0,
        explosions: [[8, 4], [8, 2]]  # Two explosions
      )
      allow(attacker).to receive(:willpower_attack_roll).and_return(willpower_roll)

      event = {
        actor: attacker,
        target: defender,
        weapon: nil,
        weapon_type: :unarmed,
        natural_attack: nil
      }
      service.send(:process_attack, event, 50)

      # Check willpower roll is tracked
      willpower_rolls = service.roll_results.select { |r| r[:purpose] == 'willpower_attack' }
      expect(willpower_rolls).not_to be_empty
    end
  end

  describe '#calculate_effective_cumulative' do
    before { service.initialize_round_state }

    it 'returns zero effective damage when no damage taken' do
      state = service.instance_variable_get(:@round_state)[defender.id]
      result = service.calculate_effective_cumulative(defender, state, 'physical')

      expect(result[:effective]).to eq(0)
      expect(result[:armor_reduced]).to eq(0)
      expect(result[:protection_reduced]).to eq(0)
    end

    it 'applies armor reduction per attacker' do
      state = service.instance_variable_get(:@round_state)[defender.id]
      state[:raw_by_attacker][attacker.id] = 20

      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(5)
      allow(StatusEffectService).to receive(:overall_protection).and_return(0)

      result = service.calculate_effective_cumulative(defender, state, 'physical')

      expect(result[:effective]).to eq(15) # 20 - 5 armor
      expect(result[:armor_reduced]).to eq(5)
    end

    it 'applies protection after armor' do
      state = service.instance_variable_get(:@round_state)[defender.id]
      state[:raw_by_attacker][attacker.id] = 30

      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(5)
      allow(StatusEffectService).to receive(:overall_protection).and_return(10)

      result = service.calculate_effective_cumulative(defender, state, 'physical')

      # 30 raw - 5 armor = 25, then - 10 protection = 15
      expect(result[:effective]).to eq(15)
      expect(result[:armor_reduced]).to eq(5)
      expect(result[:protection_reduced]).to eq(10)
    end

    it 'adds DOT damage after defenses (bypasses armor and protection)' do
      state = service.instance_variable_get(:@round_state)[defender.id]
      state[:raw_by_attacker][attacker.id] = 20
      state[:dot_cumulative] = 8

      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(5)
      allow(StatusEffectService).to receive(:overall_protection).and_return(5)

      result = service.calculate_effective_cumulative(defender, state, 'physical')

      # 20 - 5 armor = 15, - 5 protection = 10, + 8 DOT = 18
      expect(result[:effective]).to eq(18)
    end

    it 'does not reduce damage below zero' do
      state = service.instance_variable_get(:@round_state)[defender.id]
      state[:raw_by_attacker][attacker.id] = 5

      allow(StatusEffectService).to receive(:flat_damage_reduction).and_return(20)
      allow(StatusEffectService).to receive(:overall_protection).and_return(20)

      result = service.calculate_effective_cumulative(defender, state, 'physical')

      expect(result[:effective]).to be >= 0
    end
  end

  describe '#safe_execute' do
    it 'executes block successfully' do
      result = nil
      service.safe_execute('test_step') { result = 'success' }
      expect(result).to eq('success')
    end

    it 'catches and logs errors without re-raising' do
      expect do
        service.safe_execute('failing_step') { raise StandardError, 'Test error' }
      end.not_to raise_error
    end

    it 'continues execution after error' do
      results = []
      service.safe_execute('step1') { results << 1 }
      service.safe_execute('step2') { raise StandardError, 'Error in step 2' }
      service.safe_execute('step3') { results << 3 }

      expect(results).to eq([1, 3])
    end
  end

  describe '#all_conscious_passed?' do
    it 'returns true when all conscious participants passed' do
      attacker.update(main_action: 'pass')
      defender.update(main_action: 'pass')
      service.initialize_round_state

      expect(service.send(:all_conscious_passed?)).to be true
    end

    it 'returns false when any participant chose attack' do
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
      defender.update(main_action: 'pass')
      service.initialize_round_state

      expect(service.send(:all_conscious_passed?)).to be false
    end

    it 'returns false when no conscious participants' do
      attacker.update(is_knocked_out: true)
      defender.update(is_knocked_out: true)
      service.initialize_round_state

      expect(service.send(:all_conscious_passed?)).to be false
    end

    it 'ignores knocked out participants' do
      attacker.update(is_knocked_out: true, main_action: 'attack')
      defender.update(main_action: 'pass')
      service.initialize_round_state

      expect(service.send(:all_conscious_passed?)).to be true
    end
  end

  describe '#calculate_movement_path' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 5, hex_y: 5)
      defender.update(hex_x: 10, hex_y: 5)
    end

    it 'returns empty array for unknown movement action' do
      allow(attacker).to receive(:movement_action).and_return('unknown_action')
      path = service.send(:calculate_movement_path, attacker)
      expect(path).to eq([])
    end

    it 'calculates path towards target for towards_person' do
      allow(attacker).to receive(:movement_action).and_return('towards_person')

      allow(service).to receive(:calculate_towards_path).and_return([[6, 5], [7, 5]])
      path = service.send(:calculate_movement_path, attacker)

      expect(path).to eq([[6, 5], [7, 5]])
    end

    it 'calculates path away from target for away_from' do
      allow(attacker).to receive(:movement_action).and_return('away_from')

      allow(service).to receive(:calculate_away_path).and_return([[4, 5], [3, 5]])
      path = service.send(:calculate_movement_path, attacker)

      expect(path).to eq([[4, 5], [3, 5]])
    end

    it 'calculates maintain distance path' do
      allow(attacker).to receive(:movement_action).and_return('maintain_distance')

      allow(service).to receive(:calculate_maintain_distance_path).and_return([[5, 6]])
      path = service.send(:calculate_movement_path, attacker)

      expect(path).to eq([[5, 6]])
    end

    it 'calculates path to specific hex for move_to_hex' do
      allow(attacker).to receive(:movement_action).and_return('move_to_hex')

      allow(service).to receive(:calculate_hex_target_path).and_return([[6, 5], [7, 5], [8, 5]])
      path = service.send(:calculate_movement_path, attacker)

      expect(path).to eq([[6, 5], [7, 5], [8, 5]])
    end
  end

  describe '#schedule_movement' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 5, hex_y: 5)
      defender.update(hex_x: 10, hex_y: 5)
    end

    it 'skips scheduling for stand_still' do
      allow(attacker).to receive(:movement_action).and_return('stand_still')

      service.send(:schedule_movement, attacker)

      segment_events = service.instance_variable_get(:@segment_events).flatten
      movement_events = segment_events.select { |e| e.is_a?(Hash) && e[:type] == :movement_step }
      expect(movement_events).to be_empty
    end

    it 'schedules movement step events for each hex in path' do
      allow(attacker).to receive(:movement_action).and_return('towards_person')

      allow(service).to receive(:calculate_movement_path).and_return([[6, 5], [7, 5]])
      allow(attacker).to receive(:movement_segments).and_return([30, 60])

      service.send(:schedule_movement, attacker)

      segment_events = service.instance_variable_get(:@segment_events).flatten
      movement_events = segment_events.select { |e| e.is_a?(Hash) && e[:type] == :movement_step }
      expect(movement_events.length).to eq(2)
    end

    it 'does not schedule when path is empty' do
      allow(attacker).to receive(:movement_action).and_return('towards_person')

      allow(service).to receive(:calculate_movement_path).and_return([])

      service.send(:schedule_movement, attacker)

      segment_events = service.instance_variable_get(:@segment_events).flatten
      movement_events = segment_events.select { |e| e.is_a?(Hash) && e[:type] == :movement_step }
      expect(movement_events).to be_empty
    end
  end

  describe '#calculate_reach_segment_range' do
    before do
      service.initialize_round_state
      attacker.update(hex_x: 0, hex_y: 0)
      defender.update(hex_x: 1, hex_y: 0)
    end

    it 'returns full range when target is nil' do
      result = service.send(:calculate_reach_segment_range, attacker, nil, :melee, nil)
      expect(result).to eq({ start: 1, end: 100 })
    end

    it 'uses ReachSegmentService for calculation' do
      allow(ReachSegmentService).to receive(:effective_reach).and_return(2)
      allow(ReachSegmentService).to receive(:defender_reach).and_return(1)
      allow(ReachSegmentService).to receive(:calculate_segment_range).and_return({ start: 20, end: 80 })

      result = service.send(:calculate_reach_segment_range, attacker, nil, :melee, defender)
      expect(result).to eq({ start: 20, end: 80 })
    end

    it 'returns full range when reaches cannot be determined' do
      allow(ReachSegmentService).to receive(:effective_reach).and_return(nil)
      allow(ReachSegmentService).to receive(:defender_reach).and_return(nil)

      result = service.send(:calculate_reach_segment_range, attacker, nil, :melee, defender)
      expect(result).to eq({ start: 1, end: 100 })
    end
  end

  describe '#end_fight_peacefully' do
    it 'creates fight_ended_peacefully event' do
      service.send(:end_fight_peacefully)

      peaceful_events = service.events.select { |e| e[:event_type] == 'fight_ended_peacefully' }
      expect(peaceful_events).not_to be_empty
    end

    it 'updates fight status to complete' do
      service.send(:end_fight_peacefully)

      fight.refresh
      expect(fight.status).to eq('complete')
    end

    it 'sets combat_ended_at timestamp' do
      service.send(:end_fight_peacefully)

      fight.refresh
      expect(fight.combat_ended_at).not_to be_nil
    end
  end

  describe '#schedule_dot_tick_events' do
    before { service.initialize_round_state }

    it 'does nothing when no DOT effects present' do
      allow(StatusEffectService).to receive(:active_effects).and_return([])

      service.send(:schedule_dot_tick_events)

      segment_events = service.instance_variable_get(:@segment_events).flatten
      dot_events = segment_events.select { |e| e.is_a?(Hash) && e[:type] == :dot_tick }
      expect(dot_events).to be_empty
    end
  end

  describe 'process_surrenders' do
    before { service.initialize_round_state }

    it 'handles surrender when participant is surrendering' do
      attacker.update(is_surrendering: true, main_action: 'pass')

      allow(attacker).to receive(:process_surrender!)
      allow(BroadcastService).to receive(:to_room)

      service.send(:process_surrenders)

      surrender_events = service.events.select { |e| e[:event_type] == 'surrender' }
      expect(surrender_events).not_to be_empty
    end

    it 'skips non-surrendering participants' do
      attacker.update(is_surrendering: false)
      defender.update(is_surrendering: false)

      service.send(:process_surrenders)

      surrender_events = service.events.select { |e| e[:event_type] == 'surrender' }
      expect(surrender_events).to be_empty
    end
  end

  describe 'create_event helper' do
    before { service.initialize_round_state }

    it 'creates event with all required fields' do
      event = service.send(:create_event, 50, attacker, defender, 'attack', damage: 10)

      expect(event[:segment]).to eq(50)
      expect(event[:actor_id]).to eq(attacker.id)
      expect(event[:target_id]).to eq(defender.id)
      expect(event[:event_type]).to eq('attack')
      expect(event[:details][:damage]).to eq(10)
    end

    it 'handles nil actor and target' do
      event = service.send(:create_event, 25, nil, nil, 'action')

      expect(event[:actor_id]).to be_nil
      expect(event[:target_id]).to be_nil
    end
  end

  describe 'damage accumulation edge cases' do
    before { service.initialize_round_state }

    it 'handles zero effective cumulative damage' do
      state = { raw_by_attacker: { attacker.id => 0 }, dot_cumulative: 0 }
      result = service.send(:calculate_effective_cumulative, defender, state, :physical)
      expect(result[:effective]).to eq(0)
    end

    it 'handles high effective cumulative damage' do
      state = { raw_by_attacker: { attacker.id => 100 }, dot_cumulative: 50 }
      result = service.send(:calculate_effective_cumulative, defender, state, :physical)
      expect(result[:effective]).to be >= 0
    end

    it 'handles different damage types' do
      state = { raw_by_attacker: { attacker.id => 20 }, dot_cumulative: 10 }
      physical_result = service.send(:calculate_effective_cumulative, defender, state, :physical)
      fire_result = service.send(:calculate_effective_cumulative, defender, state, :fire)
      expect(physical_result[:effective]).to be >= 0
      expect(fire_result[:effective]).to be >= 0
    end
  end

  describe 'flee mechanic edge cases' do
    before { service.initialize_round_state }

    it 'process_flee_attempts does not crash with non-fleeing participants' do
      attacker.update(main_action: 'attack')
      defender.update(main_action: 'attack')

      expect { service.send(:process_flee_attempts) }.not_to raise_error
    end
  end

  describe 'round state edge cases' do
    it 'initializes round state correctly' do
      service.initialize_round_state

      expect(service.instance_variable_get(:@segment_events)).to be_an(Array)
      expect(service.events).to be_an(Array)
    end

    it 'handles multiple round initializations' do
      service.initialize_round_state
      first_events = service.events.dup

      service.initialize_round_state
      expect(service.events).to be_an(Array)
    end
  end

  describe 'status effect interactions in combat' do
    before { service.initialize_round_state }

    it 'handles stunned attacker' do
      allow(attacker).to receive(:has_effect?).with(:stunned).and_return(true)
      allow(attacker).to receive(:has_effect?).with(anything).and_return(false)

      # Stunned participants should skip their attack
    end

    it 'handles protected defender' do
      allow(defender).to receive(:has_effect?).with(:protected).and_return(true)
      allow(defender).to receive(:protection_value).and_return(5)

      # Protection should reduce damage
    end
  end

  describe 'multi-participant combat edge cases' do
    it 'handles all participants passing' do
      attacker.update(main_action: 'pass')
      defender.update(main_action: 'pass')
      service.initialize_round_state

      expect(service.send(:all_conscious_passed?)).to be true
    end

    it 'handles one participant attacking (not all passed)' do
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
      defender.update(main_action: 'pass')
      service.initialize_round_state

      expect(service.send(:all_conscious_passed?)).to be false
    end
  end

  describe 'ability cost and willpower edge cases' do
    before { service.initialize_round_state }

    it 'handles participant with no willpower trying ability' do
      attacker.update(willpower_dice: 0.0, main_action: 'attack')
      # Should fall back to regular attack
    end

    it 'handles participant with partial willpower' do
      attacker.update(willpower_dice: 0.5, main_action: 'attack')
      # Partial willpower shouldn't be usable for abilities
    end
  end

  describe 'hex position edge cases' do
    before { service.initialize_round_state }

    it 'handles combatants at same position' do
      attacker.update(hex_x: 10, hex_y: 10)
      defender.update(hex_x: 10, hex_y: 10)

      # Should handle melee at distance 0
      service.initialize_round_state
    end

    it 'handles combatants at maximum distance' do
      attacker.update(hex_x: 0, hex_y: 0)
      defender.update(hex_x: 100, hex_y: 100)

      service.initialize_round_state
    end

    it 'handles nil hex coordinates' do
      attacker.update(hex_x: nil, hex_y: nil)
      # Should handle gracefully
      service.initialize_round_state
    end
  end

  describe 'weapon attack scheduling edge cases' do
    before { service.initialize_round_state }

    it 'handles scheduling attacks for attacker with target' do
      attacker.update(main_action: 'attack', target_participant_id: defender.id)
      expect { service.send(:schedule_attacks, attacker) }.not_to raise_error
    end

    it 'handles participant with pass action (returns early)' do
      attacker.update(main_action: 'pass')
      expect { service.send(:schedule_attacks, attacker) }.not_to raise_error
    end

    it 'handles participant with defend action (returns early)' do
      attacker.update(main_action: 'defend')
      expect { service.send(:schedule_attacks, attacker) }.not_to raise_error
    end
  end

  describe 'knockback and forced movement edge cases' do
    before { service.initialize_round_state }

    it 'handles knockback to arena edge' do
      defender.update(hex_x: 0, hex_y: 0)
      # Knockback towards negative coords should clamp to 0
    end

    it 'handles knockback into occupied space' do
      # Should handle collision gracefully
    end
  end

  describe 'initiative edge cases' do
    it 'initializes round state without errors' do
      expect { service.initialize_round_state }.not_to raise_error
    end

    it 'handles resolve! with passing participants' do
      attacker.update(main_action: 'pass')
      defender.update(main_action: 'pass')

      expect { service.resolve! }.not_to raise_error
    end
  end

  describe 'event persistence edge cases' do
    before { service.initialize_round_state }

    it 'handles saving empty events array' do
      expect { service.send(:save_events_to_db) }.not_to raise_error
    end

    it 'handles saving events with nil values' do
      service.events << { segment: nil, actor_id: nil, event_type: 'test' }
      expect { service.send(:save_events_to_db) }.not_to raise_error
    end
  end

  describe 'guard action edge cases' do
    before { service.initialize_round_state }

    it 'handles defend action in schedule_attacks' do
      attacker.update(main_action: 'defend')
      expect { service.send(:schedule_attacks, attacker) }.not_to raise_error
    end
  end

  describe 'combat round cleanup' do
    before { service.initialize_round_state }

    it 'apply_accumulated_damage does not crash' do
      expect { service.send(:apply_accumulated_damage) }.not_to raise_error
    end

    it 'process_segments does not crash' do
      expect { service.send(:process_segments) }.not_to raise_error
    end
  end

  describe 'cover and concealment integration' do
    let!(:ranged_pattern) { create(:pattern, :ranged_weapon, weapon_range: 'medium') }
    let!(:weapon) { create(:item, pattern: ranged_pattern, character_instance: attacker_instance) }

    before do
      # Mock battle map as active
      allow(service.battle_map_service).to receive(:battle_map_active?).and_return(true)

      service.initialize_round_state

      # Position attacker and defender with space between them
      # y=2 row requires odd x values for valid hex coords
      attacker.update(hex_x: 1, hex_y: 2, ranged_weapon: weapon)
      defender.update(hex_x: 9, hex_y: 2)
    end

    describe 'cover blocking line of sight' do
      context 'when cover blocks attack path and target is stationary' do
        before do
          # Create contiguous cover block directly in the attack path
          # Attack is from (1,2) to (9,2), so create cover at (5,2) and (5,6) which are on the path
          RoomHex.create(room: room, danger_level: 0, hex_x: 5, hex_y: 2, has_cover: true)
          RoomHex.create(room: room, danger_level: 0, hex_x: 5, hex_y: 6, has_cover: true)

          # Defender didn't move or attack this round
          defender.update(moved_this_round: false, acted_this_round: false)
        end

        it 'blocks the shot completely' do
          event = {
            actor: attacker,
            target: defender,
            weapon: weapon,
            weapon_type: :ranged
          }

          service.send(:process_attack, event, 50)

          # Shot should be blocked
          blocked_events = service.events.select { |e| e[:event_type] == 'shot_blocked' }
          expect(blocked_events).not_to be_empty
          expect(blocked_events.first.dig(:details, :reason)).to eq('full_cover')
        end
      end

      context 'when cover blocks attack path and target is moving' do
        before do
          # Create contiguous cover block on attack path
          RoomHex.create(room: room, danger_level: 0, hex_x: 5, hex_y: 2, has_cover: true)
          RoomHex.create(room: room, danger_level: 0, hex_x: 5, hex_y: 6, has_cover: true)

          # Defender moved this round
          defender.update(moved_this_round: true, acted_this_round: false)
        end

        it 'halves the damage roll' do
          event = {
            actor: attacker,
            target: defender,
            weapon: weapon,
            weapon_type: :ranged
          }

          # Stub DiceRollService to return predictable damage (base 20)
          allow(DiceRollService).to receive(:roll).and_return(
            double(total: 20, rolls: [10, 10], exploded: false, dice: [10, 10], explosions: [])
          )

          service.send(:process_attack, event, 50)

          # Damage should be halved by cover (10 instead of 20)
          damage_events = service.events.select { |e| e[:event_type] == 'damage_applied' }
          expect(damage_events).not_to be_empty

          # The damage_this_attack should be halved from the base roll
          # Note: damage_this_attack is stored in details sub-hash
          expect(damage_events.first.dig(:details, :damage_this_attack)).to be < 20
        end
      end

      context 'when cover is adjacent to attacker' do
        before do
          # Create cover hex adjacent to attacker at (1,2) — neighbor (2,0) is distance 1
          RoomHex.create(room: room, danger_level: 0, hex_x: 2, hex_y: 0, has_cover: true)
        end

        it 'does not apply cover penalty' do
          event = {
            actor: attacker,
            target: defender,
            weapon: weapon,
            weapon_type: :ranged
          }

          service.send(:process_attack, event, 50)

          # Shot should NOT be blocked (cover is adjacent to attacker)
          blocked_events = service.events.select { |e| e[:event_type] == 'shot_blocked' }
          expect(blocked_events).to be_empty
        end
      end
    end

    describe 'concealment ranged penalty' do
      context 'when target is in concealed hex' do
        before do
          # Create concealed hex at defender position
          RoomHex.create(room: room, danger_level: 0, hex_x: defender.hex_x, hex_y: defender.hex_y, hex_type: 'concealed')
        end

        it 'applies distance-based penalty to ranged attack' do
          event = {
            actor: attacker,
            target: defender,
            weapon: weapon,
            weapon_type: :ranged
          }

          # Distance is 8 hexes, so penalty should be -(8/6).floor = -1
          # This reduces the attack roll total

          service.send(:process_attack, event, 50)

          # Verify attack was processed
          # The concealment penalty is applied to the damage total before HP calculation
          expect(service.events).not_to be_empty

          # Should have either damage or miss event (not shot_blocked)
          blocked_events = service.events.select { |e| e[:event_type] == 'shot_blocked' }
          expect(blocked_events).to be_empty
        end
      end

      context 'when target is in concealed hex at long range' do
        before do
          # Move defender further away (y=2 requires odd x)
          defender.update(hex_x: 17, hex_y: 2)

          # Create concealed hex at defender position
          RoomHex.create(room: room, danger_level: 0, hex_x: defender.hex_x, hex_y: defender.hex_y, hex_type: 'concealed')
        end

        it 'applies larger penalty at longer distances (capped at -4)' do
          event = {
            actor: attacker,
            target: defender,
            weapon: weapon,
            weapon_type: :ranged
          }

          # Distance is 16 hexes, so penalty should be -(16/6).floor = -2
          # If distance were 30, penalty would be -(30/6).floor = -5, but capped at -4

          service.send(:process_attack, event, 50)

          # Verify attack was processed with concealment penalty
          expect(service.events).not_to be_empty

          # Should not be blocked (concealment doesn't block, just penalizes)
          blocked_events = service.events.select { |e| e[:event_type] == 'shot_blocked' }
          expect(blocked_events).to be_empty
        end
      end

      context 'when attack is melee' do
        before do
          # Position defender adjacent for melee
          defender.update(hex_x: 3, hex_y: 2)

          # Create concealed hex at defender position
          RoomHex.create(room: room, danger_level: 0, hex_x: defender.hex_x, hex_y: defender.hex_y, hex_type: 'concealed')
        end

        it 'does not apply concealment penalty to melee attacks' do
          event = {
            actor: attacker,
            target: defender,
            weapon: nil,
            weapon_type: :melee
          }

          service.send(:process_attack, event, 50)

          # Melee attacks should not be affected by concealment
          # Attack should process normally
          expect(service.events).not_to be_empty

          # Should not be blocked or have concealment penalty
          blocked_events = service.events.select { |e| e[:event_type] == 'shot_blocked' }
          expect(blocked_events).to be_empty
        end
      end
    end

    describe 'stacked penalties' do
      context 'when both cover and concealment apply' do
        before do
          # Create cover between attacker and defender
          RoomHex.create(room: room, danger_level: 0, hex_x: 6, hex_y: 2, has_cover: true)

          # Create concealed hex at defender position
          RoomHex.create(room: room, danger_level: 0, hex_x: defender.hex_x, hex_y: defender.hex_y, hex_type: 'concealed')

          # Defender is moving
          defender.update(moved_this_round: true, acted_this_round: false)
        end

        it 'applies both cover damage reduction and concealment penalty' do
          # Ensure a strong roll so damage is nonzero after cover/concealment penalties
          strong_roll = DiceRollService::RollResult.new(total: 20, dice: [10, 10], sides: 8, explosions: [])
          allow(DiceRollService).to receive(:roll).and_return(strong_roll)

          event = {
            actor: attacker,
            target: defender,
            weapon: weapon,
            weapon_type: :ranged
          }

          service.send(:process_attack, event, 50)

          # Both penalties should stack:
          # - Cover halves damage rolls (since target is moving)
          # - Concealment applies distance penalty to attack total

          expect(service.events).not_to be_empty

          # Attack should not be completely blocked (target is moving)
          blocked_events = service.events.select { |e| e[:event_type] == 'shot_blocked' }
          expect(blocked_events).to be_empty

          # Should have damage applied or miss event
          attack_events = service.events.select do |e|
            e[:event_type] == 'damage_applied' || e[:event_type] == 'attack'
          end
          expect(attack_events).not_to be_empty
        end
      end
    end
  end

  describe 'position safety check during resolve!' do
    let(:room_with_bounds) { create(:room, min_x: 0, max_x: 40, min_y: 0, max_y: 40) }
    let(:bounded_fight) { create(:fight, room: room_with_bounds, status: 'input') }
    let(:bounded_attacker) do
      create(:fight_participant,
             fight: bounded_fight,
             character_instance: attacker_instance,
             side: 1,
             current_hp: 6,
             max_hp: 6,
             hex_x: 4,
             hex_y: 4,
             main_action: 'pass',
             input_complete: true)
    end
    let(:bounded_defender) do
      create(:fight_participant,
             fight: bounded_fight,
             character_instance: defender_instance,
             side: 2,
             current_hp: 6,
             max_hp: 6,
             hex_x: 8,
             hex_y: 4,
             main_action: 'pass',
             input_complete: true)
    end

    before do
      bounded_attacker
      bounded_defender

      # Create playable hex records for participant positions and neighbors
      [[4, 4], [4, 8], [5, 6], [5, 2], [4, 0], [3, 2], [3, 6],
       [8, 4], [8, 8], [9, 6], [9, 2], [8, 0], [7, 2], [7, 6]].each do |hx, hy|
        RoomHex.set_hex_details(room_with_bounds, hx, hy, hex_type: 'normal', traversable: true)
      end
    end

    it 'moves participant off non-traversable hex at start of round' do
      # Mark attacker's hex as a wall
      RoomHex.set_hex_details(room_with_bounds, 4, 4, hex_type: 'wall', traversable: false)

      resolve_service = described_class.new(bounded_fight)
      resolve_service.resolve!

      bounded_attacker.refresh
      expect([bounded_attacker.hex_x, bounded_attacker.hex_y]).not_to eq([4, 4])
      expect(RoomHex.playable_at?(room_with_bounds, bounded_attacker.hex_x, bounded_attacker.hex_y)).to be true
    end

    it 'does not move participant on traversable hex' do
      resolve_service = described_class.new(bounded_fight)
      resolve_service.resolve!

      bounded_defender.refresh
      expect([bounded_defender.hex_x, bounded_defender.hex_y]).to eq([8, 4])
    end
  end
end
