# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CombatActionService do
  let(:room) { create(:room) }
  let(:fight) { create(:fight, room: room, round_number: 1, status: 'input') }
  let(:participant) { create(:fight_participant, fight: fight, hex_x: 5, hex_y: 4, current_hp: 5, max_hp: 5) }
  let(:target) { create(:fight_participant, :side_2, fight: fight, hex_x: 6, hex_y: 4, current_hp: 5, max_hp: 5) }
  let(:service) { described_class.new(participant) }
  let(:ally) { create(:fight_participant, fight: fight, side: participant.side, hex_x: 4, hex_y: 4, current_hp: 5, max_hp: 5) }

  before do
    participant
    target
  end

  describe '.process_map_action' do
    it 'creates new service and processes action' do
      result = described_class.process_map_action(participant, 'pass', nil)
      expect(result[:success]).to be true
    end
  end

  describe '#initialize' do
    it 'sets participant and fight' do
      expect(service.participant).to eq(participant)
      expect(service.fight).to eq(fight)
    end
  end

  describe '#process' do
    describe 'combat phase guards' do
      it 'rejects actions while round is locked' do
        fight.update(round_locked: true, status: 'resolving')

        result = service.process('pass', nil)

        expect(result[:success]).to be false
        expect(result[:error]).to include('resolving')
      end

      it 'rejects actions when fight is not accepting input' do
        fight.update(status: 'narrative', round_locked: false)

        result = service.process('pass', nil)

        expect(result[:success]).to be false
        expect(result[:error]).to include('closed')
      end
    end

    describe 'movement actions' do
      # NOTE: These tests are skipped due to mass assignment restrictions in FightParticipant
      # The service code tries to update restricted columns - this is a service bug to fix later
      it 'processes stand_still' do
        result = service.process('stand_still', nil)
        expect(result[:success]).to be true
      end

      it 'processes move_to_hex' do
        result = service.process('move_to_hex', { 'hex_x' => 7, 'hex_y' => 4 })
        expect(result[:success]).to be true
      end

      it 'rejects malformed move_to_hex payloads' do
        result = service.process('move_to_hex', 'bad-payload')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid payload')
      end

      it 'processes move_toward' do
        result = service.process('move_toward', target.id.to_s)
        expect(result[:success]).to be true
      end

      it 'processes move_away' do
        result = service.process('move_away', target.id.to_s)
        expect(result[:success]).to be true
      end

      it 'processes maintain_distance' do
        result = service.process('maintain_distance', target.id.to_s)
        expect(result[:success]).to be true
      end
    end

    describe 'main actions' do
      it 'processes attack' do
        result = service.process('attack', target.id.to_s)
        expect(result[:success]).to be true
      end

      it 'processes attack without target' do
        result = service.process('attack', nil)
        expect(result[:success]).to be true
      end

      it 'rejects attack with invalid target id' do
        result = service.process('attack', '999999')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Target not found')
      end

      it 'rejects attack when targeting self' do
        result = service.process('attack', participant.id.to_s)
        expect(result[:success]).to be false
        expect(result[:error]).to include('yourself')
      end

      it 'rejects attack when target is knocked out' do
        target.update(is_knocked_out: true)
        result = service.process('attack', target.id.to_s)
        expect(result[:success]).to be false
        expect(result[:error]).to include('knocked out')
      end

      it 'rejects attack against same-side participants' do
        ally
        result = service.process('attack', ally.id.to_s)
        expect(result[:success]).to be false
        expect(result[:error]).to include('your side')
      end

      it 'processes defend' do
        result = service.process('defend', nil)
        expect(result[:success]).to be true
        expect(result[:message]).to include('Full Defense')
      end

      it 'processes dodge' do
        result = service.process('dodge', nil)
        expect(result[:success]).to be true
      end

      it 'processes sprint' do
        result = service.process('sprint', nil)
        expect(result[:success]).to be true
      end

      it 'processes pass' do
        result = service.process('pass', nil)
        expect(result[:success]).to be true
      end

      it 'processes set_target' do
        result = service.process('set_target', target.id.to_s)
        expect(result[:success]).to be true
      end

      it 'rejects targeting self' do
        result = service.process('set_target', participant.id.to_s)
        expect(result[:success]).to be false
        expect(result[:error]).to include('yourself')
      end

      it 'rejects targeting knocked out participant' do
        target.update(is_knocked_out: true)
        result = service.process('set_target', target.id.to_s)
        expect(result[:success]).to be false
        expect(result[:error]).to include('knocked out')
      end

      it 'rejects targeting same-side participants' do
        ally
        result = service.process('set_target', ally.id.to_s)
        expect(result[:success]).to be false
        expect(result[:error]).to include('your side')
      end
    end

    describe 'willpower actions' do
      it 'processes willpower_skip' do
        result = service.process('willpower_skip', nil)
        expect(result[:success]).to be true
        expect(result[:message]).to include('Saving dice')
      end

      it 'deducts and reallocates willpower consistently for map actions' do
        updates = {
          willpower_dice: 3.0,
          willpower_attack: 0,
          willpower_defense: 0,
          willpower_ability: 0
        }
        updates[:willpower_movement] = 0 if FightParticipant.columns.include?(:willpower_movement)
        participant.update(updates)

        first = service.process('willpower_attack', '2')
        expect(first[:success]).to be true
        expect(participant.reload.willpower_dice).to eq(1.0)
        expect(participant.willpower_attack).to eq(2)

        second = service.process('willpower_defense', '1')
        expect(second[:success]).to be true
        participant.reload
        expect(participant.willpower_dice).to eq(2.0) # Refund one when reallocating 2 -> 1
        expect(participant.willpower_attack).to eq(0)
        expect(participant.willpower_defense).to eq(1)
      end

      context 'when participant has willpower dice available' do
        before do
          allow(participant).to receive(:available_willpower_dice).and_return(3)
        end

        it 'processes willpower_attack' do
          result = service.process('willpower_attack', '2')
          expect(result[:success]).to be true
          expect(result[:message]).to include('attack damage')
        end

        it 'processes willpower_defense' do
          result = service.process('willpower_defense', '1')
          expect(result[:success]).to be true
          expect(result[:message]).to include('defense')
        end

        it 'processes willpower_ability' do
          result = service.process('willpower_ability', '2')
          expect(result[:success]).to be true
          expect(result[:message]).to include('ability damage')
        end

        it 'rejects spending more than available' do
          result = service.process('willpower_attack', '5')
          expect(result[:success]).to be false
          expect(result[:error]).to include('max')
        end

        it 'rejects spending less than 1' do
          result = service.process('willpower_attack', '0')
          expect(result[:success]).to be false
          expect(result[:error]).to include('at least 1')
        end
      end

      context 'when participant has no willpower dice' do
        before do
          allow(participant).to receive(:available_willpower_dice).and_return(0)
        end

        it 'rejects willpower spending' do
          result = service.process('willpower_attack', '1')
          expect(result[:success]).to be false
          expect(result[:error]).to include('No willpower')
        end
      end
    end

    describe 'tactical actions' do
      it 'processes aggressive stance' do
        result = service.process('tactical', 'aggressive')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Aggressive')
      end

      it 'processes defensive stance' do
        result = service.process('tactical', 'defensive')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Defensive')
      end

      it 'processes quick stance' do
        result = service.process('tactical', 'quick')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Quick')
      end

      it 'processes tactical none' do
        result = service.process('tactical', 'none')
        expect(result[:success]).to be true
        expect(result[:message]).to include('None')
      end

      it 'rejects invalid tactical stance' do
        result = service.process('tactical', 'invalid_stance')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Invalid')
      end

      it 'processes guard stance' do
        result = service.process('tactical', 'guard')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Guard')
      end

      it 'processes back_to_back stance' do
        result = service.process('tactical', 'back_to_back')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Back to Back')
      end
    end

    describe 'ability actions' do
      let(:ability_mock) { double('Ability', id: 1001, name: 'Test Strike', key: 'test_strike', target_type: 'enemy') }
      let(:self_ability_mock) { double('Ability', id: 1002, name: 'Self Heal', key: 'self_heal', target_type: 'self') }
      let(:ally_ability_mock) { double('Ability', id: 1004, name: 'Ally Shield', key: 'ally_shield', target_type: 'ally') }

      context 'use_ability' do
        before do
          allow(participant).to receive(:available_main_abilities).and_return([ability_mock, self_ability_mock, ally_ability_mock])
          allow(participant).to receive(:available_tactical_abilities).and_return([])
          allow(participant).to receive(:update).and_return(true)
          allow(Ability).to receive(:[]).with(1001).and_return(ability_mock)
          allow(Ability).to receive(:[]).with(1002).and_return(self_ability_mock)
          allow(Ability).to receive(:[]).with(1004).and_return(ally_ability_mock)
        end

        it 'processes use_ability with target' do
          result = service.process('use_ability', { 'ability_id' => 1001, 'target_id' => target.id })
          expect(result[:success]).to be true
          expect(result[:message]).to include('Test Strike')
        end

        it 'processes self-targeted ability' do
          result = service.process('use_ability', { 'ability_id' => 1002 })
          expect(result[:success]).to be true
          expect(result[:message]).to include('Self Heal')
        end

        it 'rejects non-self ability without a target' do
          participant.update(target_participant_id: nil)
          result = service.process('use_ability', { 'ability_id' => 1001 })
          expect(result[:success]).to be false
          expect(result[:error]).to include('Target required')
        end

        it 'rejects ally ability targeting an enemy' do
          result = service.process('use_ability', { 'ability_id' => 1004, 'target_id' => target.id })
          expect(result[:success]).to be false
          expect(result[:error]).to include('Invalid target')
        end

        it 'rejects enemy ability targeting self' do
          result = service.process('use_ability', { 'ability_id' => 1001, 'target_id' => participant.id })
          expect(result[:success]).to be false
          expect(result[:error]).to include('Invalid target')
        end

        it 'rejects unavailable ability' do
          unavailable = double('Ability', id: 1003, name: 'Unavailable')
          allow(Ability).to receive(:[]).with(1003).and_return(unavailable)
          result = service.process('use_ability', { 'ability_id' => 1003 })
          expect(result[:success]).to be false
          expect(result[:error]).to include('not available')
        end

        it 'rejects nonexistent ability' do
          allow(Ability).to receive(:[]).with(999999).and_return(nil)
          result = service.process('use_ability', { 'ability_id' => 999999 })
          expect(result[:success]).to be false
          expect(result[:error]).to include('not found')
        end

        it 'rejects malformed use_ability payloads' do
          result = service.process('use_ability', 'bad-payload')
          expect(result[:success]).to be false
          expect(result[:error]).to include('Invalid payload')
        end
      end

      context 'use_tactical_ability' do
        before do
          allow(participant).to receive(:available_main_abilities).and_return([])
          allow(participant).to receive(:available_tactical_abilities).and_return([ability_mock, self_ability_mock])
          allow(participant).to receive(:update).and_return(true)
          allow(Ability).to receive(:[]).with(1001).and_return(ability_mock)
          allow(Ability).to receive(:[]).with(1002).and_return(self_ability_mock)
        end

        it 'processes tactical ability' do
          result = service.process('use_tactical_ability', { 'ability_id' => 1001, 'target_id' => target.id })
          expect(result[:success]).to be true
          expect(result[:message]).to include('Test Strike')
        end

        it 'processes self-targeted tactical ability without target_id' do
          result = service.process('use_tactical_ability', { 'ability_id' => 1002 })
          expect(result[:success]).to be true
          expect(result[:message]).to include('Self Heal')
        end

        it 'rejects non-self tactical ability when no target is available' do
          participant.update(target_participant_id: nil)
          result = service.process('use_tactical_ability', { 'ability_id' => 1001 })
          expect(result[:success]).to be false
          expect(result[:error]).to include('Target required')
        end

        it 'rejects unavailable tactical ability' do
          unavailable = double('Ability', id: 1003)
          allow(Ability).to receive(:[]).with(1003).and_return(unavailable)
          result = service.process('use_tactical_ability', '1003')
          expect(result[:success]).to be false
          expect(result[:error]).to include('not available')
        end
      end
    end

    describe 'surrender action' do
      it 'processes surrender' do
        result = service.process('surrender', nil)
        expect(result[:success]).to be true
        expect(result[:message]).to include('Surrender')
      end
    end

    describe 'flee action' do
      context 'when participant can flee' do
        # Create an adjacent room to the north for flee testing
        let(:location) { room.location }
        let(:north_room) { create(:room, location: location, name: 'Escape Room', min_y: room.max_y, max_y: room.max_y + 100.0) }
        # Flee exit structure mirrors what available_flee_exits returns (exit is the destination Room)
        let(:flee_exit) { { direction: 'north', exit: north_room } }

        before do
          # Ensure north_room is created before available_flee_exits is stubbed
          north_room
          allow(participant).to receive(:can_flee?).and_return(true)
          allow(participant).to receive(:available_flee_exits).and_return([flee_exit])
        end

        it 'processes flee with direction' do
          result = service.process('flee', 'north')
          expect(result[:success]).to be true
          expect(result[:message]).to include('Flee north')
        end

        it 'processes flee with room id' do
          result = service.process('flee', north_room.id.to_s)
          expect(result[:success]).to be true
          expect(result[:message]).to include('Flee')
        end

        it 'rejects invalid flee direction' do
          result = service.process('flee', 'invalid_direction')
          expect(result[:success]).to be false
          expect(result[:error]).to include('Invalid flee direction')
        end
      end

      context 'when participant cannot flee' do
        before do
          allow(participant).to receive(:can_flee?).and_return(false)
        end

        it 'rejects flee' do
          result = service.process('flee', 'north')
          expect(result[:success]).to be false
          expect(result[:error]).to include('Cannot flee')
        end
      end
    end

    describe 'status-dependent actions' do
      describe 'extinguish' do
        context 'when participant is burning' do
          before do
            allow(StatusEffectService).to receive(:has_effect?).with(participant, 'burning').and_return(true)
            allow(StatusEffectService).to receive(:extinguish)
          end

          it 'processes extinguish' do
            result = service.process('extinguish', nil)
            expect(result[:success]).to be true
            expect(result[:message]).to include('Extinguish')
          end
        end

        context 'when participant is not burning' do
          before do
            allow(StatusEffectService).to receive(:has_effect?).with(participant, 'burning').and_return(false)
          end

          it 'rejects extinguish' do
            result = service.process('extinguish', nil)
            expect(result[:success]).to be false
            expect(result[:error]).to include('not on fire')
          end
        end
      end

      describe 'stand_up' do
        context 'when participant is prone' do
          before do
            allow(StatusEffectService).to receive(:is_prone?).with(participant).and_return(true)
            allow(StatusEffectService).to receive(:stand_cost).with(participant).and_return(2)
          end

          it 'processes stand_up' do
            result = service.process('stand_up', nil)
            expect(result[:success]).to be true
            expect(result[:message]).to include('Standing up')
          end
        end

        context 'when participant is not prone' do
          before do
            allow(StatusEffectService).to receive(:is_prone?).with(participant).and_return(false)
          end

          it 'rejects stand_up' do
            result = service.process('stand_up', nil)
            expect(result[:success]).to be false
            expect(result[:error]).to include('not prone')
          end
        end
      end
    end

    describe 'monster mounting actions' do
      let(:mounting_service) { instance_double(MonsterMountingService) }

      before do
        allow(MonsterMountingService).to receive(:new).with(fight).and_return(mounting_service)
      end

      describe 'mount' do
        let(:monster) { double('LargeMonsterInstance', id: 1, display_name: 'Giant Spider') }
        let(:dataset) { double('SequelDataset') }

        context 'when monster is adjacent' do
          before do
            allow(LargeMonsterInstance).to receive(:where)
              .with(id: 1, fight_id: fight.id, status: 'active')
              .and_return(dataset)
            allow(dataset).to receive(:first).and_return(monster)
            allow(mounting_service).to receive(:attempt_mount).with(participant, monster).and_return(success: true)
            allow(participant).to receive(:update).and_return(true)
          end

          it 'processes mount' do
            result = service.process('mount', '1')
            expect(result[:success]).to be true
            expect(result[:message]).to include('Mounting')
          end
        end

        context 'when monster not found' do
          before do
            allow(LargeMonsterInstance).to receive(:where)
              .with(id: 999, fight_id: fight.id, status: 'active')
              .and_return(dataset)
            allow(dataset).to receive(:first).and_return(nil)
          end

          it 'rejects mount' do
            result = service.process('mount', '999')
            expect(result[:success]).to be false
            expect(result[:error]).to include('Monster not found')
          end
        end

        context 'when monster not adjacent' do
          before do
            allow(LargeMonsterInstance).to receive(:where)
              .with(id: 2, fight_id: fight.id, status: 'active')
              .and_return(dataset)
            allow(dataset).to receive(:first).and_return(monster)
            allow(mounting_service).to receive(:attempt_mount).with(participant, monster)
              .and_return(success: false, error: 'Must be adjacent to the monster to mount')
          end

          it 'rejects mount' do
            result = service.process('mount', '2')
            expect(result[:success]).to be false
            expect(result[:error]).to include('adjacent')
          end
        end

        it 'requires monster id' do
          result = service.process('mount', '0')
          expect(result[:success]).to be false
          expect(result[:error]).to include('Monster ID required')
        end
      end

      describe 'climb' do
        let(:monster) { double('LargeMonsterInstance', id: 1) }
        let(:mount_state) { double('MonsterMountState') }

        context 'when mounted' do
          before do
            allow(participant).to receive(:is_mounted).and_return(true)
            allow(participant).to receive(:targeting_monster_id).and_return(1)
            allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
            allow(MonsterMountState).to receive(:first).and_return(mount_state)
            allow(mounting_service).to receive(:process_climb).with(mount_state).and_return(at_weak_point: false)
            allow(participant).to receive(:update).and_return(true)
          end

          it 'processes climb' do
            result = service.process('climb', nil)
            expect(result[:success]).to be true
            expect(result[:message]).to include('Climbing')
          end
        end

        context 'when not mounted' do
          before { allow(participant).to receive(:is_mounted).and_return(false) }

          it 'rejects climb' do
            result = service.process('climb', nil)
            expect(result[:success]).to be false
            expect(result[:error]).to include('Not mounted')
          end
        end
      end

      describe 'cling' do
        let(:monster) { double('LargeMonsterInstance', id: 1) }
        let(:mount_state) { double('MonsterMountState') }

        context 'when mounted' do
          before do
            allow(participant).to receive(:is_mounted).and_return(true)
            allow(participant).to receive(:targeting_monster_id).and_return(1)
            allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
            allow(MonsterMountState).to receive(:first).and_return(mount_state)
            allow(mounting_service).to receive(:process_cling).with(mount_state).and_return(success: true)
            allow(participant).to receive(:update).and_return(true)
          end

          it 'processes cling' do
            result = service.process('cling', nil)
            expect(result[:success]).to be true
            expect(result[:message]).to include('Clinging')
          end
        end

        context 'when not mounted' do
          before { allow(participant).to receive(:is_mounted).and_return(false) }

          it 'rejects cling' do
            result = service.process('cling', nil)
            expect(result[:success]).to be false
            expect(result[:error]).to include('Not mounted')
          end
        end
      end

      describe 'dismount' do
        let(:monster) { double('LargeMonsterInstance', id: 1) }
        let(:mount_state) { double('MonsterMountState') }

        context 'when mounted' do
          before do
            allow(participant).to receive(:is_mounted).and_return(true)
            allow(participant).to receive(:targeting_monster_id).and_return(1)
            allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
            allow(MonsterMountState).to receive(:first).and_return(mount_state)
            allow(mounting_service).to receive(:process_dismount).with(mount_state)
              .and_return(success: true, landing_position: [6, 4])
            allow(participant).to receive(:update).and_return(true)
          end

          it 'processes dismount' do
            result = service.process('dismount', nil)
            expect(result[:success]).to be true
            expect(result[:message]).to include('Dismounting')
          end
        end

        context 'when not mounted' do
          before { allow(participant).to receive(:is_mounted).and_return(false) }

          it 'rejects dismount' do
            result = service.process('dismount', nil)
            expect(result[:success]).to be false
            expect(result[:error]).to include('Not mounted')
          end
        end
      end
    end

    describe 'hex distance helper' do
      it 'uses canonical HexGrid distance calculations' do
        expect(service.send(:hex_distance, -4, -4, -4, 0)).to eq(HexGrid.hex_distance(-4, -4, -4, 0))
      end
    end

    describe 'option actions' do
      describe 'select_melee' do
        before do
          # Mock the objects_dataset to avoid database column issues
          empty_dataset = double('Dataset')
          allow(empty_dataset).to receive(:where).and_return(empty_dataset)
          allow(empty_dataset).to receive(:all).and_return([])
          allow(participant.character_instance).to receive(:objects_dataset).and_return(empty_dataset)
        end

        it 'returns weapon options' do
          result = service.process('select_melee', nil)
          expect(result[:success]).to be true
          expect(result[:options]).to be_an(Array)
          expect(result[:options].first[:name]).to eq('Unarmed')
        end
      end

      describe 'select_ranged' do
        before do
          # Mock the objects_dataset to avoid database column issues
          empty_dataset = double('Dataset')
          allow(empty_dataset).to receive(:where).and_return(empty_dataset)
          allow(empty_dataset).to receive(:all).and_return([])
          allow(participant.character_instance).to receive(:objects_dataset).and_return(empty_dataset)
        end

        it 'returns weapon options' do
          result = service.process('select_ranged', nil)
          expect(result[:success]).to be true
          expect(result[:options]).to be_an(Array)
          expect(result[:options].first[:name]).to eq('None')
        end
      end

      describe 'toggle_autobattle' do
        it 'cycles through autobattle styles' do
          # Start with nil
          result = service.process('toggle_autobattle', nil)
          expect(result[:success]).to be true
          participant.refresh
          expect(participant.autobattle_style).to eq('aggressive')

          # Toggle again
          result = service.process('toggle_autobattle', nil)
          expect(result[:success]).to be true
          participant.refresh
          expect(participant.autobattle_style).to eq('defensive')
        end
      end

      describe 'toggle_hazard' do
        it 'toggles hazard avoidance' do
          result = service.process('toggle_hazard', nil)
          expect(result[:success]).to be true
          participant.refresh
          expect(participant.ignore_hazard_avoidance).to be true

          result = service.process('toggle_hazard', nil)
          expect(result[:success]).to be true
          participant.refresh
          expect(participant.ignore_hazard_avoidance).to be false
        end
      end

      describe 'change_side' do
        it 'changes participant side' do
          result = service.process('change_side', '2')
          expect(result[:success]).to be true
          expect(result[:message]).to include('Side 2')
        end

        it 'rejects invalid side' do
          result = service.process('change_side', '0')
          expect(result[:success]).to be false
          expect(result[:error]).to include('Invalid side')
        end
      end
    end

    describe 'submit_round action' do
      it 'is an alias for done' do
        participant.update(main_action: 'pass', main_action_set: true)
        allow(participant).to receive(:complete_input!)
        allow(fight).to receive(:check_round_resolution)

        result = service.process('submit_round', nil)
        expect(result[:success]).to be true
        expect(result[:input_complete]).to be true
      end
    end

    describe 'tactical_boost action' do
      it 'redirects to tactical' do
        result = service.process('tactical_boost', 'aggressive')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Aggressive')
      end
    end

    describe 'done action' do
      it 'rejects done when main action not set' do
        result = service.process('done', nil)
        expect(result[:success]).to be false
        expect(result[:error]).to include('Main action required')
      end
    end

    describe 'unknown action' do
      it 'returns error for unknown action' do
        result = service.process('unknown_action', nil)
        expect(result[:success]).to be false
        expect(result[:error]).to include('Unknown action')
      end
    end
  end

  describe 'MAX_WILLPOWER_SPEND constant' do
    it 'is set to 2' do
      expect(described_class::MAX_WILLPOWER_SPEND).to eq(2)
    end
  end
end
