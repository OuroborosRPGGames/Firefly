# frozen_string_literal: true

require 'spec_helper'

RSpec.describe CombatQuickmenuHandler do
  let(:room) { create(:room) }
  let(:fight) { create(:fight, room: room, status: 'input') }
  let(:character_instance) { create(:character_instance, current_room: room) }
  let(:participant) do
    create(:fight_participant,
           fight: fight,
           character_instance: character_instance,
           input_stage: 'main_menu',
           side: 1,
           current_hp: 6,
           max_hp: 6)
  end

  describe '.status_text' do
    context 'in normal combat' do
      before { allow(fight).to receive(:spar_mode?).and_return(false) }

      it 'returns HP format' do
        allow(participant).to receive(:fight).and_return(fight)
        expect(described_class.status_text(participant)).to eq('HP: 6/6')
      end
    end

    context 'in spar mode' do
      before { allow(fight).to receive(:spar_mode?).and_return(true) }

      it 'returns touches format' do
        allow(participant).to receive(:fight).and_return(fight)
        allow(participant).to receive(:touch_count).and_return(2)
        expect(described_class.status_text(participant)).to eq('Touches: 2/6')
      end
    end
  end

  describe '.show_menu' do
    it 'creates handler and shows current menu' do
      handler = instance_double(described_class)
      allow(described_class).to receive(:new).and_return(handler)
      allow(handler).to receive(:show_current_menu).and_return({ type: :quickmenu })

      result = described_class.show_menu(participant, character_instance)

      expect(result[:type]).to eq(:quickmenu)
    end
  end

  describe '.handle_response' do
    it 'creates handler and handles response' do
      handler = instance_double(described_class)
      allow(described_class).to receive(:new).and_return(handler)
      allow(handler).to receive(:handle_response).with('main').and_return({ type: :quickmenu })

      result = described_class.handle_response(participant, character_instance, 'main')

      expect(result[:type]).to eq(:quickmenu)
    end
  end

  describe '#show_current_menu' do
    subject(:handler) { described_class.new(participant, character_instance) }

    context 'when on main_menu stage' do
      before { allow(participant).to receive(:input_stage).and_return('main_menu') }

      it 'returns quickmenu with combat actions' do
        allow(participant).to receive_messages(
          main_action_set: false,
          tactical_action_set: false,
          movement_set: false,
          willpower_set: false
        )

        result = handler.show_current_menu

        expect(result[:type]).to eq(:quickmenu)
        expect(result[:prompt]).to eq('Combat Actions:')
        expect(result[:options].map { |o| o[:key] }).to include('main', 'tactical', 'movement', 'willpower', 'options', 'done')
      end
    end

    context 'when stage is done' do
      before { allow(participant).to receive(:input_stage).and_return('done') }

      it 'returns nil' do
        expect(handler.show_current_menu).to be_nil
      end
    end
  end

  describe '#handle_response' do
    subject(:handler) { described_class.new(participant, character_instance) }

    context 'when response is back' do
      it 'returns to main menu' do
        expect(participant).to receive(:update).with(input_stage: 'main_menu')
        allow(participant).to receive(:input_stage).and_return('main_menu')
        allow(participant).to receive_messages(
          main_action_set: false,
          tactical_action_set: false,
          movement_set: false,
          willpower_set: false,
          reload: true
        )

        handler.handle_response('back')
      end
    end

    context 'when response is done on main_menu' do
      before do
        allow(participant).to receive(:input_stage).and_return('main_menu')
        allow(participant).to receive(:main_action_set).and_return(true)
      end

      it 'completes input when can_complete? is true' do
        expect(participant).to receive(:complete_input!)
        allow(fight).to receive(:reload)
        allow(fight).to receive(:all_inputs_complete?).and_return(false)

        handler.handle_response('done')
      end
    end
  end

  describe 'main menu navigation' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(participant).to receive(:input_stage).and_return('main_menu')
    end

    %w[main tactical movement willpower options].each do |choice|
      it "navigates to #{choice} submenu" do
        expected_stage = case choice
                         when 'main' then 'main_action'
                         when 'tactical' then 'tactical_action'
                         else choice
                         end

        expect(participant).to receive(:update).with(input_stage: expected_stage)
        allow(participant).to receive(:reload)
        allow(participant).to receive(:input_complete).and_return(false)
        allow(participant).to receive(:input_stage).and_return(expected_stage)

        handler.send(:handle_main_menu_choice, choice)
      end
    end
  end

  describe 'main action choices' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(participant).to receive(:input_stage).and_return('main_action')
      allow(StatusEffectService).to receive(:can_use_main_action?).and_return(true)
      allow(StatusEffectService).to receive(:has_effect?).and_return(false)
      allow(StatusEffectService).to receive(:is_prone?).and_return(false)
      allow(participant).to receive(:available_main_abilities).and_return([])
    end

    it 'sets attack action and moves to target selection' do
      expect(participant).to receive(:update).with(
        hash_including(main_action: 'attack', main_action_set: true, input_stage: 'main_target')
      )

      handler.send(:handle_main_action_choice, 'attack')
    end

    it 'sets defend action and returns to main menu' do
      expect(participant).to receive(:update).with(
        hash_including(main_action: 'defend', main_action_set: true, input_stage: 'main_menu')
      )

      handler.send(:handle_main_action_choice, 'defend')
    end

    it 'sets dodge action' do
      expect(participant).to receive(:update).with(
        hash_including(main_action: 'dodge', main_action_set: true)
      )

      handler.send(:handle_main_action_choice, 'dodge')
    end

    it 'sets pass action' do
      expect(participant).to receive(:update).with(
        hash_including(main_action: 'pass', main_action_set: true)
      )

      handler.send(:handle_main_action_choice, 'pass')
    end

    it 'sets sprint action' do
      expect(participant).to receive(:update).with(
        hash_including(main_action: 'sprint', main_action_set: true)
      )

      handler.send(:handle_main_action_choice, 'sprint')
    end

    it 'sets surrender action' do
      expect(participant).to receive(:update).with(
        hash_including(main_action: 'surrender', is_surrendering: true, main_action_set: true)
      )

      handler.send(:handle_main_action_choice, 'surrender')
    end
  end

  describe 'main action options building' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(StatusEffectService).to receive(:can_use_main_action?).and_return(true)
      allow(StatusEffectService).to receive(:has_effect?).and_return(false)
      allow(StatusEffectService).to receive(:is_prone?).and_return(false)
      allow(participant).to receive(:available_main_abilities).and_return([])
    end

    it 'includes basic action options' do
      allow(handler).to receive(:unavailable_main_abilities).and_return([])

      options = handler.send(:build_main_action_options)
      keys = options.map { |o| o[:key] }

      expect(keys).to include('attack', 'defend', 'dodge', 'sprint', 'pass', 'surrender', 'back')
    end

    context 'when stunned' do
      before { allow(StatusEffectService).to receive(:can_use_main_action?).and_return(false) }

      it 'shows stunned message' do
        options = handler.send(:build_main_action_options)

        expect(options.first[:key]).to eq('stunned')
        expect(options.first[:disabled]).to be true
      end
    end

    context 'when burning' do
      before { allow(StatusEffectService).to receive(:has_effect?).with(participant, 'burning').and_return(true) }

      it 'includes extinguish option' do
        allow(handler).to receive(:unavailable_main_abilities).and_return([])
        options = handler.send(:build_main_action_options)
        keys = options.map { |o| o[:key] }

        expect(keys).to include('extinguish')
      end
    end

    context 'when prone' do
      before do
        allow(StatusEffectService).to receive(:is_prone?).and_return(true)
        allow(StatusEffectService).to receive(:stand_cost).and_return(2)
      end

      it 'includes stand up option' do
        allow(handler).to receive(:unavailable_main_abilities).and_return([])
        options = handler.send(:build_main_action_options)
        keys = options.map { |o| o[:key] }

        expect(keys).to include('stand')
      end
    end
  end

  describe 'tactical action choices' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(participant).to receive(:input_stage).and_return('tactical_action')
      allow(StatusEffectService).to receive(:can_use_tactical_action?).and_return(true)
    end

    %w[aggressive defensive quick].each do |tactic|
      it "sets #{tactic} tactic" do
        expect(participant).to receive(:update).with(
          hash_including(tactic_choice: tactic, tactical_action_set: true, input_stage: 'main_menu')
        )

        handler.send(:handle_tactical_action_choice, tactic)
      end
    end

    %w[guard back_to_back].each do |tactic|
      it "#{tactic} requires target selection" do
        expect(participant).to receive(:update).with(
          hash_including(tactic_choice: tactic, input_stage: 'tactical_target')
        )

        handler.send(:handle_tactical_action_choice, tactic)
      end
    end

    it 'clears tactic when none selected' do
      expect(participant).to receive(:update).with(
        hash_including(tactic_choice: nil, tactical_action_set: true)
      )

      handler.send(:handle_tactical_action_choice, 'none')
    end
  end

  describe 'movement choices' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(participant).to receive(:input_stage).and_return('movement')
      allow(participant).to receive(:is_mounted).and_return(false)
      allow(participant).to receive(:can_flee?).and_return(false)
      allow(fight).to receive(:has_monster).and_return(false)
      allow(fight).to receive(:active_participants).and_return(
        double(exclude: [])
      )
    end

    it 'sets stand_still movement' do
      expect(participant).to receive(:update).with(
        hash_including(movement_action: 'stand_still', movement_set: true, input_stage: 'main_menu')
      )

      handler.send(:handle_movement_choice, 'stand_still')
    end

    it 'sets towards movement with target' do
      expect(participant).to receive(:update).with(
        hash_including(movement_action: 'towards_person', movement_target_participant_id: 123, movement_set: true)
      )

      handler.send(:handle_movement_choice, 'towards_123')
    end

    it 'sets away movement with target' do
      expect(participant).to receive(:update).with(
        hash_including(movement_action: 'away_from', movement_target_participant_id: 456, movement_set: true)
      )

      handler.send(:handle_movement_choice, 'away_456')
    end

    it 'sets maintain distance with target' do
      expect(participant).to receive(:update).with(
        hash_including(movement_action: 'maintain_distance', movement_target_participant_id: 789, maintain_distance_range: 6)
      )

      handler.send(:handle_movement_choice, 'maintain_6_789')
    end
  end

  describe 'willpower choices' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(participant).to receive(:available_willpower_dice).and_return(3)
      allow(participant).to receive(:set_willpower_allocation!).and_return(true)
    end

    it 'skips willpower spending' do
      expect(participant).to receive(:set_willpower_allocation!)
        .with(attack: 0, defense: 0, ability: 0, movement: 0)
      expect(participant).to receive(:update).with(
        hash_including(willpower_set: true)
      )

      handler.send(:handle_willpower_choice, 'skip')
    end

    it 'sets attack willpower and reconciles dice spending' do
      expect(participant).to receive(:set_willpower_allocation!)
        .with(attack: 2, defense: 0, ability: 0, movement: 0)
      expect(participant).to receive(:update).with(
        hash_including(willpower_set: true)
      )

      handler.send(:handle_willpower_choice, 'attack_2')
    end

    it 'sets defense willpower and reconciles dice spending' do
      expect(participant).to receive(:set_willpower_allocation!)
        .with(attack: 0, defense: 3, ability: 0, movement: 0)
      expect(participant).to receive(:update).with(
        hash_including(willpower_set: true)
      )

      handler.send(:handle_willpower_choice, 'defense_3')
    end

    it 'sets movement willpower and reconciles dice spending' do
      expect(participant).to receive(:set_willpower_allocation!)
        .with(attack: 0, defense: 0, ability: 0, movement: 1)
      expect(participant).to receive(:update).with(
        hash_including(willpower_set: true)
      )

      handler.send(:handle_willpower_choice, 'movement_1')
    end
  end

  describe 'options submenu' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(participant).to receive(:ignore_hazard_avoidance).and_return(false)
      allow(participant).to receive(:autobattle_enabled?).and_return(false)
      allow(fight).to receive(:uses_battle_map).and_return(false)
      allow(fight).to receive(:active_participants).and_return(
        double(group_and_count: double(to_hash: { 1 => 2, 2 => 1 }))
      )
    end

    it 'navigates to melee weapon selection' do
      expect(participant).to receive(:update).with(input_stage: 'weapon_melee')

      handler.send(:handle_options_choice, 'melee')
    end

    it 'navigates to ranged weapon selection' do
      expect(participant).to receive(:update).with(input_stage: 'weapon_ranged')

      handler.send(:handle_options_choice, 'ranged')
    end

    it 'navigates to autobattle selection' do
      expect(participant).to receive(:update).with(input_stage: 'autobattle')

      handler.send(:handle_options_choice, 'autobattle')
    end

    it 'toggles hazard avoidance' do
      expect(participant).to receive(:update).with(
        ignore_hazard_avoidance: true, input_stage: 'options'
      )

      handler.send(:handle_options_choice, 'ignore_hazard')
    end

    it 'navigates to side selection' do
      expect(participant).to receive(:update).with(input_stage: 'side_select')

      handler.send(:handle_options_choice, 'side')
    end
  end

  describe 'weapon selection' do
    subject(:handler) { described_class.new(participant, character_instance) }

    it 'goes back from weapon menu' do
      expect(participant).to receive(:update).with(input_stage: 'options')

      handler.send(:handle_weapon_choice, 'back', :melee)
    end

    it 'sets unarmed for melee' do
      expect(participant).to receive(:update).with(melee_weapon_id: nil, input_stage: 'options')

      handler.send(:handle_weapon_choice, 'unarmed', :melee)
    end

    it 'sets melee weapon by id' do
      expect(participant).to receive(:update).with(melee_weapon_id: 42, input_stage: 'options')

      handler.send(:handle_weapon_choice, '42', :melee)
    end

    it 'sets no ranged weapon' do
      expect(participant).to receive(:update).with(ranged_weapon_id: nil, input_stage: 'options')

      handler.send(:handle_weapon_choice, 'none', :ranged)
    end

    it 'sets ranged weapon by id' do
      expect(participant).to receive(:update).with(ranged_weapon_id: 99, input_stage: 'options')

      handler.send(:handle_weapon_choice, '99', :ranged)
    end
  end

  describe 'side selection' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(fight).to receive(:fight_participants_dataset).and_return(
        double(max: 2)
      )
    end

    it 'goes back from side menu' do
      expect(participant).to receive(:update).with(input_stage: 'options')

      handler.send(:handle_side_select_choice, 'back')
    end

    it 'creates new side' do
      expect(participant).to receive(:update).with(side: 3, input_stage: 'options')

      handler.send(:handle_side_select_choice, 'new')
    end

    it 'switches to existing side' do
      expect(participant).to receive(:update).with(side: 2, input_stage: 'options')

      handler.send(:handle_side_select_choice, '2')
    end
  end

  describe 'autobattle' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(participant).to receive(:autobattle_enabled?).and_return(false)
    end

    it 'turns off autobattle' do
      expect(participant).to receive(:update).with(autobattle_style: nil, input_stage: 'main_menu')

      handler.send(:handle_autobattle_choice, 'off')
    end

    it 'goes back from autobattle menu' do
      expect(participant).to receive(:update).with(input_stage: 'options')

      handler.send(:handle_autobattle_choice, 'back')
    end
  end

  describe 'helper methods' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#checkmark' do
      it 'returns checkmark when field is true' do
        allow(participant).to receive(:main_action_set).and_return(true)
        expect(handler.send(:checkmark, :main_action_set)).to eq('✓')
      end

      it 'returns empty string when field is false' do
        allow(participant).to receive(:main_action_set).and_return(false)
        expect(handler.send(:checkmark, :main_action_set)).to eq('')
      end
    end

    describe '#can_complete?' do
      it 'returns true when main action is set' do
        allow(participant).to receive(:main_action_set).and_return(true)
        expect(handler.send(:can_complete?)).to be true
      end

      it 'returns false when main action is not set' do
        allow(participant).to receive(:main_action_set).and_return(false)
        expect(handler.send(:can_complete?)).to be false
      end
    end

    describe '#done_validation_message' do
      it 'returns ready message when complete' do
        allow(participant).to receive(:main_action_set).and_return(true)
        expect(handler.send(:done_validation_message)).to eq('Ready to submit')
      end

      it 'returns instruction when not complete' do
        allow(participant).to receive(:main_action_set).and_return(false)
        expect(handler.send(:done_validation_message)).to eq('Choose a main action first')
      end
    end
  end

  describe 'summary methods' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#main_action_summary' do
      it 'returns Not set when action not set' do
        allow(participant).to receive(:main_action_set).and_return(false)
        expect(handler.send(:main_action_summary)).to eq('Not set')
      end

      it 'returns Full Defense for defend action' do
        allow(participant).to receive(:main_action_set).and_return(true)
        allow(participant).to receive(:main_action).and_return('defend')
        expect(handler.send(:main_action_summary)).to eq('Full Defense')
      end

      it 'returns Dodge info for dodge action' do
        allow(participant).to receive(:main_action_set).and_return(true)
        allow(participant).to receive(:main_action).and_return('dodge')
        expect(handler.send(:main_action_summary)).to eq('Dodge (-5 to incoming)')
      end

      it 'returns Sprint info for sprint action' do
        allow(participant).to receive(:main_action_set).and_return(true)
        allow(participant).to receive(:main_action).and_return('sprint')
        expect(handler.send(:main_action_summary)).to eq('Sprint (+3 movement)')
      end
    end

    describe '#tactical_action_summary' do
      it 'returns Not set when tactic not set' do
        allow(participant).to receive(:tactical_action_set).and_return(false)
        expect(handler.send(:tactical_action_summary)).to eq('Not set')
      end

      it 'returns Aggressive info' do
        allow(participant).to receive(:tactical_action_set).and_return(true)
        allow(participant).to receive(:tactical_ability_id).and_return(nil)
        allow(participant).to receive(:tactic_choice).and_return('aggressive')
        expect(handler.send(:tactical_action_summary)).to eq('Aggressive (+2/-2)')
      end

      it 'returns Defensive info' do
        allow(participant).to receive(:tactical_action_set).and_return(true)
        allow(participant).to receive(:tactical_ability_id).and_return(nil)
        allow(participant).to receive(:tactic_choice).and_return('defensive')
        expect(handler.send(:tactical_action_summary)).to eq('Defensive (-2/+2)')
      end
    end

    describe '#movement_summary' do
      it 'returns Not set when movement not set' do
        allow(participant).to receive(:movement_set).and_return(false)
        expect(handler.send(:movement_summary)).to eq('Not set')
      end

      it 'returns Stand Still for stand_still' do
        allow(participant).to receive(:movement_set).and_return(true)
        allow(participant).to receive(:movement_action).and_return('stand_still')
        expect(handler.send(:movement_summary)).to eq('Stand Still')
      end
    end

    describe '#willpower_summary' do
      it 'returns available dice when not set' do
        allow(participant).to receive(:willpower_set).and_return(false)
        allow(participant).to receive(:available_willpower_dice).and_return(2)
        expect(handler.send(:willpower_summary)).to eq('2 dice available')
      end

      it 'returns Skipped when set but no dice spent' do
        allow(participant).to receive(:willpower_set).and_return(true)
        allow(participant).to receive(:willpower_attack).and_return(0)
        allow(participant).to receive(:willpower_defense).and_return(0)
        allow(participant).to receive(:willpower_movement).and_return(0)
        allow(participant).to receive(:willpower_ability).and_return(0)
        expect(handler.send(:willpower_summary)).to eq('Skipped')
      end

      it 'returns attack info when attack dice spent' do
        allow(participant).to receive(:willpower_set).and_return(true)
        allow(participant).to receive(:willpower_attack).and_return(2)
        expect(handler.send(:willpower_summary)).to eq('Attack +2d8')
      end
    end
  end

  describe 'menu context' do
    subject(:handler) { described_class.new(participant, character_instance) }

    it 'includes combat flag and IDs' do
      context = handler.send(:menu_context)

      expect(context[:combat]).to be true
      expect(context[:fight_id]).to eq(fight.id)
      expect(context[:participant_id]).to eq(participant.id)
    end
  end

  describe 'monster mounting actions' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#process_mount_action' do
      let(:monster) { double('LargeMonsterInstance', id: 1, status: 'active') }
      let(:mounting_service) { double('MonsterMountingService') }
      let(:segment) { double('MonsterSegmentInstance', id: 5) }

      before do
        allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
        allow(MonsterMountingService).to receive(:new).with(fight).and_return(mounting_service)
      end

      it 'sets mount target when monster exists and mount succeeds' do
        allow(mounting_service).to receive(:attempt_mount)
          .with(participant, monster)
          .and_return({ success: true, segment: segment })

        expect(participant).to receive(:update).with(
          hash_including(targeting_monster_id: 1, is_mounted: true, mount_action: 'cling')
        )

        handler.send(:process_mount_action, 1)
      end

      it 'returns nil when monster not found' do
        allow(LargeMonsterInstance).to receive(:[]).with(999).and_return(nil)

        result = handler.send(:process_mount_action, 999)
        expect(result).to be_nil
      end
    end

    describe '#process_climb_action' do
      let(:monster) { double('LargeMonsterInstance', id: 1) }
      let(:mount_state) { double('MonsterMountState') }
      let(:mounting_service) { double('MonsterMountingService') }

      before do
        allow(participant).to receive(:is_mounted).and_return(true)
        allow(participant).to receive(:targeting_monster_id).and_return(1)
        allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
        allow(MonsterMountState).to receive(:first).and_return(mount_state)
        allow(MonsterMountingService).to receive(:new).with(fight).and_return(mounting_service)
      end

      it 'calls process_climb when mounted' do
        expect(mounting_service).to receive(:process_climb).with(mount_state)

        handler.send(:process_climb_action)
      end

      it 'returns nil when not mounted' do
        allow(participant).to receive(:is_mounted).and_return(false)

        result = handler.send(:process_climb_action)
        expect(result).to be_nil
      end
    end

    describe '#process_dismount_action' do
      let(:monster) { double('LargeMonsterInstance', id: 1) }
      let(:mount_state) { double('MonsterMountState') }
      let(:mounting_service) { double('MonsterMountingService') }

      before do
        allow(participant).to receive(:is_mounted).and_return(true)
        allow(participant).to receive(:targeting_monster_id).and_return(1)
        allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
        allow(MonsterMountState).to receive(:first).and_return(mount_state)
        allow(MonsterMountingService).to receive(:new).with(fight).and_return(mounting_service)
      end

      it 'sets dismount state when dismount succeeds' do
        allow(mounting_service).to receive(:process_dismount)
          .with(mount_state)
          .and_return({ success: true, landing_position: [5, 6] })

        expect(participant).to receive(:update).with(
          hash_including(hex_x: 5, hex_y: 6, is_mounted: false, targeting_monster_id: nil)
        )

        handler.send(:process_dismount_action)
      end

      it 'returns nil when not mounted' do
        allow(participant).to receive(:is_mounted).and_return(false)

        result = handler.send(:process_dismount_action)
        expect(result).to be_nil
      end
    end
  end

  describe 'tactical ability targeting' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#build_tactical_ability_target_options' do
      let(:ability) { double('Ability', id: 1, name: 'Guard', target_type: 'ally') }

      before do
        allow(participant).to receive(:pending_tactical_ability).and_return(ability)
        allow(fight).to receive(:active_participants).and_return([participant])
      end

      it 'builds options for ally targeting abilities' do
        ally = double('Participant', id: 2, character_name: 'Ally', side: 1)
        allow(fight).to receive(:active_participants).and_return([participant, ally])
        allow(participant).to receive(:side).and_return(1)

        options = handler.send(:build_tactical_ability_target_options)
        expect(options).to be_an(Array)
      end

      it 'includes back option' do
        options = handler.send(:build_tactical_ability_target_options)
        expect(options.map { |o| o[:key] }).to include('back')
      end
    end

    describe '#handle_tactical_ability_target_choice' do
      let(:target) { double('Participant', id: 2, character_name: 'Target') }

      it 'returns to tactical menu on back' do
        expect(participant).to receive(:update).with(input_stage: 'tactical_action')

        handler.send(:handle_tactical_ability_target_choice, 'back')
      end

      it 'sets target and completes tactical action when target found' do
        ability = double('Ability', id: 9, target_type: 'ally')
        allow(participant).to receive(:tactical_ability_id).and_return(9)
        allow(participant).to receive(:hex_distance_to).with(target).and_return(nil)
        allow(Ability).to receive(:[]).with(9).and_return(ability)
        allow(FightParticipant).to receive(:first)
          .with(id: 2, fight_id: fight.id)
          .and_return(target)

        expect(participant).to receive(:update).with(
          hash_including(
            tactic_target_participant_id: 2,
            tactical_action_set: true,
            input_stage: 'main_menu'
          )
        )

        handler.send(:handle_tactical_ability_target_choice, '2')
      end
    end
  end

  describe 'autobattle system' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#build_autobattle_summary' do
      before do
        allow(participant).to receive(:autobattle_style).and_return('aggressive')
      end

      it 'returns formatted summary of actions with main action' do
        decisions = {
          main_action: 'attack',
          movement_action: 'towards_person',
          tactic_choice: 'aggressive'
        }

        summary = handler.send(:build_autobattle_summary, decisions)
        expect(summary).to be_a(String)
        expect(summary).to include('Auto/Aggressive')
        expect(summary).to include('Attack')
        expect(summary).to include('Charge')
      end

      it 'includes ability name when ability_id present' do
        ability = double('Ability', name: 'Fireball')
        allow(Ability).to receive(:[]).with(5).and_return(ability)

        decisions = {
          main_action: 'attack',
          ability_id: 5,
          movement_action: 'stand_still'
        }

        summary = handler.send(:build_autobattle_summary, decisions)
        expect(summary).to include('Fireball')
      end

      it 'includes target when target_participant_id present' do
        target = double('FightParticipant', character_name: 'Enemy')
        allow(FightParticipant).to receive(:[]).with(2).and_return(target)

        decisions = {
          main_action: 'attack',
          target_participant_id: 2,
          movement_action: 'stand_still'
        }

        summary = handler.send(:build_autobattle_summary, decisions)
        expect(summary).to include('Enemy')
      end

      it 'includes willpower when spent' do
        decisions = {
          main_action: 'attack',
          movement_action: 'stand_still',
          willpower_attack: 1,
          willpower_defense: 1
        }

        summary = handler.send(:build_autobattle_summary, decisions)
        expect(summary).to include('+2 WP')
      end
    end
  end

  describe 'round resolution' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#check_round_resolution' do
      let(:fight_service) { double('FightService') }
      let(:resolution_result) { { success: true, events: [] } }

      before do
        allow(fight).to receive(:reload)
        allow(FightService).to receive(:new).with(fight).and_return(fight_service)
        allow(fight_service).to receive(:ready_to_resolve?).and_return(true)
        allow(fight_service).to receive(:resolve_round!).and_return(resolution_result)
        allow(fight_service).to receive(:generate_narrative).and_return('Combat narrative text')
        allow(fight_service).to receive(:should_end?).and_return(false)
        allow(fight_service).to receive(:start_next_round)
        allow(fight_service).to receive(:next_round!)
        allow(fight).to receive(:status).and_return('input')
        allow(fight).to receive(:room_id).and_return(1)
        allow(fight).to receive(:round_number).and_return(1)
        allow(fight).to receive(:active_participants).and_return([])
        allow(BroadcastService).to receive(:to_room)
        allow(BroadcastService).to receive(:to_character)
      end

      it 'calls resolve_round when ready_to_resolve? is true' do
        expect(fight_service).to receive(:resolve_round!)

        handler.send(:check_round_resolution)
      end

      it 'returns early when not ready to resolve' do
        allow(fight_service).to receive(:ready_to_resolve?).and_return(false)

        expect(fight_service).not_to receive(:resolve_round!)

        handler.send(:check_round_resolution)
      end
    end

    describe '#force_recovery_transition' do
      let(:fight_service) { double('FightService') }

      before do
        allow(fight).to receive(:reload)
        allow(fight).to receive(:room_id).and_return(1)
        allow(fight).to receive(:round_number).and_return(1)
        allow(BroadcastService).to receive(:to_room)
      end

      it 'forces complete when should_end? is true' do
        allow(fight).to receive(:status).and_return('resolving')
        allow(fight_service).to receive(:should_end?).and_return(true)

        expect(fight).to receive(:update).with(hash_including(status: 'complete'))

        handler.send(:force_recovery_transition, fight_service)
      end

      it 'forces to next round input when should_end? is false' do
        allow(fight).to receive(:status).and_return('narrative')
        allow(fight_service).to receive(:should_end?).and_return(false)
        allow(fight).to receive(:fight_participants).and_return([])

        expect(fight).to receive(:update).with(hash_including(status: 'input'))

        handler.send(:force_recovery_transition, fight_service)
      end

      it 'does nothing when fight status is not stuck' do
        allow(fight).to receive(:status).and_return('input')

        expect(fight).not_to receive(:update)

        handler.send(:force_recovery_transition, fight_service)
      end
    end
  end

  describe 'personal combat summaries' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#build_personal_summary' do
      it 'builds summary from hit events' do
        events = [
          {
            actor_id: participant.id,
            event_type: 'hit',
            target_name: 'Enemy',
            details: { total: 15 }
          }
        ]

        summary = handler.send(:build_personal_summary, participant, events)
        expect(summary).to be_a(String)
        expect(summary).to include('15')
        expect(summary).to include('Enemy')
      end

      it 'returns empty string for no events involving participant' do
        events = [
          {
            actor_id: 999,  # Different participant
            event_type: 'hit',
            target_name: 'Someone',
            details: { total: 10 }
          }
        ]

        summary = handler.send(:build_personal_summary, participant, events)
        expect(summary).to eq('')
      end

      it 'includes ability name when present in details' do
        events = [
          {
            actor_id: participant.id,
            event_type: 'ability_hit',
            target_name: 'Enemy',
            details: { effective_damage: 20, ability_name: 'Fireball' }
          }
        ]

        summary = handler.send(:build_personal_summary, participant, events)
        expect(summary).to include('Fireball')
        expect(summary).to include('20')
      end

      it 'includes damage received' do
        events = [
          {
            target_id: participant.id,
            event_type: 'hit',
            details: { total: 12 }
          }
        ]

        summary = handler.send(:build_personal_summary, participant, events)
        expect(summary).to include('took')
        expect(summary).to include('12')
      end

      it 'includes healing received' do
        events = [
          {
            target_id: participant.id,
            event_type: 'ability_heal',
            details: { actual_heal: 8 }
          }
        ]

        summary = handler.send(:build_personal_summary, participant, events)
        expect(summary).to include('healed')
        expect(summary).to include('8')
      end

      it 'includes status effects applied' do
        events = [
          {
            target_id: participant.id,
            event_type: 'status_applied',
            details: { effect_name: 'Burning' }
          }
        ]

        summary = handler.send(:build_personal_summary, participant, events)
        expect(summary).to include('affected by')
        expect(summary).to include('Burning')
      end

      it 'includes lifesteal' do
        events = [
          {
            actor_id: participant.id,
            event_type: 'ability_lifesteal',
            details: { amount: 5 }
          }
        ]

        summary = handler.send(:build_personal_summary, participant, events)
        expect(summary).to include('drained')
        expect(summary).to include('5')
      end

      it 'includes knockout notification' do
        events = [
          {
            target_id: participant.id,
            event_type: 'knockout'
          }
        ]

        summary = handler.send(:build_personal_summary, participant, events)
        expect(summary).to include('knocked out')
      end

      it 'includes hazard damage in received total' do
        events = [
          {
            target_id: participant.id,
            event_type: 'hazard_damage',
            details: { damage: 7 }
          }
        ]

        summary = handler.send(:build_personal_summary, participant, events)
        expect(summary).to include('took')
        expect(summary).to include('7')
      end

      it 'includes healing tick amount' do
        events = [
          {
            target_id: participant.id,
            event_type: 'healing_tick',
            details: { amount: 3 }
          }
        ]

        summary = handler.send(:build_personal_summary, participant, events)
        expect(summary).to include('healed')
        expect(summary).to include('3')
      end
    end
  end

  describe 'main target selection' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:enemy_participant) do
      double('FightParticipant',
             id: 2,
             character_name: 'Enemy',
             side: 2,
             current_hp: 4,
             max_hp: 6,
             fight: fight)
    end

    describe '#build_main_target_options' do
      before do
        allow(participant).to receive(:pending_action_name).and_return('Attack')
        allow(participant).to receive(:selected_ability).and_return(nil)
        allow(participant).to receive(:melee_weapon).and_return(nil)
        allow(participant).to receive(:ranged_weapon).and_return(nil)
        allow(participant).to receive(:hex_distance_to).and_return(2)
        allow(participant).to receive(:side).and_return(1)
        allow(fight).to receive(:active_participants).and_return(
          double(exclude: double(exclude: [enemy_participant]))
        )
        allow(fight).to receive(:has_monster).and_return(false)
        allow(handler).to receive(:filter_targets_by_protection).and_return([enemy_participant])
        allow(handler).to receive(:filter_targets_by_taunt).and_return([enemy_participant])
        allow(described_class).to receive(:status_text).and_return('HP: 4/6')
      end

      it 'builds target options with distance info' do
        options = handler.send(:build_main_target_options)

        expect(options.find { |o| o[:key] == '2' }).not_to be_nil
        expect(options.find { |o| o[:key] == '2' }[:description]).to include('hex')
      end

      it 'includes back option' do
        options = handler.send(:build_main_target_options)

        expect(options.map { |o| o[:key] }).to include('back')
      end

      it 'shows out of range warning when target is too far' do
        allow(participant).to receive(:hex_distance_to).and_return(10)

        options = handler.send(:build_main_target_options)

        target_option = options.find { |o| o[:key] == '2' }
        expect(target_option[:description]).to include('OUT OF RANGE')
      end

      context 'with monsters in fight' do
        let(:monster) { double('LargeMonsterInstance', id: 1, display_name: 'Dragon', current_hp_percent: 75) }

        before do
          allow(fight).to receive(:has_monster).and_return(true)
          allow(LargeMonsterInstance).to receive(:where).and_return(double(all: [monster]))
        end

        it 'includes monsters as targets' do
          allow(handler).to receive(:monster_segment_status).and_return('3/4 segments')

          options = handler.send(:build_main_target_options)

          expect(options.find { |o| o[:key] == 'monster_1' }).not_to be_nil
        end
      end

      context 'with taunt effects' do
        before do
          handler.instance_variable_set(:@must_target_id, 2)
          handler.instance_variable_set(:@taunt_penalty, -5)
        end

        it 'shows taunt warning on taunter' do
          allow(handler).to receive(:filter_targets_by_taunt) do |targets|
            handler.instance_variable_set(:@must_target_id, 2)
            handler.instance_variable_set(:@taunt_penalty, -5)
            targets
          end

          options = handler.send(:build_main_target_options)

          target_option = options.find { |o| o[:key] == '2' }
          expect(target_option[:description]).to include('TAUNTED')
        end
      end
    end

    describe '#handle_main_target_choice' do
      context 'with monster targeting' do
        let(:monster) { double('LargeMonsterInstance', id: 1, status: 'active') }
        let(:segment) { double('MonsterSegmentInstance', id: 5) }

        before do
          allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
          allow(participant).to receive(:is_mounted).and_return(false)
          allow(monster).to receive(:closest_segment_to).and_return(segment)
        end

        it 'targets monster and segment' do
          expect(participant).to receive(:update).with(
            hash_including(
              target_participant_id: nil,
              targeting_monster_id: 1,
              targeting_segment_id: 5,
              main_action_set: true
            )
          )

          handler.send(:handle_main_target_choice, 'monster_1')
        end

        it 'uses current segment when mounted on monster' do
          allow(participant).to receive(:is_mounted).and_return(true)
          allow(participant).to receive(:targeting_monster_id).and_return(1)
          allow(participant).to receive(:targeting_segment_id).and_return(7)
          mounted_segment = double('MonsterSegmentInstance', id: 7)
          allow(MonsterSegmentInstance).to receive(:[]).with(7).and_return(mounted_segment)

          expect(participant).to receive(:update).with(
            hash_including(targeting_segment_id: 7)
          )

          handler.send(:handle_main_target_choice, 'monster_1')
        end

        it 'does nothing when monster not found' do
          allow(LargeMonsterInstance).to receive(:[]).with(999).and_return(nil)

          expect(participant).not_to receive(:update)

          handler.send(:handle_main_target_choice, 'monster_999')
        end
      end

      context 'with participant targeting' do
        let(:target) { double('FightParticipant', id: 2) }

        before do
          allow(FightParticipant).to receive(:first).with(id: 2, fight_id: fight.id).and_return(target)
        end

        it 'sets target participant' do
          expect(participant).to receive(:update).with(
            hash_including(
              target_participant_id: 2,
              targeting_monster_id: nil,
              ability_target_participant_id: 2,
              main_action_set: true
            )
          )

          handler.send(:handle_main_target_choice, '2')
        end

        it 'does nothing when target not found' do
          allow(FightParticipant).to receive(:first).with(id: 999, fight_id: fight.id).and_return(nil)

          expect(participant).not_to receive(:update)

          handler.send(:handle_main_target_choice, '999')
        end
      end
    end
  end

  describe 'ability selection' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:ability) do
      double('Ability',
             id: 10,
             name: 'Fireball',
             target_type: 'enemy',
             main_action?: true,
             base_damage_dice: '2d6',
             min_damage: 2,
             max_damage: 12,
             damage_type: 'fire',
             healing_ability?: false,
             has_aoe?: false,
             has_chain?: false,
             has_lifesteal?: false,
             has_execute?: false,
             applies_prone: false,
             has_forced_movement?: false,
             specific_cooldown_rounds: 2,
             global_cooldown_rounds: 0,
             ability_penalty_config: {})
    end

    describe 'ability in main action menu' do
      before do
        allow(StatusEffectService).to receive(:can_use_main_action?).and_return(true)
        allow(StatusEffectService).to receive(:has_effect?).and_return(false)
        allow(StatusEffectService).to receive(:is_prone?).and_return(false)
        allow(participant).to receive(:available_main_abilities).and_return([ability])
        allow(handler).to receive(:unavailable_main_abilities).and_return([])
      end

      it 'includes abilities in main action options' do
        options = handler.send(:build_main_action_options)

        ability_option = options.find { |o| o[:key] == 'ability_10' }
        expect(ability_option).not_to be_nil
        expect(ability_option[:label]).to eq('Fireball')
      end

      it 'includes cooldown info in description' do
        options = handler.send(:build_main_action_options)

        ability_option = options.find { |o| o[:key] == 'ability_10' }
        expect(ability_option[:description]).to include('2rd CD')
      end
    end

    describe '#handle_main_action_choice with ability' do
      before do
        allow(Ability).to receive(:[]).with(10).and_return(ability)
        allow(participant).to receive(:available_main_abilities).and_return([ability])
      end

      it 'sets ability as main action for enemy-targeted abilities' do
        expect(participant).to receive(:update).with(
          hash_including(
            main_action: 'ability',
            ability_id: 10,
            ability_choice: 'fireball'
          )
        )
        expect(participant).to receive(:update).with(input_stage: 'main_target')

        handler.send(:handle_main_action_choice, 'ability_10')
      end

      it 'sets self as target for self-targeted abilities' do
        allow(ability).to receive(:target_type).and_return('self')

        expect(participant).to receive(:update).with(
          hash_including(main_action: 'ability', ability_id: 10)
        )
        expect(participant).to receive(:update).with(
          hash_including(
            main_action_set: true,
            ability_target_participant_id: participant.id,
            input_stage: 'main_menu'
          )
        )

        handler.send(:handle_main_action_choice, 'ability_10')
      end

      it 'does nothing when ability not found' do
        allow(Ability).to receive(:[]).with(999).and_return(nil)

        result = handler.send(:handle_main_action_choice, 'ability_999')

        expect(result).to be_nil
      end
    end

    describe 'unavailable abilities' do
      let(:unavailable_ability) do
        double('Ability',
               id: 20,
               name: 'Ice Storm',
               main_action?: true,
               specific_cooldown_rounds: 3,
               global_cooldown_rounds: 0,
               ability_penalty_config: {})
      end

      before do
        allow(StatusEffectService).to receive(:can_use_main_action?).and_return(true)
        allow(StatusEffectService).to receive(:has_effect?).and_return(false)
        allow(StatusEffectService).to receive(:is_prone?).and_return(false)
        allow(participant).to receive(:available_main_abilities).and_return([])
        allow(participant).to receive(:all_combat_abilities).and_return([unavailable_ability])
      end

      it 'shows unavailable abilities as disabled' do
        options = handler.send(:build_main_action_options)

        unavail_option = options.find { |o| o[:key] == 'ability_20' }
        expect(unavail_option).not_to be_nil
        expect(unavail_option[:disabled]).to be true
        expect(unavail_option[:description]).to include('Unavailable')
      end
    end
  end

  describe '#ability_description' do
    subject(:handler) { described_class.new(participant, character_instance) }

    it 'includes damage dice and range' do
      ability = double('Ability',
                       base_damage_dice: '3d8',
                       min_damage: 3,
                       max_damage: 24,
                       damage_type: 'lightning',
                       healing_ability?: false,
                       has_aoe?: false,
                       has_chain?: false,
                       has_lifesteal?: false,
                       has_execute?: false,
                       applies_prone: false,
                       has_forced_movement?: false,
                       specific_cooldown_rounds: 0,
                       global_cooldown_rounds: 0,
                       ability_penalty_config: {})

      desc = handler.send(:ability_description, ability)

      expect(desc).to include('3d8')
      expect(desc).to include('[3-24]')
      expect(desc).to include('lightning')
    end

    it 'includes heals for healing abilities' do
      ability = double('Ability',
                       base_damage_dice: nil,
                       healing_ability?: true,
                       has_aoe?: false,
                       has_chain?: false,
                       has_lifesteal?: false,
                       has_execute?: false,
                       applies_prone: false,
                       has_forced_movement?: false,
                       specific_cooldown_rounds: 0,
                       global_cooldown_rounds: 0,
                       ability_penalty_config: {})

      desc = handler.send(:ability_description, ability)

      expect(desc).to include('heals')
    end

    it 'includes AoE shape' do
      ability = double('Ability',
                       base_damage_dice: nil,
                       healing_ability?: false,
                       has_aoe?: true,
                       aoe_shape: 'cone',
                       has_chain?: false,
                       has_lifesteal?: false,
                       has_execute?: false,
                       applies_prone: false,
                       has_forced_movement?: false,
                       specific_cooldown_rounds: 0,
                       global_cooldown_rounds: 0,
                       ability_penalty_config: {})

      desc = handler.send(:ability_description, ability)

      expect(desc).to include('AoE:cone')
    end

    it 'includes chain for chain abilities' do
      ability = double('Ability',
                       base_damage_dice: nil,
                       healing_ability?: false,
                       has_aoe?: false,
                       has_chain?: true,
                       has_lifesteal?: false,
                       has_execute?: false,
                       applies_prone: false,
                       has_forced_movement?: false,
                       specific_cooldown_rounds: 0,
                       global_cooldown_rounds: 0,
                       ability_penalty_config: {})

      desc = handler.send(:ability_description, ability)

      expect(desc).to include('chain')
    end

    it 'includes knockdown for prone abilities' do
      ability = double('Ability',
                       base_damage_dice: nil,
                       healing_ability?: false,
                       has_aoe?: false,
                       has_chain?: false,
                       has_lifesteal?: false,
                       has_execute?: false,
                       applies_prone: true,
                       has_forced_movement?: false,
                       specific_cooldown_rounds: 0,
                       global_cooldown_rounds: 0,
                       ability_penalty_config: {})

      desc = handler.send(:ability_description, ability)

      expect(desc).to include('knockdown')
    end

    it 'includes push for forced movement abilities' do
      ability = double('Ability',
                       base_damage_dice: nil,
                       healing_ability?: false,
                       has_aoe?: false,
                       has_chain?: false,
                       has_lifesteal?: false,
                       has_execute?: false,
                       applies_prone: false,
                       has_forced_movement?: true,
                       specific_cooldown_rounds: 0,
                       global_cooldown_rounds: 0,
                       ability_penalty_config: {})

      desc = handler.send(:ability_description, ability)

      expect(desc).to include('push')
    end

    it 'includes global cooldown' do
      ability = double('Ability',
                       base_damage_dice: nil,
                       healing_ability?: false,
                       has_aoe?: false,
                       has_chain?: false,
                       has_lifesteal?: false,
                       has_execute?: false,
                       applies_prone: false,
                       has_forced_movement?: false,
                       specific_cooldown_rounds: 0,
                       global_cooldown_rounds: 1,
                       ability_penalty_config: {})

      desc = handler.send(:ability_description, ability)

      expect(desc).to include('1rd GCD')
    end

    it 'includes ability penalty' do
      ability = double('Ability',
                       base_damage_dice: nil,
                       healing_ability?: false,
                       has_aoe?: false,
                       has_chain?: false,
                       has_lifesteal?: false,
                       has_execute?: false,
                       applies_prone: false,
                       has_forced_movement?: false,
                       specific_cooldown_rounds: 0,
                       global_cooldown_rounds: 0,
                       ability_penalty_config: { 'amount' => -2 })

      desc = handler.send(:ability_description, ability)

      expect(desc).to include('-2 penalty')
    end
  end

  describe 'tactical action options building' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:tactical_ability) do
      double('Ability',
             id: 30,
             name: 'Healing Word',
             target_type: 'ally',
             main_action?: false,
             base_damage_dice: nil,
             healing_ability?: true,
             has_aoe?: false,
             has_chain?: false,
             has_lifesteal?: false,
             has_execute?: false,
             applies_prone: false,
             has_forced_movement?: false,
             specific_cooldown_rounds: 0,
             global_cooldown_rounds: 0,
             ability_penalty_config: {})
    end

    before do
      allow(StatusEffectService).to receive(:can_use_tactical_action?).and_return(true)
      allow(participant).to receive(:available_tactical_abilities).and_return([tactical_ability])
    end

    it 'includes tactical abilities' do
      options = handler.send(:build_tactical_action_options)

      ability_option = options.find { |o| o[:key] == 'tactical_ability_30' }
      expect(ability_option).not_to be_nil
      expect(ability_option[:label]).to eq('Healing Word')
    end

    it 'includes stance divider when abilities exist' do
      options = handler.send(:build_tactical_action_options)

      divider = options.find { |o| o[:key] == 'divider' }
      expect(divider).not_to be_nil
      expect(divider[:disabled]).to be true
    end

    context 'when dazed' do
      before { allow(StatusEffectService).to receive(:can_use_tactical_action?).and_return(false) }

      it 'shows dazed message' do
        options = handler.send(:build_tactical_action_options)

        expect(options.first[:key]).to eq('dazed')
        expect(options.first[:disabled]).to be true
      end
    end
  end

  describe '#handle_tactical_action_choice with tactical ability' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:tactical_ability) do
      double('Ability', id: 30, name: 'Healing Word', target_type: 'ally')
    end

    before do
      allow(Ability).to receive(:[]).with(30).and_return(tactical_ability)
      allow(participant).to receive(:available_tactical_abilities).and_return([tactical_ability])
    end

    it 'sets tactical ability and goes to target selection' do
      expect(participant).to receive(:update).with(
        hash_including(tactical_ability_id: 30, tactic_choice: nil)
      )
      expect(participant).to receive(:update).with(input_stage: 'tactical_ability_target')

      handler.send(:handle_tactical_action_choice, 'tactical_ability_30')
    end

    it 'completes immediately for self-targeted abilities' do
      allow(tactical_ability).to receive(:target_type).and_return('self')

      expect(participant).to receive(:update).with(
        hash_including(tactical_ability_id: 30)
      )
      expect(participant).to receive(:update).with(
        hash_including(
          tactical_action_set: true,
          tactic_target_participant_id: participant.id,
          input_stage: 'main_menu'
        )
      )

      handler.send(:handle_tactical_action_choice, 'tactical_ability_30')
    end

    it 'does nothing when ability not found' do
      allow(Ability).to receive(:[]).with(999).and_return(nil)

      result = handler.send(:handle_tactical_action_choice, 'tactical_ability_999')

      expect(result).to be_nil
    end
  end

  describe 'tactical target options' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:ally) { double('FightParticipant', id: 3, character_name: 'Ally', side: 1, current_hp: 4, max_hp: 6, fight: fight) }

    before do
      allow(participant).to receive(:side).and_return(1)
      allow(participant).to receive(:hex_distance_to).and_return(1)
      allow(fight).to receive(:active_participants).and_return(
        double(where: double(exclude: [ally]))
      )
    end

    it 'builds options for allies on same side' do
      options = handler.send(:build_tactical_target_options)

      expect(options.find { |o| o[:key] == '3' }).not_to be_nil
      expect(options.find { |o| o[:key] == '3' }[:label]).to eq('Ally')
    end

    it 'shows adjacent status' do
      options = handler.send(:build_tactical_target_options)

      ally_option = options.find { |o| o[:key] == '3' }
      expect(ally_option[:description]).to include('adjacent')
    end
  end

  describe '#send_protection_notification' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:target) { double('FightParticipant', character_instance: character_instance) }

    before do
      allow(BroadcastService).to receive(:to_character)
    end

    it 'sends guard notification' do
      allow(participant).to receive(:tactic_choice).and_return('guard')
      allow(participant).to receive(:character_name).and_return('Guardian')

      expect(BroadcastService).to receive(:to_character).with(
        character_instance,
        'Guardian is guarding you!',
        type: :combat
      )

      handler.send(:send_protection_notification, target)
    end

    it 'sends back_to_back notification' do
      allow(participant).to receive(:tactic_choice).and_return('back_to_back')
      allow(participant).to receive(:character_name).and_return('Ally')

      expect(BroadcastService).to receive(:to_character).with(
        character_instance,
        'Ally wants to fight back-to-back with you!',
        type: :combat
      )

      handler.send(:send_protection_notification, target)
    end

    it 'does nothing for other tactics' do
      allow(participant).to receive(:tactic_choice).and_return('aggressive')

      expect(BroadcastService).not_to receive(:to_character)

      handler.send(:send_protection_notification, target)
    end
  end

  describe 'eligible targets filtering' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:enemy) { double('FightParticipant', id: 2, side: 2) }
    let(:ally) { double('FightParticipant', id: 3, side: 1) }

    before do
      allow(participant).to receive(:side).and_return(1)
      allow(fight).to receive(:active_participants).and_return(
        double(
          exclude: double(exclude: [enemy]),
          where: [participant, ally]
        )
      )
    end

    describe '#eligible_targets_for_action' do
      before do
        allow(handler).to receive(:filter_targets_by_protection).and_return([enemy])
        allow(handler).to receive(:filter_targets_by_taunt).and_return([enemy])
      end

      it 'returns enemies for nil ability (attack)' do
        targets = handler.send(:eligible_targets_for_action, nil)
        expect(targets).to eq([enemy])
      end

      it 'returns allies for ally-targeted ability' do
        ability = double('Ability', target_type: 'ally')
        allow(handler).to receive(:filter_targets_by_protection).and_return([participant, ally])
        allow(handler).to receive(:filter_targets_by_taunt).and_return([participant, ally])

        targets = handler.send(:eligible_targets_for_action, ability)
        expect(targets).to include(participant)
      end

      it 'returns enemies for enemy-targeted ability' do
        ability = double('Ability', target_type: 'enemy')
        allow(fight).to receive(:active_participants).and_return(
          double(exclude: [enemy])
        )
        allow(handler).to receive(:filter_targets_by_protection).and_return([enemy])
        allow(handler).to receive(:filter_targets_by_taunt).and_return([enemy])

        targets = handler.send(:eligible_targets_for_action, ability)
        expect(targets).to eq([enemy])
      end

      it 'returns self for self-targeted ability' do
        ability = double('Ability', target_type: 'self')
        allow(handler).to receive(:filter_targets_by_protection).and_return([participant])
        allow(handler).to receive(:filter_targets_by_taunt).and_return([participant])

        targets = handler.send(:eligible_targets_for_action, ability)
        expect(targets).to eq([participant])
      end
    end

    describe '#filter_targets_by_protection' do
      it 'filters out protected targets' do
        allow(StatusEffectService).to receive(:cannot_target_ids).and_return([2])

        targets = handler.send(:filter_targets_by_protection, [enemy, ally])
        expect(targets).to eq([ally])
      end

      it 'returns all when no protected targets' do
        allow(StatusEffectService).to receive(:cannot_target_ids).and_return([])

        targets = handler.send(:filter_targets_by_protection, [enemy, ally])
        expect(targets).to eq([enemy, ally])
      end
    end

    describe '#filter_targets_by_taunt' do
      it 'reorders targets to put taunter first' do
        allow(StatusEffectService).to receive(:must_target).and_return(2)
        allow(StatusEffectService).to receive(:taunt_penalty).and_return(-5)

        targets = handler.send(:filter_targets_by_taunt, [ally, enemy])

        expect(targets.first).to eq(enemy)
        expect(handler.instance_variable_get(:@must_target_id)).to eq(2)
        expect(handler.instance_variable_get(:@taunt_penalty)).to eq(-5)
      end

      it 'returns unchanged when no taunt' do
        allow(StatusEffectService).to receive(:must_target).and_return(nil)

        targets = handler.send(:filter_targets_by_taunt, [ally, enemy])
        expect(targets).to eq([ally, enemy])
      end
    end
  end

  describe 'movement options' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#build_movement_options' do
      let(:other_participant) { double('FightParticipant', id: 2, character_name: 'Enemy') }

      before do
        allow(participant).to receive(:is_mounted).and_return(false)
        allow(participant).to receive(:can_flee?).and_return(false)
        allow(participant).to receive(:hex_distance_to).and_return(3)
        allow(fight).to receive(:has_monster).and_return(false)
        allow(fight).to receive(:active_participants).and_return(
          double(exclude: [other_participant])
        )
      end

      it 'includes stand still option' do
        options = handler.send(:build_movement_options)
        expect(options.map { |o| o[:key] }).to include('stand_still')
      end

      it 'includes movement options for each participant' do
        options = handler.send(:build_movement_options)
        keys = options.map { |o| o[:key] }

        expect(keys).to include('towards_2', 'away_2', 'maintain_6_2')
      end

      context 'with flee options' do
        # exit is now the destination Room directly (not RoomExit with to_room)
        let(:exit_room) { double('Room', id: 1, name: 'Safe Room') }

        before do
          allow(participant).to receive(:can_flee?).and_return(true)
          allow(participant).to receive(:available_flee_exits).and_return([
                                                                            { direction: 'north', exit: exit_room }
                                                                          ])
        end

        it 'includes flee options' do
          options = handler.send(:build_movement_options)

          flee_option = options.find { |o| o[:key] == 'flee_north' }
          expect(flee_option).not_to be_nil
          expect(flee_option[:description]).to include('Safe Room')
        end
      end

      context 'with adjacent monsters' do
        let(:monster) { double('LargeMonsterInstance', id: 1, display_name: 'Dragon') }
        let(:hex_service) { double('MonsterHexService') }

        before do
          allow(fight).to receive(:has_monster).and_return(true)
          allow(LargeMonsterInstance).to receive(:where).and_return(double(all: [monster]))
          allow(MonsterHexService).to receive(:new).and_return(hex_service)
          allow(hex_service).to receive(:adjacent_to_monster?).and_return(true)
        end

        it 'includes mount monster option' do
          options = handler.send(:build_movement_options)

          mount_option = options.find { |o| o[:key] == 'mount_monster_1' }
          expect(mount_option).not_to be_nil
          expect(mount_option[:label]).to include('Dragon')
        end
      end
    end

    describe '#build_mounted_movement_options' do
      let(:monster) { double('LargeMonsterInstance', id: 1, monster_template: double(climb_distance: 5)) }
      let(:mount_state) { double('MonsterMountState', climb_progress: 2, at_weak_point?: false) }

      before do
        allow(participant).to receive(:targeting_monster_id).and_return(1)
        allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
        allow(MonsterMountState).to receive(:first).and_return(mount_state)
      end

      it 'includes climb option with progress' do
        options = handler.send(:build_mounted_movement_options)

        climb_option = options.find { |o| o[:key] == 'climb' }
        expect(climb_option).not_to be_nil
        expect(climb_option[:description]).to include('2/5')
      end

      it 'includes cling and dismount options' do
        options = handler.send(:build_mounted_movement_options)
        keys = options.map { |o| o[:key] }

        expect(keys).to include('cling', 'dismount', 'back')
      end

      context 'when at weak point' do
        before { allow(mount_state).to receive(:at_weak_point?).and_return(true) }

        it 'shows weak point indicator' do
          options = handler.send(:build_mounted_movement_options)

          weak_point_option = options.find { |o| o[:key] == 'at_weak_point' }
          expect(weak_point_option).not_to be_nil
          expect(weak_point_option[:disabled]).to be true
          expect(weak_point_option[:description]).to include('3x damage')
        end
      end
    end
  end

  describe 'flee movement handling' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:exit) { double('RoomExit', id: 5, to_room: double(name: 'Escape')) }

    before do
      allow(participant).to receive(:available_flee_exits).and_return([
                                                                        { direction: 'north', exit: exit }
                                                                      ])
    end

    it 'sets flee movement with exit info' do
      expect(participant).to receive(:update).with(
        hash_including(
          movement_action: 'flee',
          is_fleeing: true,
          flee_direction: 'north',
          flee_exit_id: 5,
          movement_set: true
        )
      )

      handler.send(:handle_movement_choice, 'flee_north')
    end

    it 'does nothing for invalid flee direction' do
      expect(participant).not_to receive(:update)

      handler.send(:handle_movement_choice, 'flee_south')
    end
  end

  describe 'mounted movement handling' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(participant).to receive(:is_mounted).and_return(true)
      allow(participant).to receive(:targeting_monster_id).and_return(1)
    end

    describe 'climb action' do
      let(:monster) { double('LargeMonsterInstance', id: 1) }
      let(:mount_state) { double('MonsterMountState') }
      let(:mounting_service) { double('MonsterMountingService') }

      before do
        allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
        allow(MonsterMountState).to receive(:first).and_return(mount_state)
        allow(MonsterMountingService).to receive(:new).with(fight).and_return(mounting_service)
        allow(mounting_service).to receive(:process_climb)
      end

      it 'processes climb and sets mount action' do
        expect(participant).to receive(:update).with(
          hash_including(mount_action: 'climb', movement_set: true)
        )

        handler.send(:handle_movement_choice, 'climb')
      end
    end

    describe 'cling action' do
      let(:monster) { double('LargeMonsterInstance', id: 1) }
      let(:mount_state) { double('MonsterMountState') }
      let(:mounting_service) { double('MonsterMountingService') }

      before do
        allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
        allow(MonsterMountState).to receive(:first).and_return(mount_state)
        allow(MonsterMountingService).to receive(:new).with(fight).and_return(mounting_service)
        allow(mounting_service).to receive(:process_cling)
      end

      it 'processes cling and sets mount action' do
        expect(participant).to receive(:update).with(
          hash_including(mount_action: 'cling', movement_set: true)
        )

        handler.send(:handle_movement_choice, 'cling')
      end
    end

    describe 'dismount action' do
      let(:monster) { create(:large_monster_instance, fight: fight) }
      let(:mount_state) { double('MonsterMountState') }
      let(:mounting_service) { double('MonsterMountingService') }

      before do
        # Override the parent stubs to use real values
        allow(participant).to receive(:is_mounted).and_call_original
        allow(participant).to receive(:targeting_monster_id).and_call_original

        # Set up participant as mounted to the real monster
        participant.update(is_mounted: true, targeting_monster_id: monster.id)

        # Stub all lookups to ensure process_dismount_action completes
        allow(LargeMonsterInstance).to receive(:[]).with(monster.id).and_return(monster)
        allow(MonsterMountState).to receive(:first).and_return(mount_state)
        # Use any instance of Fight for the stub since participant.fight returns a reloaded instance
        allow(MonsterMountingService).to receive(:new).and_return(mounting_service)
      end

      it 'processes dismount when successful' do
        allow(mounting_service).to receive(:process_dismount).and_return(
          { success: true, landing_position: [3, 4] }
        )

        handler.send(:handle_movement_choice, 'dismount')

        # Verify participant state after dismount
        participant.reload
        expect(participant.is_mounted).to be false
        expect(participant.movement_set).to be true
        expect(participant.input_stage).to eq('main_menu')
      end
    end
  end

  describe 'willpower options building' do
    subject(:handler) { described_class.new(participant, character_instance) }

    context 'with available willpower' do
      before do
        allow(participant).to receive(:available_willpower_dice).and_return(2)
        allow(participant).to receive(:main_action).and_return('attack')
      end

      it 'builds attack options for each die count' do
        options = handler.send(:build_willpower_options)
        keys = options.map { |o| o[:key] }

        expect(keys).to include('attack_1', 'attack_2')
      end

      it 'builds defense options for each die count' do
        options = handler.send(:build_willpower_options)
        keys = options.map { |o| o[:key] }

        expect(keys).to include('defense_1', 'defense_2')
      end

      it 'builds movement options for each die count' do
        options = handler.send(:build_willpower_options)
        keys = options.map { |o| o[:key] }

        expect(keys).to include('movement_1', 'movement_2')
      end

      it 'includes skip option' do
        options = handler.send(:build_willpower_options)
        skip_option = options.find { |o| o[:key] == 'skip' }

        expect(skip_option).not_to be_nil
        expect(skip_option[:description]).to include('Save all')
      end
    end

    context 'when main action is ability' do
      before do
        allow(participant).to receive(:available_willpower_dice).and_return(2)
        allow(participant).to receive(:main_action).and_return('ability')
      end

      it 'includes ability willpower options' do
        options = handler.send(:build_willpower_options)
        keys = options.map { |o| o[:key] }

        expect(keys).to include('ability_1', 'ability_2')
      end
    end

    context 'with no willpower available' do
      before do
        allow(participant).to receive(:available_willpower_dice).and_return(0)
      end

      it 'shows no willpower message' do
        options = handler.send(:build_willpower_options)

        expect(options.first[:key]).to eq('skip')
        expect(options.first[:description]).to include('no dice')
      end
    end
  end

  describe '#handle_willpower_choice with ability' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(participant).to receive(:set_willpower_allocation!).and_return(true)
    end

    it 'sets ability willpower and reconciles dice spending' do
      expect(participant).to receive(:set_willpower_allocation!)
        .with(attack: 0, defense: 0, ability: 2, movement: 0)
      expect(participant).to receive(:update).with(
        hash_including(
          willpower_set: true
        )
      )

      handler.send(:handle_willpower_choice, 'ability_2')
    end
  end

  describe 'options submenu building' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(participant).to receive(:ignore_hazard_avoidance).and_return(false)
      allow(participant).to receive(:autobattle_enabled?).and_return(false)
      allow(participant).to receive(:side).and_return(1)
      allow(fight).to receive(:uses_battle_map).and_return(true)
      allow(fight).to receive_message_chain(:room, :has_battle_map).and_return(true)
      allow(fight).to receive(:active_participants).and_return(
        double(group_and_count: double(to_hash: { 1 => 2, 2 => 1 }))
      )
    end

    it 'includes hazard toggle when battle map active' do
      options = handler.send(:build_options_submenu)

      hazard_option = options.find { |o| o[:key] == 'ignore_hazard' }
      expect(hazard_option).not_to be_nil
      expect(hazard_option[:label]).to include('[OFF]')
    end

    it 'shows current side in side change option' do
      options = handler.send(:build_options_submenu)

      side_option = options.find { |o| o[:key] == 'side' }
      expect(side_option).not_to be_nil
      expect(side_option[:label]).to include('Currently: 1')
    end
  end

  describe 'side selection building' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(participant).to receive(:side).and_return(1)
      allow(fight).to receive(:active_participants).and_return(
        double(group_and_count: double(to_hash: { 1 => 2, 2 => 1 }))
      )
    end

    it 'marks current side' do
      options = handler.send(:build_side_select_options)

      current_side_option = options.find { |o| o[:key] == '1' }
      expect(current_side_option[:label]).to include('Current')
    end

    it 'shows fighter count for each side' do
      options = handler.send(:build_side_select_options)

      side_1_option = options.find { |o| o[:key] == '1' }
      expect(side_1_option[:description]).to include('2 fighters')

      side_2_option = options.find { |o| o[:key] == '2' }
      expect(side_2_option[:description]).to include('1 fighter')
    end

    it 'includes new side option' do
      options = handler.send(:build_side_select_options)

      new_option = options.find { |o| o[:key] == 'new' }
      expect(new_option).not_to be_nil
      expect(new_option[:label]).to include('Side 3')
    end
  end

  describe '#handle_side_select_choice with invalid side' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(fight).to receive(:fight_participants_dataset).and_return(
        double(max: 2)
      )
    end

    it 'does nothing for invalid side number' do
      expect(participant).not_to receive(:update)

      handler.send(:handle_side_select_choice, '0')
    end
  end

  describe 'weapon options building' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:melee_weapon) { double('Item', id: 1, name: 'Sword', pattern: double(attack_speed: 5, weapon_range: 'melee')) }
    let(:ranged_weapon) { double('Item', id: 2, name: 'Bow', pattern: double(attack_speed: 3, weapon_range: 'ranged')) }

    before do
      allow(handler).to receive(:find_available_weapons).with(:melee).and_return([melee_weapon])
      allow(handler).to receive(:find_available_weapons).with(:ranged).and_return([ranged_weapon])
    end

    it 'builds melee weapon options with unarmed' do
      options = handler.send(:build_weapon_options, :melee)

      expect(options.find { |o| o[:key] == '1' }[:label]).to eq('Sword')
      expect(options.find { |o| o[:key] == 'unarmed' }).not_to be_nil
    end

    it 'builds ranged weapon options with none' do
      options = handler.send(:build_weapon_options, :ranged)

      expect(options.find { |o| o[:key] == '2' }[:label]).to eq('Bow')
      expect(options.find { |o| o[:key] == 'none' }).not_to be_nil
    end

    it 'shows weapon stats in description' do
      options = handler.send(:build_weapon_options, :melee)

      sword_option = options.find { |o| o[:key] == '1' }
      expect(sword_option[:description]).to include('Speed: 5')
    end
  end

  describe 'summary methods additional coverage' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#main_action_summary' do
      it 'returns attack with target name' do
        target = double('FightParticipant', character_name: 'Enemy')
        allow(participant).to receive(:main_action_set).and_return(true)
        allow(participant).to receive(:main_action).and_return('attack')
        allow(participant).to receive(:targeting_monster_id).and_return(nil)
        allow(participant).to receive(:target_participant).and_return(target)

        expect(handler.send(:main_action_summary)).to eq('Attack Enemy')
      end

      it 'returns pass info' do
        allow(participant).to receive(:main_action_set).and_return(true)
        allow(participant).to receive(:main_action).and_return('pass')

        expect(handler.send(:main_action_summary)).to eq('Pass (no action)')
      end

      it 'returns ability name' do
        ability = double('Ability', name: 'Fireball')
        allow(participant).to receive(:main_action_set).and_return(true)
        allow(participant).to receive(:main_action).and_return('ability')
        allow(participant).to receive(:selected_ability).and_return(ability)

        expect(handler.send(:main_action_summary)).to eq('Fireball')
      end

      it 'returns Set for unknown action' do
        allow(participant).to receive(:main_action_set).and_return(true)
        allow(participant).to receive(:main_action).and_return('unknown_action')

        expect(handler.send(:main_action_summary)).to eq('Set')
      end

      context 'with monster target' do
        let(:monster) { double('LargeMonsterInstance', display_name: 'Dragon') }
        let(:segment) { double('MonsterSegmentInstance', name: 'Head') }

        before do
          allow(participant).to receive(:main_action_set).and_return(true)
          allow(participant).to receive(:main_action).and_return('attack')
          allow(participant).to receive(:targeting_monster_id).and_return(1)
          allow(participant).to receive(:targeting_segment_id).and_return(5)
          allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
          allow(MonsterSegmentInstance).to receive(:[]).with(5).and_return(segment)
        end

        it 'includes monster and segment name' do
          expect(handler.send(:main_action_summary)).to eq('Attack Dragon (Head)')
        end
      end
    end

    describe '#tactical_action_summary' do
      it 'returns Quick info' do
        allow(participant).to receive(:tactical_action_set).and_return(true)
        allow(participant).to receive(:tactical_ability_id).and_return(nil)
        allow(participant).to receive(:tactic_choice).and_return('quick')

        expect(handler.send(:tactical_action_summary)).to eq('Quick (+1 move)')
      end

      it 'returns Guard with target' do
        target = double('FightParticipant', character_name: 'Ally')
        allow(participant).to receive(:tactical_action_set).and_return(true)
        allow(participant).to receive(:tactical_ability_id).and_return(nil)
        allow(participant).to receive(:tactic_choice).and_return('guard')
        allow(participant).to receive(:tactic_target_participant).and_return(target)

        expect(handler.send(:tactical_action_summary)).to eq('Guard Ally')
      end

      it 'returns Back-to-Back with target' do
        target = double('FightParticipant', character_name: 'Partner')
        allow(participant).to receive(:tactical_action_set).and_return(true)
        allow(participant).to receive(:tactical_ability_id).and_return(nil)
        allow(participant).to receive(:tactic_choice).and_return('back_to_back')
        allow(participant).to receive(:tactic_target_participant).and_return(target)

        expect(handler.send(:tactical_action_summary)).to eq('Back-to-Back with Partner')
      end

      it 'returns tactical ability with target' do
        ability = double('Ability', name: 'Healing Word')
        target = double('FightParticipant', character_name: 'Ally')
        allow(participant).to receive(:tactical_action_set).and_return(true)
        allow(participant).to receive(:tactical_ability_id).and_return(30)
        allow(participant).to receive(:tactic_target_participant).and_return(target)
        allow(Ability).to receive(:[]).with(30).and_return(ability)

        expect(handler.send(:tactical_action_summary)).to eq('Healing Word → Ally')
      end
    end

    describe '#movement_summary' do
      it 'returns towards target name' do
        target = double('FightParticipant', character_name: 'Enemy')
        allow(participant).to receive(:movement_set).and_return(true)
        allow(participant).to receive(:movement_action).and_return('towards_person')
        allow(participant).to receive(:movement_target_participant_id).and_return(2)
        allow(FightParticipant).to receive(:[]).with(2).and_return(target)

        expect(handler.send(:movement_summary)).to eq('Toward Enemy')
      end

      it 'returns away from target name' do
        target = double('FightParticipant', character_name: 'Enemy')
        allow(participant).to receive(:movement_set).and_return(true)
        allow(participant).to receive(:movement_action).and_return('away_from')
        allow(participant).to receive(:movement_target_participant_id).and_return(2)
        allow(FightParticipant).to receive(:[]).with(2).and_return(target)

        expect(handler.send(:movement_summary)).to eq('Away from Enemy')
      end

      it 'returns maintain distance info' do
        allow(participant).to receive(:movement_set).and_return(true)
        allow(participant).to receive(:movement_action).and_return('maintain_distance')
        allow(participant).to receive(:maintain_distance_range).and_return(6)

        expect(handler.send(:movement_summary)).to eq('Maintain 6 hex')
      end

      it 'returns Set for unknown movement' do
        allow(participant).to receive(:movement_set).and_return(true)
        allow(participant).to receive(:movement_action).and_return('custom_movement')

        expect(handler.send(:movement_summary)).to eq('Set')
      end
    end

    describe '#willpower_summary' do
      it 'returns defense dice info' do
        allow(participant).to receive(:willpower_set).and_return(true)
        allow(participant).to receive(:willpower_attack).and_return(0)
        allow(participant).to receive(:willpower_defense).and_return(2)

        expect(handler.send(:willpower_summary)).to eq('Defense 2d8')
      end

      it 'returns movement dice info' do
        allow(participant).to receive(:willpower_set).and_return(true)
        allow(participant).to receive(:willpower_attack).and_return(0)
        allow(participant).to receive(:willpower_defense).and_return(0)
        allow(participant).to receive(:willpower_movement).and_return(1)

        expect(handler.send(:willpower_summary)).to eq('Movement 1d8÷2')
      end

      it 'returns ability dice info' do
        allow(participant).to receive(:willpower_set).and_return(true)
        allow(participant).to receive(:willpower_attack).and_return(0)
        allow(participant).to receive(:willpower_defense).and_return(0)
        allow(participant).to receive(:willpower_movement).and_return(0)
        allow(participant).to receive(:willpower_ability).and_return(3)

        expect(handler.send(:willpower_summary)).to eq('Ability +3d8')
      end
    end
  end

  describe 'weapon helpers' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#current_melee_weapon_name' do
      it 'returns weapon name when weapon exists' do
        weapon = double('Item', name: 'Sword')
        allow(participant).to receive(:melee_weapon).and_return(weapon)

        expect(handler.send(:current_melee_weapon_name)).to eq('Sword')
      end

      it 'returns Unarmed when no weapon' do
        allow(participant).to receive(:melee_weapon).and_return(nil)

        expect(handler.send(:current_melee_weapon_name)).to eq('Unarmed')
      end
    end

    describe '#current_ranged_weapon_name' do
      it 'returns weapon name when weapon exists' do
        weapon = double('Item', name: 'Bow')
        allow(participant).to receive(:ranged_weapon).and_return(weapon)

        expect(handler.send(:current_ranged_weapon_name)).to eq('Bow')
      end

      it 'returns None when no weapon' do
        allow(participant).to receive(:ranged_weapon).and_return(nil)

        expect(handler.send(:current_ranged_weapon_name)).to eq('None')
      end
    end
  end

  describe 'autobattle handling' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#autobattle_status' do
      it 'returns OFF when not enabled' do
        allow(participant).to receive(:autobattle_enabled?).and_return(false)

        expect(handler.send(:autobattle_status)).to eq('OFF')
      end

      it 'returns style in uppercase when enabled' do
        allow(participant).to receive(:autobattle_enabled?).and_return(true)
        allow(participant).to receive(:autobattle_style).and_return('aggressive')

        expect(handler.send(:autobattle_status)).to eq('AGGRESSIVE')
      end
    end

    describe '#apply_and_submit_autobattle!' do
      let(:ai_service) { double('AutobattleAIService') }
      let(:decisions) do
        {
          main_action: 'attack',
          target_participant_id: 2,
          movement_action: 'towards_person',
          tactic_choice: 'aggressive'
        }
      end

      before do
        allow(AutobattleAIService).to receive(:new).with(participant).and_return(ai_service)
        allow(ai_service).to receive(:decide!).and_return(decisions)
        allow(participant).to receive(:autobattle_style).and_return('aggressive')
        allow(participant).to receive(:update)
        allow(participant).to receive(:complete_input!)
        allow(BroadcastService).to receive(:to_character)
        allow(fight).to receive(:reload)
        allow(FightService).to receive(:new).and_return(
          double(ready_to_resolve?: false)
        )
      end

      it 'calls AI service to get decisions' do
        expect(ai_service).to receive(:decide!)

        handler.send(:apply_and_submit_autobattle!)
      end

      it 'updates participant with filtered decisions' do
        expect(participant).to receive(:update).with(
          hash_including(main_action: 'attack', main_action_set: true)
        )

        handler.send(:apply_and_submit_autobattle!)
      end

      it 'completes input' do
        expect(participant).to receive(:complete_input!)

        handler.send(:apply_and_submit_autobattle!)
      end

      it 'sends feedback to player' do
        expect(BroadcastService).to receive(:to_character).with(
          character_instance,
          anything,
          type: :system
        )

        handler.send(:apply_and_submit_autobattle!)
      end
    end
  end

  describe 'broadcast methods' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#broadcast_roll_display' do
      before do
        allow(fight).to receive(:room_id).and_return(1)
        allow(fight).to receive(:round_number).and_return(2)
      end

      it 'broadcasts individual dice_roll per viewer with personalized names' do
        roll_display = [{
          character_id: 42,
          character_name: 'Test',
          animations: ['|||w|||0||0||5||3|2|7|5'],
          total: 12
        }]

        # Broadcast is now per-viewer for name personalization
        viewer = character_instance
        allow(CharacterInstance).to receive(:where).and_return(
          double(eager: double(all: [viewer]))
        )
        allow(fight).to receive(:fight_participants).and_return([participant])

        expect(BroadcastService).to receive(:to_character).with(
          viewer,
          hash_including(type: 'dice_roll', combat_roll: true, animation_data: anything),
          type: :dice_roll
        )

        handler.send(:broadcast_roll_display, roll_display)
      end

      it 'does nothing for nil roll display' do
        expect(BroadcastService).not_to receive(:to_character)

        handler.send(:broadcast_roll_display, nil)
      end

      it 'does nothing for empty roll display' do
        expect(BroadcastService).not_to receive(:to_room)

        handler.send(:broadcast_roll_display, [])
      end
    end

    describe '#broadcast_combat_narrative' do
      let(:viewer1) { double('CharacterInstance', id: 101, character_id: 1, character: double('Character', name_variants: ['Alice'])) }

      before do
        handler # Force lazy let evaluation before stubbing CharacterInstance.where
        allow(fight).to receive(:room_id).and_return(1)
        allow(fight).to receive(:round_number).and_return(2)
        allow(CharacterInstance).to receive(:where).and_return(double(eager: double(all: [viewer1])))
        allow(MessagePersonalizationService).to receive(:personalize).and_return('The battle rages on!')
      end

      it 'broadcasts personalized narrative to each viewer' do
        narrative = 'The battle rages on!'

        expect(BroadcastService).to receive(:to_character).with(
          viewer1,
          narrative,
          type: :combat,
          fight_id: fight.id,
          round: 2,
          dice_duration_ms: 0
        )

        handler.send(:broadcast_combat_narrative, narrative)
      end
    end

    describe '#send_personal_combat_summaries' do
      before do
        allow(fight).to receive(:active_participants).and_return([participant])
        allow(fight).to receive(:round_number).and_return(2)
        allow(BroadcastService).to receive(:to_character)
      end

      it 'sends summary to each participant' do
        events = [
          { actor_id: participant.id, event_type: 'hit', target_name: 'Enemy', details: { total: 10 } }
        ]

        expect(BroadcastService).to receive(:to_character).with(
          character_instance,
          anything,
          hash_including(type: :combat_summary, fight_id: fight.id)
        )

        handler.send(:send_personal_combat_summaries, events)
      end

      it 'skips participants with empty summaries' do
        events = [
          { actor_id: 999, event_type: 'hit', target_name: 'Other', details: { total: 10 } }
        ]

        expect(BroadcastService).not_to receive(:to_character)

        handler.send(:send_personal_combat_summaries, events)
      end
    end
  end

  describe '#log_resolution_error' do
    subject(:handler) { described_class.new(participant, character_instance) }

    it 'logs error to stderr' do
      error = StandardError.new('Test error')
      error.set_backtrace(['line1', 'line2'])

      expect { handler.send(:log_resolution_error, 'test_step', error) }.to output(/COMBAT_RESOLUTION_ERROR/).to_stderr
    end

    it 'handles errors without backtrace' do
      error = StandardError.new('Test error')

      expect { handler.send(:log_resolution_error, 'test_step', error) }.not_to raise_error
    end
  end

  describe 'fight ending and next round' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:fight_service) { double('FightService') }

    before do
      handler # Force lazy let evaluation before any CharacterInstance.where stubs
      allow(fight).to receive(:room_id).and_return(1)
      allow(fight).to receive(:round_number).and_return(2)
      allow(BroadcastService).to receive(:to_room)
    end

    describe '#end_fight' do
      it 'ends fight and announces winner' do
        winner_char = double('Character', full_name: 'Victor')
        winner_ci = double('CharacterInstance', character: winner_char)
        winner = double('FightParticipant', id: 2, character_name: 'Victor', character_instance: winner_ci)
        viewer1 = double('CharacterInstance', id: 101)
        allow(fight_service).to receive(:end_fight!)
        allow(fight).to receive(:winner).and_return(winner)
        allow(CharacterInstance).to receive(:where).and_return(double(eager: double(all: [viewer1])))
        allow(MessagePersonalizationService).to receive(:personalize).and_return('The fight is over! Victor is victorious!')

        expect(BroadcastService).to receive(:to_character).with(
          viewer1,
          'The fight is over! Victor is victorious!',
          hash_including(type: :combat, winner_id: 2, winner_name: 'Victor')
        )

        handler.send(:end_fight, fight_service)
      end

      it 'announces end without winner' do
        allow(fight_service).to receive(:end_fight!)
        allow(fight).to receive(:winner).and_return(nil)

        expect(BroadcastService).to receive(:to_room).with(
          1,
          'The fight has ended!',
          hash_including(type: :combat)
        )

        handler.send(:end_fight, fight_service)
      end
    end

    describe '#start_next_round' do
      before do
        allow(fight).to receive(:reload).and_return(fight)
        allow(fight).to receive(:fight_participants).and_return([])
      end

      it 'starts next round and sends quickmenus to participants' do
        allow(fight_service).to receive(:next_round!)
        allow(fight).to receive(:active_participants).and_return([participant])
        allow(fight).to receive(:has_monster).and_return(false)
        menu_data = { prompt: 'Choose action', options: [{ label: 'Attack' }], context: {} }
        allow(described_class).to receive(:show_menu).and_return(menu_data)
        allow(OutputHelper).to receive(:store_agent_interaction)

        expect(BroadcastService).to receive(:to_character).with(
          character_instance,
          hash_including(content: "Round 2 — choose your actions."),
          hash_including(type: :quickmenu)
        )

        handler.send(:start_next_round, fight_service)
      end

      it 'shows menus to all active participants' do
        allow(fight_service).to receive(:next_round!)
        allow(fight).to receive(:active_participants).and_return([participant])
        allow(fight).to receive(:has_monster).and_return(false)

        expect(described_class).to receive(:show_menu).with(participant, character_instance)

        handler.send(:start_next_round, fight_service)
      end
    end
  end

  describe 'monster helpers' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#targetable_monsters' do
      it 'returns empty when no monsters in fight' do
        allow(fight).to receive(:has_monster).and_return(false)

        expect(handler.send(:targetable_monsters)).to eq([])
      end

      it 'returns active monsters' do
        monster = double('LargeMonsterInstance', id: 1, status: 'active')
        allow(fight).to receive(:has_monster).and_return(true)
        allow(LargeMonsterInstance).to receive(:where).with(fight_id: fight.id, status: 'active').and_return(
          double(all: [monster])
        )

        expect(handler.send(:targetable_monsters)).to eq([monster])
      end
    end

    describe '#monster_segment_status' do
      it 'returns segment count summary' do
        active_segments = double(count: 3)
        all_segments = double(count: 4)
        monster = double('LargeMonsterInstance',
                         active_segments: active_segments,
                         monster_segment_instances: all_segments)

        expect(handler.send(:monster_segment_status, monster)).to eq('3/4 segments')
      end
    end

    describe '#adjacent_monsters' do
      it 'returns empty when no monsters' do
        allow(fight).to receive(:has_monster).and_return(false)

        expect(handler.send(:adjacent_monsters)).to eq([])
      end

      it 'returns monsters adjacent to participant' do
        monster = double('LargeMonsterInstance', id: 1, status: 'active')
        hex_service = double('MonsterHexService')

        allow(fight).to receive(:has_monster).and_return(true)
        allow(LargeMonsterInstance).to receive(:where).and_return(double(all: [monster]))
        allow(MonsterHexService).to receive(:new).with(monster).and_return(hex_service)
        allow(hex_service).to receive(:adjacent_to_monster?).with(participant).and_return(true)

        expect(handler.send(:adjacent_monsters)).to eq([monster])
      end
    end
  end

  describe 'cling action processing' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#process_cling_action' do
      let(:monster) { double('LargeMonsterInstance', id: 1) }
      let(:mount_state) { double('MonsterMountState') }
      let(:mounting_service) { double('MonsterMountingService') }

      before do
        allow(participant).to receive(:is_mounted).and_return(true)
        allow(participant).to receive(:targeting_monster_id).and_return(1)
        allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
        allow(MonsterMountState).to receive(:first).and_return(mount_state)
        allow(MonsterMountingService).to receive(:new).with(fight).and_return(mounting_service)
      end

      it 'calls process_cling when mounted with valid state' do
        expect(mounting_service).to receive(:process_cling).with(mount_state)

        handler.send(:process_cling_action)
      end

      it 'returns nil when not mounted' do
        allow(participant).to receive(:is_mounted).and_return(false)

        result = handler.send(:process_cling_action)
        expect(result).to be_nil
      end

      it 'returns nil when monster not found' do
        allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(nil)

        result = handler.send(:process_cling_action)
        expect(result).to be_nil
      end

      it 'returns nil when mount state not found' do
        allow(MonsterMountState).to receive(:first).and_return(nil)

        result = handler.send(:process_cling_action)
        expect(result).to be_nil
      end
    end
  end

  describe '#eligible_targets_for_tactical_ability' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:ally) { double('FightParticipant', id: 2, side: 1) }
    let(:enemy) { double('FightParticipant', id: 3, side: 2) }

    before do
      allow(participant).to receive(:side).and_return(1)
    end

    it 'returns allies for ally-targeted abilities' do
      ability = double('Ability', target_type: 'ally')
      allow(fight).to receive(:active_participants).and_return(
        double(where: double(to_a: [participant, ally]))
      )

      targets = handler.send(:eligible_targets_for_tactical_ability, ability)
      expect(targets).to include(participant)
      expect(targets).to include(ally)
    end

    it 'returns allies for allies-targeted abilities' do
      ability = double('Ability', target_type: 'allies')
      allow(fight).to receive(:active_participants).and_return(
        double(where: double(to_a: [participant, ally]))
      )

      targets = handler.send(:eligible_targets_for_tactical_ability, ability)
      expect(targets).to include(participant)
    end

    it 'returns enemies for enemy-targeted abilities' do
      ability = double('Ability', target_type: 'enemy')
      allow(fight).to receive(:active_participants).and_return(
        double(exclude: double(to_a: [enemy]))
      )

      targets = handler.send(:eligible_targets_for_tactical_ability, ability)
      expect(targets).to eq([enemy])
    end

    it 'returns self for self-targeted abilities' do
      ability = double('Ability', target_type: 'self')

      targets = handler.send(:eligible_targets_for_tactical_ability, ability)
      expect(targets).to eq([participant])
    end

    it 'returns all for other target types' do
      ability = double('Ability', target_type: 'any')
      allow(fight).to receive(:active_participants).and_return(
        double(to_a: [participant, ally, enemy])
      )

      targets = handler.send(:eligible_targets_for_tactical_ability, ability)
      expect(targets).to include(participant, ally, enemy)
    end
  end

  describe 'extinguish and stand actions' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe 'extinguish action' do
      before do
        allow(StatusEffectService).to receive(:can_use_main_action?).and_return(true)
        allow(StatusEffectService).to receive(:has_effect?).with(participant, 'burning').and_return(true)
      end

      it 'removes burning and sets pass action when extinguish succeeds' do
        allow(StatusEffectService).to receive(:extinguish).with(participant).and_return(true)

        expect(participant).to receive(:update).with(
          hash_including(
            main_action: 'pass',
            main_action_set: true,
            pending_action_name: 'Extinguish flames'
          )
        )

        handler.send(:handle_main_action_choice, 'extinguish')
      end

      it 'returns to main menu when extinguish fails' do
        allow(StatusEffectService).to receive(:extinguish).with(participant).and_return(false)

        expect(participant).to receive(:update).with(input_stage: 'main_menu')

        handler.send(:handle_main_action_choice, 'extinguish')
      end
    end

    describe 'stand action' do
      before do
        allow(StatusEffectService).to receive(:can_use_main_action?).and_return(true)
        allow(StatusEffectService).to receive(:is_prone?).and_return(true)
      end

      it 'removes prone and sets stand action' do
        expect(StatusEffectService).to receive(:remove_effect).with(participant, 'prone')
        expect(participant).to receive(:update).with(
          hash_including(
            main_action: 'stand',
            main_action_set: true,
            pending_action_name: 'Stand up'
          )
        )

        handler.send(:handle_main_action_choice, 'stand')
      end
    end
  end

  describe '#build_tactical_ability_target_options with range checking' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:ability) { double('Ability', id: 30, target_type: 'ally', range_in_hexes: 3) }
    let(:close_ally) { double('FightParticipant', id: 2, character_name: 'CloseAlly', side: 1, current_hp: 4, max_hp: 6, fight: fight) }
    let(:far_ally) { double('FightParticipant', id: 3, character_name: 'FarAlly', side: 1, current_hp: 3, max_hp: 6, fight: fight) }

    before do
      allow(participant).to receive(:tactical_ability_id).and_return(30)
      allow(participant).to receive(:side).and_return(1)
      allow(Ability).to receive(:[]).with(30).and_return(ability)
      allow(fight).to receive(:active_participants).and_return(
        double(where: double(to_a: [participant, close_ally, far_ally]))
      )
    end

    it 'marks out of range targets as disabled' do
      allow(participant).to receive(:hex_distance_to).with(close_ally).and_return(2)
      allow(participant).to receive(:hex_distance_to).with(far_ally).and_return(5)
      allow(participant).to receive(:hex_distance_to).with(participant).and_return(0)

      options = handler.send(:build_tactical_ability_target_options)

      close_option = options.find { |o| o[:key] == '2' }
      expect(close_option[:disabled]).to be_falsey

      far_option = options.find { |o| o[:key] == '3' }
      expect(far_option[:disabled]).to be true
      expect(far_option[:description]).to include('out of range')
    end
  end

  describe 'handle_tactical_target_choice with notification' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:target) { double('FightParticipant', id: 2, character_instance: character_instance) }

    before do
      allow(FightParticipant).to receive(:first).with(id: 2, fight_id: fight.id).and_return(target)
      allow(participant).to receive(:update)
      allow(BroadcastService).to receive(:to_character)
    end

    it 'sends protection notification when target found' do
      allow(participant).to receive(:tactic_choice).and_return('guard')
      allow(participant).to receive(:character_name).and_return('Guardian')

      expect(BroadcastService).to receive(:to_character)

      handler.send(:handle_tactical_target_choice, '2')
    end
  end

  describe 'battle map check' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#battle_map_active?' do
      it 'returns false when no fight' do
        allow(handler).to receive(:fight).and_return(nil)

        expect(handler.send(:battle_map_active?)).to be false
      end

      it 'returns false when uses_battle_map is false' do
        allow(fight).to receive(:uses_battle_map).and_return(false)

        expect(handler.send(:battle_map_active?)).to be false
      end

      it 'returns false when room has no battle map' do
        allow(fight).to receive(:uses_battle_map).and_return(true)
        allow(fight).to receive_message_chain(:room, :has_battle_map).and_return(false)

        expect(handler.send(:battle_map_active?)).to be false
      end

      it 'returns true when battle map is active' do
        allow(fight).to receive(:uses_battle_map).and_return(true)
        allow(fight).to receive_message_chain(:room, :has_battle_map).and_return(true)

        expect(handler.send(:battle_map_active?)).to be true
      end
    end
  end

  # ===== EDGE CASE TESTS FOR ADDITIONAL COVERAGE =====

  describe 'main target handling with monsters' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#handle_main_target_choice' do
      context 'when targeting a monster' do
        let(:monster) { double('LargeMonsterInstance', id: 10, status: 'active') }
        let(:segment) { double('MonsterSegmentInstance', id: 20) }

        before do
          allow(LargeMonsterInstance).to receive(:[]).with(10).and_return(monster)
          allow(monster).to receive(:closest_segment_to).and_return(segment)
          allow(participant).to receive(:is_mounted).and_return(false)
          allow(participant).to receive(:update)
        end

        it 'sets monster targeting fields' do
          expect(participant).to receive(:update).with(hash_including(
            target_participant_id: nil,
            targeting_monster_id: 10,
            targeting_segment_id: 20,
            main_action_set: true
          ))

          handler.send(:handle_main_target_choice, 'monster_10')
        end

        it 'ignores invalid monster id' do
          allow(LargeMonsterInstance).to receive(:[]).with(99).and_return(nil)

          # Should return early without updating
          expect(participant).not_to receive(:update)

          handler.send(:handle_main_target_choice, 'monster_99')
        end

        it 'ignores inactive monster' do
          inactive_monster = double('LargeMonsterInstance', id: 11, status: 'dead')
          allow(LargeMonsterInstance).to receive(:[]).with(11).and_return(inactive_monster)

          expect(participant).not_to receive(:update)

          handler.send(:handle_main_target_choice, 'monster_11')
        end
      end

      context 'when targeting mounted monster' do
        let(:monster) { double('LargeMonsterInstance', id: 10, status: 'active') }
        let(:current_segment) { double('MonsterSegmentInstance', id: 25) }

        before do
          allow(LargeMonsterInstance).to receive(:[]).with(10).and_return(monster)
          allow(participant).to receive(:is_mounted).and_return(true)
          allow(participant).to receive(:targeting_monster_id).and_return(10)
          allow(participant).to receive(:targeting_segment_id).and_return(25)
          allow(MonsterSegmentInstance).to receive(:[]).with(25).and_return(current_segment)
          allow(participant).to receive(:update)
        end

        it 'uses current segment when mounted on target monster' do
          expect(participant).to receive(:update).with(hash_including(
            targeting_segment_id: 25
          ))

          handler.send(:handle_main_target_choice, 'monster_10')
        end
      end
    end
  end

  describe 'flee movement handling' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#handle_movement_choice' do
      context 'when fleeing' do
        let(:exit_obj) { double('Exit', id: 100) }
        let(:flee_opt) { { direction: 'north', exit: exit_obj } }

        before do
          allow(participant).to receive(:available_flee_exits).and_return([flee_opt])
          allow(participant).to receive(:update)
        end

        it 'sets flee movement fields' do
          expect(participant).to receive(:update).with(hash_including(
            movement_action: 'flee',
            is_fleeing: true,
            flee_direction: 'north',
            flee_exit_id: 100,
            movement_set: true
          ))

          handler.send(:handle_movement_choice, 'flee_north')
        end

        it 'ignores invalid flee direction' do
          handler.send(:handle_movement_choice, 'flee_south')

          # Should not call update with flee fields since south not in available exits
        end
      end
    end

    describe '#build_movement_options' do
      it 'includes flee options when at edge with valid exit' do
        allow(participant).to receive(:can_flee?).and_return(true)
        # exit is now the destination Room directly (not RoomExit with to_room)
        exit_room = double('Room', id: 101, name: 'Safe Haven')
        allow(participant).to receive(:available_flee_exits).and_return([
          { direction: 'west', exit: exit_room }
        ])
        allow(fight).to receive(:active_participants).and_return(
          double(exclude: double(each: []))
        )
        allow(fight).to receive(:has_monster).and_return(false)
        allow(participant).to receive(:is_mounted).and_return(false)
        allow(participant).to receive(:targeting_monster_id).and_return(nil)

        options = handler.send(:build_movement_options)

        flee_option = options.find { |o| o[:key] == 'flee_west' }
        expect(flee_option).not_to be_nil
        expect(flee_option[:description]).to include('Safe Haven')
      end

      it 'handles flee exit without destination room' do
        allow(participant).to receive(:can_flee?).and_return(true)
        # exit is nil when no destination room available
        allow(participant).to receive(:available_flee_exits).and_return([
          { direction: 'east', exit: nil }
        ])
        allow(fight).to receive(:active_participants).and_return(
          double(exclude: double(each: []))
        )
        allow(fight).to receive(:has_monster).and_return(false)
        allow(participant).to receive(:is_mounted).and_return(false)
        allow(participant).to receive(:targeting_monster_id).and_return(nil)

        options = handler.send(:build_movement_options)

        flee_option = options.find { |o| o[:key] == 'flee_east' }
        expect(flee_option[:description]).to include('adjacent room')
      end
    end
  end

  describe 'mounted movement options' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#build_mounted_movement_options' do
      let(:monster) { double('LargeMonsterInstance', id: 15) }
      let(:template) { double('MonsterTemplate', climb_distance: 5) }

      before do
        allow(participant).to receive(:is_mounted).and_return(true)
        allow(participant).to receive(:targeting_monster_id).and_return(15)
        allow(LargeMonsterInstance).to receive(:[]).with(15).and_return(monster)
        allow(monster).to receive(:monster_template).and_return(template)
      end

      context 'at weak point' do
        let(:mount_state) do
          double('MonsterMountState',
                 climb_progress: 5,
                 at_weak_point?: true)
        end

        before do
          allow(MonsterMountState).to receive(:first).and_return(mount_state)
        end

        it 'shows at weak point indicator' do
          options = handler.send(:build_mounted_movement_options)

          weak_point_option = options.find { |o| o[:key] == 'at_weak_point' }
          expect(weak_point_option).not_to be_nil
          expect(weak_point_option[:label]).to include('Weak Point')
          expect(weak_point_option[:disabled]).to be true
        end
      end

      context 'climbing toward weak point' do
        let(:mount_state) do
          double('MonsterMountState',
                 climb_progress: 2,
                 at_weak_point?: false)
        end

        before do
          allow(MonsterMountState).to receive(:first).and_return(mount_state)
        end

        it 'shows climb progress' do
          options = handler.send(:build_mounted_movement_options)

          climb_option = options.find { |o| o[:key] == 'climb' }
          expect(climb_option).not_to be_nil
          expect(climb_option[:description]).to include('2/5')
        end
      end

      context 'without mount state' do
        before do
          allow(MonsterMountState).to receive(:first).and_return(nil)
        end

        it 'shows generic climb option' do
          options = handler.send(:build_mounted_movement_options)

          climb_option = options.find { |o| o[:key] == 'climb' }
          expect(climb_option).not_to be_nil
          expect(climb_option[:description]).to include('weak point')
        end
      end
    end
  end

  describe 'force recovery transition' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:fight_service) { double('FightService') }

    describe '#force_recovery_transition' do
      context 'when fight is stuck in resolving status' do
        before do
          allow(fight).to receive(:reload)
          allow(fight).to receive(:status).and_return('resolving')
          allow(fight).to receive(:update)
          allow(fight).to receive(:round_number).and_return(3)
          allow(fight).to receive(:room_id).and_return(room.id)
          allow(BroadcastService).to receive(:to_room)
        end

        it 'forces to complete when fight should end' do
          allow(fight_service).to receive(:should_end?).and_return(true)

          expect(fight).to receive(:update).with(hash_including(status: 'complete'))

          handler.send(:force_recovery_transition, fight_service)
        end

        it 'forces to next round when fight should continue' do
          allow(fight_service).to receive(:should_end?).and_return(false)
          allow(fight).to receive(:fight_participants).and_return([])

          expect(fight).to receive(:update).with(hash_including(status: 'input', round_number: 4))

          handler.send(:force_recovery_transition, fight_service)
        end
      end

      context 'when in narrative status' do
        before do
          allow(fight).to receive(:reload)
          allow(fight).to receive(:status).and_return('narrative')
          allow(fight).to receive(:update)
          allow(fight).to receive(:round_number).and_return(2)
          allow(fight).to receive(:room_id).and_return(room.id)
          allow(BroadcastService).to receive(:to_room)
        end

        it 'handles narrative status same as resolving' do
          allow(fight_service).to receive(:should_end?).and_return(true)

          expect(fight).to receive(:update).with(hash_including(status: 'complete'))

          handler.send(:force_recovery_transition, fight_service)
        end
      end

      context 'when recovery fails' do
        before do
          allow(fight).to receive(:reload)
          allow(fight).to receive(:status).and_return('resolving')
          allow(fight_service).to receive(:should_end?).and_raise(StandardError.new('Test error'))
          allow(fight).to receive(:update)
        end

        it 'falls back to completing fight' do
          expect(fight).to receive(:update).with(hash_including(status: 'complete'))

          handler.send(:force_recovery_transition, fight_service)
        end
      end
    end
  end

  describe 'protection notification edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#send_protection_notification' do
      let(:target_participant) { double('FightParticipant', character_instance: character_instance) }

      before do
        allow(BroadcastService).to receive(:to_character)
      end

      it 'sends guard notification' do
        allow(participant).to receive(:tactic_choice).and_return('guard')
        allow(participant).to receive(:character_name).and_return('Tank')

        expect(BroadcastService).to receive(:to_character).with(
          character_instance,
          'Tank is guarding you!',
          type: :combat
        )

        handler.send(:send_protection_notification, target_participant)
      end

      it 'sends back_to_back notification' do
        allow(participant).to receive(:tactic_choice).and_return('back_to_back')
        allow(participant).to receive(:character_name).and_return('Partner')

        expect(BroadcastService).to receive(:to_character).with(
          character_instance,
          'Partner wants to fight back-to-back with you!',
          type: :combat
        )

        handler.send(:send_protection_notification, target_participant)
      end

      it 'does not send notification for other tactics' do
        allow(participant).to receive(:tactic_choice).and_return('aggressive')
        allow(participant).to receive(:character_name).and_return('Fighter')

        expect(BroadcastService).not_to receive(:to_character)

        handler.send(:send_protection_notification, target_participant)
      end

      it 'handles nil tactic_choice' do
        allow(participant).to receive(:tactic_choice).and_return(nil)

        expect(BroadcastService).not_to receive(:to_character)

        handler.send(:send_protection_notification, target_participant)
      end
    end
  end

  describe 'target filtering' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#filter_targets_by_protection' do
      let(:target1) { double('FightParticipant', id: 10) }
      let(:target2) { double('FightParticipant', id: 11) }
      let(:targets) { [target1, target2] }

      it 'filters out protected targets' do
        allow(StatusEffectService).to receive(:cannot_target_ids).with(participant).and_return([10])

        result = handler.send(:filter_targets_by_protection, targets)

        expect(result).to eq([target2])
      end

      it 'returns all targets when none protected' do
        allow(StatusEffectService).to receive(:cannot_target_ids).with(participant).and_return([])

        result = handler.send(:filter_targets_by_protection, targets)

        expect(result).to eq(targets)
      end
    end

    describe '#filter_targets_by_taunt' do
      let(:target1) { double('FightParticipant', id: 10) }
      let(:target2) { double('FightParticipant', id: 11) }
      let(:taunter) { double('FightParticipant', id: 12) }
      let(:targets) { [target1, target2, taunter] }

      it 'reorders targets to put taunter first' do
        allow(StatusEffectService).to receive(:must_target).with(participant).and_return(12)
        allow(StatusEffectService).to receive(:taunt_penalty).with(participant).and_return(-3)

        result = handler.send(:filter_targets_by_taunt, targets)

        expect(result.first.id).to eq(12)
        expect(handler.instance_variable_get(:@must_target_id)).to eq(12)
        expect(handler.instance_variable_get(:@taunt_penalty)).to eq(-3)
      end

      it 'returns targets unchanged when not taunted' do
        allow(StatusEffectService).to receive(:must_target).with(participant).and_return(nil)

        result = handler.send(:filter_targets_by_taunt, targets)

        expect(result).to eq(targets)
      end

      it 'returns targets unchanged when taunter not in list' do
        allow(StatusEffectService).to receive(:must_target).with(participant).and_return(99)

        result = handler.send(:filter_targets_by_taunt, targets)

        expect(result).to eq(targets)
      end
    end
  end

  describe 'ability description edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#ability_description' do
      it 'includes all special flags' do
        ability = double('Ability',
                         base_damage_dice: '3d6',
                         min_damage: 3,
                         max_damage: 18,
                         damage_type: 'fire',
                         healing_ability?: true,
                         has_aoe?: true,
                         aoe_shape: 'cone',
                         has_chain?: true,
                         has_lifesteal?: true,
                         has_execute?: true,
                         applies_prone: true,
                         has_forced_movement?: true,
                         specific_cooldown_rounds: 2,
                         global_cooldown_rounds: 1,
                         ability_penalty_config: { 'amount' => -2 })

        desc = handler.send(:ability_description, ability)

        expect(desc).to include('3d6')
        expect(desc).to include('fire')
        expect(desc).to include('heals')
        expect(desc).to include('AoE:cone')
        expect(desc).to include('chain')
        expect(desc).to include('lifesteal')
        expect(desc).to include('execute')
        expect(desc).to include('knockdown')
        expect(desc).to include('push')
      end

      it 'handles ability with no special flags' do
        ability = double('Ability',
                         base_damage_dice: nil,
                         healing_ability?: false,
                         has_aoe?: false,
                         has_chain?: false,
                         has_lifesteal?: false,
                         has_execute?: false,
                         applies_prone: false,
                         has_forced_movement?: false,
                         specific_cooldown_rounds: 0,
                         global_cooldown_rounds: 0,
                         ability_penalty_config: {})

        desc = handler.send(:ability_description, ability)

        expect(desc).to eq('')
      end
    end

    describe '#ability_cooldown_text' do
      it 'combines multiple cooldown types' do
        ability = double('Ability',
                         specific_cooldown_rounds: 3,
                         global_cooldown_rounds: 2,
                         ability_penalty_config: { 'amount' => -5 })

        text = handler.send(:ability_cooldown_text, ability)

        expect(text).to include('3rd CD')
        expect(text).to include('2rd GCD')
        expect(text).to include('-5 penalty')
      end

      it 'returns empty for no cooldowns' do
        ability = double('Ability',
                         specific_cooldown_rounds: 0,
                         global_cooldown_rounds: 0,
                         ability_penalty_config: {})

        text = handler.send(:ability_cooldown_text, ability)

        expect(text).to eq('')
      end
    end
  end

  describe 'build personal summary edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#build_personal_summary' do
      it 'includes lifesteal events' do
        allow(participant).to receive(:id).and_return(1)
        allow(fight).to receive(:spar_mode?).and_return(false)
        events = [
          { actor_id: 1, event_type: 'ability_lifesteal', details: { amount: 5 } }
        ]

        summary = handler.send(:build_personal_summary, participant, events)

        expect(summary).to include('drained 5 HP')
      end

      it 'includes knockout notification' do
        allow(participant).to receive(:id).and_return(1)
        allow(fight).to receive(:spar_mode?).and_return(false)
        events = [
          { target_id: 1, event_type: 'knockout' }
        ]

        summary = handler.send(:build_personal_summary, participant, events)

        expect(summary).to include('knocked out')
      end

      it 'includes healing received' do
        allow(participant).to receive(:id).and_return(1)
        allow(fight).to receive(:spar_mode?).and_return(false)
        events = [
          { target_id: 1, event_type: 'ability_heal', details: { actual_heal: 10 } }
        ]

        summary = handler.send(:build_personal_summary, participant, events)

        expect(summary).to include('healed 10 HP')
      end

      it 'includes status effects applied' do
        allow(participant).to receive(:id).and_return(1)
        allow(fight).to receive(:spar_mode?).and_return(false)
        events = [
          { target_id: 1, event_type: 'status_applied', details: { effect_name: 'burning' } }
        ]

        summary = handler.send(:build_personal_summary, participant, events)

        expect(summary).to include('affected by burning')
      end

      it 'handles damage with ability name' do
        allow(participant).to receive(:id).and_return(1)
        allow(fight).to receive(:spar_mode?).and_return(false)
        events = [
          { actor_id: 1, event_type: 'ability_hit', target_name: 'Enemy', details: { total: 15, ability_name: 'Fireball' } }
        ]

        summary = handler.send(:build_personal_summary, participant, events)

        expect(summary).to include('15 damage')
        expect(summary).to include('Fireball')
      end

      it 'returns empty string when no relevant events' do
        allow(participant).to receive(:id).and_return(1)
        events = []

        summary = handler.send(:build_personal_summary, participant, events)

        expect(summary).to eq('')
      end
    end
  end

  describe 'autobattle error handling' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#handle_autobattle_choice' do
      it 're-raises errors from autobattle application' do
        allow(participant).to receive(:update)
        allow(AutobattleAIService).to receive(:new).and_raise(StandardError.new('AI Error'))

        expect {
          handler.send(:handle_autobattle_choice, 'aggressive')
        }.to raise_error(StandardError, 'AI Error')
      end
    end

    describe '#apply_and_submit_autobattle!' do
      let(:ai_service) { double('AutobattleAIService') }

      before do
        allow(AutobattleAIService).to receive(:new).and_return(ai_service)
        allow(participant).to receive(:autobattle_style).and_return('aggressive')
        allow(participant).to receive(:complete_input!)
        allow(BroadcastService).to receive(:to_character)
        allow(fight).to receive(:reload)
        allow(fight).to receive(:all_inputs_complete?).and_return(false)
      end

      it 'filters invalid decision keys' do
        allow(ai_service).to receive(:decide!).and_return({
          main_action: 'attack',
          invalid_key: 'should be filtered',
          target_participant_id: 5
        })

        expect(participant).to receive(:update) do |args|
          expect(args.keys).not_to include(:invalid_key)
          expect(args[:main_action]).to eq('attack')
        end

        handler.send(:apply_and_submit_autobattle!)
      end

      it 'sets action_set flags automatically' do
        allow(ai_service).to receive(:decide!).and_return({
          main_action: 'attack',
          tactic_choice: 'aggressive',
          movement_action: 'stand_still'
        })

        expect(participant).to receive(:update) do |args|
          expect(args[:main_action_set]).to be true
          expect(args[:tactical_action_set]).to be true
          expect(args[:movement_set]).to be true
          expect(args[:willpower_set]).to be true
        end

        handler.send(:apply_and_submit_autobattle!)
      end
    end
  end

  describe 'check round resolution error handling' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:fight_service) { double('FightService') }

    describe '#check_round_resolution' do
      before do
        allow(fight).to receive(:reload)
        allow(FightService).to receive(:new).and_return(fight_service)
      end

      it 'continues when roll display broadcast fails' do
        allow(fight_service).to receive(:ready_to_resolve?).and_return(true)
        allow(fight_service).to receive(:resolve_round!).and_return({ roll_display: [{ test: 'data' }] })
        allow(BroadcastService).to receive(:to_room).and_raise(StandardError.new('Broadcast error'))
        allow(fight_service).to receive(:generate_narrative).and_return('Narrative')
        allow(fight_service).to receive(:should_end?).and_return(true)
        allow(fight_service).to receive(:end_fight!)
        allow(fight).to receive(:winner).and_return(nil)
        allow(fight).to receive(:room_id).and_return(room.id)

        # Should not raise, should continue to end fight
        expect { handler.send(:check_round_resolution) }.not_to raise_error
      end

      it 'handles resolve_round! errors gracefully' do
        allow(fight_service).to receive(:ready_to_resolve?).and_return(true)
        allow(fight_service).to receive(:resolve_round!).and_raise(StandardError.new('Resolution error'))
        allow(fight_service).to receive(:generate_narrative).and_return('Narrative')
        allow(BroadcastService).to receive(:to_room)
        allow(fight_service).to receive(:should_end?).and_return(false)
        allow(fight_service).to receive(:next_round!)
        allow(fight).to receive(:room_id).and_return(room.id)
        allow(fight).to receive(:round_number).and_return(2)
        allow(fight).to receive(:active_participants).and_return([])

        expect { handler.send(:check_round_resolution) }.not_to raise_error
      end
    end
  end

  describe 'main action summary with ability' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#main_action_summary' do
      it 'returns ability name when using ability' do
        ability = double('Ability', name: 'Fireball')
        allow(participant).to receive(:main_action_set).and_return(true)
        allow(participant).to receive(:main_action).and_return('ability')
        allow(participant).to receive(:selected_ability).and_return(ability)

        summary = handler.send(:main_action_summary)

        expect(summary).to eq('Fireball')
      end

      it 'returns Pass info for pass action' do
        allow(participant).to receive(:main_action_set).and_return(true)
        allow(participant).to receive(:main_action).and_return('pass')

        summary = handler.send(:main_action_summary)

        expect(summary).to eq('Pass (no action)')
      end

      it 'returns attack with monster target info' do
        monster = double('LargeMonsterInstance', display_name: 'Dragon')
        segment = double('MonsterSegmentInstance', name: 'Head')

        allow(participant).to receive(:main_action_set).and_return(true)
        allow(participant).to receive(:main_action).and_return('attack')
        allow(participant).to receive(:targeting_monster_id).and_return(10)
        allow(participant).to receive(:targeting_segment_id).and_return(20)
        allow(LargeMonsterInstance).to receive(:[]).with(10).and_return(monster)
        allow(MonsterSegmentInstance).to receive(:[]).with(20).and_return(segment)

        summary = handler.send(:main_action_summary)

        expect(summary).to include('Dragon')
        expect(summary).to include('Head')
      end

      it 'handles monster target without segment' do
        monster = double('LargeMonsterInstance', display_name: 'Giant')

        allow(participant).to receive(:main_action_set).and_return(true)
        allow(participant).to receive(:main_action).and_return('attack')
        allow(participant).to receive(:targeting_monster_id).and_return(10)
        allow(participant).to receive(:targeting_segment_id).and_return(nil)
        allow(LargeMonsterInstance).to receive(:[]).with(10).and_return(monster)

        summary = handler.send(:main_action_summary)

        expect(summary).to include('Giant')
        expect(summary).not_to include('(')
      end
    end
  end

  describe 'build main target options with taunt warnings' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#build_main_target_options' do
      let(:taunter) { double('FightParticipant', id: 20, character_name: 'Taunter', side: 2, current_hp: 5, max_hp: 6, fight: fight) }
      let(:other_enemy) { double('FightParticipant', id: 21, character_name: 'Other', side: 2, current_hp: 4, max_hp: 6, fight: fight) }

      before do
        allow(participant).to receive(:pending_action_name).and_return(nil)
        allow(participant).to receive(:selected_ability).and_return(nil)
        allow(participant).to receive(:side).and_return(1)
        allow(participant).to receive(:hex_distance_to).and_return(2)
        allow(participant).to receive(:melee_weapon).and_return(nil)
        allow(participant).to receive(:ranged_weapon).and_return(nil)
        allow(fight).to receive(:has_monster).and_return(false)

        # Set up target filtering
        allow(fight).to receive(:active_participants).and_return(
          double(exclude: double(exclude: [taunter, other_enemy]))
        )
        allow(StatusEffectService).to receive(:cannot_target_ids).and_return([])
        allow(StatusEffectService).to receive(:must_target).and_return(20)
        allow(StatusEffectService).to receive(:taunt_penalty).and_return(-4)
      end

      it 'shows taunt warning for taunter target' do
        options = handler.send(:build_main_target_options)

        taunter_option = options.find { |o| o[:key] == '20' }
        expect(taunter_option[:description]).to include('TAUNTED')
      end

      it 'shows penalty warning for non-taunter targets' do
        options = handler.send(:build_main_target_options)

        other_option = options.find { |o| o[:key] == '21' }
        expect(other_option[:description]).to include('-4 penalty')
      end
    end
  end

  describe 'build willpower options edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#build_willpower_options' do
      it 'shows ability options when main action is ability' do
        allow(participant).to receive(:available_willpower_dice).and_return(2)
        allow(participant).to receive(:main_action).and_return('ability')

        options = handler.send(:build_willpower_options)

        ability_options = options.select { |o| o[:key] =~ /^ability_\d+$/ }
        expect(ability_options.length).to eq(2)
      end

      it 'hides ability options when main action is not ability' do
        allow(participant).to receive(:available_willpower_dice).and_return(2)
        allow(participant).to receive(:main_action).and_return('attack')

        options = handler.send(:build_willpower_options)

        ability_options = options.select { |o| o[:key] =~ /^ability_\d+$/ }
        expect(ability_options).to be_empty
      end

      it 'caps options at MAX_WILLPOWER_SPEND' do
        allow(participant).to receive(:available_willpower_dice).and_return(10)
        allow(participant).to receive(:main_action).and_return('attack')

        options = handler.send(:build_willpower_options)

        # Should have options for 1 to MAX_WILLPOWER_SPEND only
        attack_options = options.select { |o| o[:key] =~ /^attack_\d+$/ }
        max_count = CombatQuickmenuHandler::MAX_WILLPOWER_SPEND
        expect(attack_options.length).to eq(max_count)
      end
    end
  end

  describe 'tactical action with dazed status' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#build_tactical_action_options' do
      it 'shows dazed message when dazed' do
        allow(StatusEffectService).to receive(:can_use_tactical_action?).and_return(false)

        options = handler.send(:build_tactical_action_options)

        dazed_option = options.find { |o| o[:key] == 'dazed' }
        expect(dazed_option).not_to be_nil
        expect(dazed_option[:disabled]).to be true
        expect(dazed_option[:label]).to eq('DAZED')
      end
    end
  end

  describe 'tactical ability selection' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#handle_tactical_action_choice' do
      let(:ability) { double('Ability', id: 50, name: 'Heal', target_type: 'ally') }

      before do
        allow(Ability).to receive(:[]).with(50).and_return(ability)
        allow(participant).to receive(:available_tactical_abilities).and_return([ability])
        allow(participant).to receive(:update)
      end

      it 'moves to target selection for ally-targeted tactical ability' do
        expect(participant).to receive(:update).with(hash_including(input_stage: 'tactical_ability_target'))

        handler.send(:handle_tactical_action_choice, 'tactical_ability_50')
      end

      it 'completes immediately for self-targeted tactical ability' do
        self_ability = double('Ability', id: 51, name: 'Shield', target_type: 'self')
        allow(Ability).to receive(:[]).with(51).and_return(self_ability)
        allow(participant).to receive(:available_tactical_abilities).and_return([self_ability])

        expect(participant).to receive(:update).with(hash_including(
          tactical_action_set: true,
          input_stage: 'main_menu'
        ))

        handler.send(:handle_tactical_action_choice, 'tactical_ability_51')
      end

      it 'ignores invalid ability id' do
        allow(Ability).to receive(:[]).with(99).and_return(nil)

        # Should return early without update
        handler.send(:handle_tactical_action_choice, 'tactical_ability_99')
      end
    end
  end

  describe 'log resolution error' do
    subject(:handler) { described_class.new(participant, character_instance) }

    it 'handles file write failures gracefully' do
      error = StandardError.new('Test error')
      allow(error).to receive(:backtrace).and_return(['line 1', 'line 2'])

      # Mock File.open to raise error
      allow(File).to receive(:open).and_raise(Errno::EACCES.new('Permission denied'))

      # Should not raise, should log to stderr
      expect { handler.send(:log_resolution_error, 'test_step', error) }.not_to raise_error
    end
  end

  # ===== ADDITIONAL EDGE CASE TESTS =====

  describe 'monster targeting edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#handle_main_target_choice' do
      before do
        allow(participant).to receive(:update)
      end

      it 'handles invalid monster_id gracefully' do
        allow(LargeMonsterInstance).to receive(:[]).with(99999).and_return(nil)

        # Should not update participant when monster not found
        expect(participant).not_to receive(:update)

        handler.send(:handle_main_target_choice, 'monster_99999')
      end

      it 'handles inactive monster gracefully' do
        inactive_monster = double('LargeMonsterInstance', id: 123, status: 'defeated')
        allow(LargeMonsterInstance).to receive(:[]).with(123).and_return(inactive_monster)

        # Should not update participant when monster is inactive
        expect(participant).not_to receive(:update)

        handler.send(:handle_main_target_choice, 'monster_123')
      end
    end
  end

  describe 'mounted movement edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#build_mounted_movement_options' do
      it 'handles nil mount_state gracefully' do
        monster = double('Monster', id: 1)
        allow(participant).to receive(:is_mounted).and_return(true)
        allow(participant).to receive(:targeting_monster_id).and_return(1)
        allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
        allow(MonsterMountState).to receive(:first).and_return(nil)

        options = handler.send(:build_mounted_movement_options)

        expect(options).to be_an(Array)
        # Should still have climb option without progress info
        climb_opt = options.find { |o| o[:key] == 'climb' }
        expect(climb_opt[:description]).to eq('Progress toward weak point')
      end

      it 'shows at_weak_point indicator when reached' do
        mount_state = double('MonsterMountState', climb_progress: 3, at_weak_point?: true)
        monster = double('Monster', id: 1, monster_template: double(climb_distance: 3))

        allow(participant).to receive(:is_mounted).and_return(true)
        allow(participant).to receive(:targeting_monster_id).and_return(1)
        allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
        allow(MonsterMountState).to receive(:first).and_return(mount_state)

        options = handler.send(:build_mounted_movement_options)

        weak_point_opt = options.find { |o| o[:key] == 'at_weak_point' }
        expect(weak_point_opt).not_to be_nil
        expect(weak_point_opt[:disabled]).to be true
      end
    end
  end

  describe 'adjacent monsters edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#adjacent_monsters' do
      it 'returns empty array when fight has no monster' do
        allow(fight).to receive(:has_monster).and_return(false)

        result = handler.send(:adjacent_monsters)

        expect(result).to eq([])
      end
    end
  end

  describe 'process mount action edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#process_mount_action' do
      it 'does nothing for nil monster' do
        allow(LargeMonsterInstance).to receive(:[]).with(999).and_return(nil)

        expect(participant).not_to receive(:update)

        handler.send(:process_mount_action, 999)
      end

      it 'does nothing for inactive monster' do
        inactive_monster = double('Monster', id: 123, status: 'defeated')
        allow(LargeMonsterInstance).to receive(:[]).with(123).and_return(inactive_monster)

        expect(participant).not_to receive(:update)

        handler.send(:process_mount_action, 123)
      end
    end
  end

  describe 'process climb action edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#process_climb_action' do
      it 'does nothing when not mounted' do
        allow(participant).to receive(:is_mounted).and_return(false)

        expect(MonsterMountingService).not_to receive(:new)

        handler.send(:process_climb_action)
      end

      it 'does nothing when no targeting_monster_id' do
        allow(participant).to receive(:is_mounted).and_return(true)
        allow(participant).to receive(:targeting_monster_id).and_return(nil)

        expect(MonsterMountingService).not_to receive(:new)

        handler.send(:process_climb_action)
      end

      it 'does nothing when monster not found' do
        allow(participant).to receive(:is_mounted).and_return(true)
        allow(participant).to receive(:targeting_monster_id).and_return(999)
        allow(LargeMonsterInstance).to receive(:[]).with(999).and_return(nil)

        expect(MonsterMountingService).not_to receive(:new)

        handler.send(:process_climb_action)
      end

      it 'does nothing when mount_state not found' do
        monster = double('Monster', id: 1)
        allow(participant).to receive(:is_mounted).and_return(true)
        allow(participant).to receive(:targeting_monster_id).and_return(1)
        allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
        allow(MonsterMountState).to receive(:first).and_return(nil)

        expect(MonsterMountingService).not_to receive(:new)

        handler.send(:process_climb_action)
      end
    end

    describe '#process_cling_action' do
      it 'does nothing when not mounted' do
        allow(participant).to receive(:is_mounted).and_return(false)

        expect(MonsterMountingService).not_to receive(:new)

        handler.send(:process_cling_action)
      end
    end

    describe '#process_dismount_action' do
      it 'does nothing when not mounted' do
        allow(participant).to receive(:is_mounted).and_return(false)

        expect(MonsterMountingService).not_to receive(:new)

        handler.send(:process_dismount_action)
      end

      it 'does not update participant when dismount fails' do
        monster = double('Monster', id: 1)
        mount_state = double('MountState')
        mounting_service = double('MonsterMountingService')

        allow(participant).to receive(:is_mounted).and_return(true)
        allow(participant).to receive(:targeting_monster_id).and_return(1)
        allow(LargeMonsterInstance).to receive(:[]).with(1).and_return(monster)
        allow(MonsterMountState).to receive(:first).and_return(mount_state)
        allow(MonsterMountingService).to receive(:new).and_return(mounting_service)
        allow(mounting_service).to receive(:process_dismount).and_return({ success: false })

        expect(participant).not_to receive(:update)

        handler.send(:process_dismount_action)
      end
    end
  end

  describe 'eligible targets for tactical ability edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#eligible_targets_for_tactical_ability' do
      let(:active_participants) { double('participants_dataset') }

      before do
        allow(fight).to receive(:active_participants).and_return(active_participants)
        allow(participant).to receive(:side).and_return(1)
      end

      it 'returns allies for ally target type' do
        ability = double('Ability', target_type: 'ally')
        allow(active_participants).to receive(:where).with(side: 1).and_return(double(to_a: [participant]))

        result = handler.send(:eligible_targets_for_tactical_ability, ability)

        expect(result).to eq([participant])
      end

      it 'returns enemies for enemy target type' do
        ability = double('Ability', target_type: 'enemy')
        enemy = double('enemy_participant')
        allow(active_participants).to receive(:exclude).with(side: 1).and_return(double(to_a: [enemy]))

        result = handler.send(:eligible_targets_for_tactical_ability, ability)

        expect(result).to eq([enemy])
      end

      it 'returns self for self target type' do
        ability = double('Ability', target_type: 'self')

        result = handler.send(:eligible_targets_for_tactical_ability, ability)

        expect(result).to eq([participant])
      end

      it 'returns all participants for unknown target type' do
        ability = double('Ability', target_type: 'any')
        all = [participant, double('other')]
        allow(active_participants).to receive(:to_a).and_return(all)

        result = handler.send(:eligible_targets_for_tactical_ability, ability)

        expect(result).to eq(all)
      end

      it 'handles allies target type' do
        ability = double('Ability', target_type: 'allies')
        allies = [participant, double('ally')]
        allow(active_participants).to receive(:where).with(side: 1).and_return(double(to_a: allies))

        result = handler.send(:eligible_targets_for_tactical_ability, ability)

        expect(result).to eq(allies)
      end

      it 'handles enemies target type' do
        ability = double('Ability', target_type: 'enemies')
        enemies = [double('enemy1'), double('enemy2')]
        allow(active_participants).to receive(:exclude).with(side: 1).and_return(double(to_a: enemies))

        result = handler.send(:eligible_targets_for_tactical_ability, ability)

        expect(result).to eq(enemies)
      end
    end
  end

  describe 'force recovery transition edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#force_recovery_transition' do
      let(:fight_service) { double('FightService') }

      before do
        allow(fight).to receive(:reload)
        allow(fight).to receive(:room_id).and_return(1)
        allow(fight).to receive(:fight_participants).and_return([])
        allow(BroadcastService).to receive(:to_room)
      end

      it 'forces complete when should_end is true and fight stuck' do
        allow(fight).to receive(:status).and_return('resolving')
        allow(fight_service).to receive(:should_end?).and_return(true)
        allow(fight).to receive(:update)

        expect(fight).to receive(:update).with(hash_including(status: 'complete'))

        handler.send(:force_recovery_transition, fight_service)
      end

      it 'forces next round input when should_end is false and fight stuck' do
        allow(fight).to receive(:status).and_return('narrative')
        allow(fight).to receive(:round_number).and_return(1)
        allow(fight_service).to receive(:should_end?).and_return(false)
        allow(fight).to receive(:update)

        expect(fight).to receive(:update).with(hash_including(status: 'input', round_number: 2))

        handler.send(:force_recovery_transition, fight_service)
      end

      it 'does nothing when fight not stuck in resolving/narrative' do
        allow(fight).to receive(:status).and_return('input')

        expect(fight).not_to receive(:update)

        handler.send(:force_recovery_transition, fight_service)
      end

      it 'handles Sequel database errors gracefully' do
        allow(fight).to receive(:status).and_return('resolving')
        allow(fight_service).to receive(:should_end?).and_return(true)
        # First update raises StandardError (caught by outer rescue)
        # Second update in final rescue raises Sequel::DatabaseError (caught and logged)
        call_count = 0
        allow(fight).to receive(:update) do
          call_count += 1
          if call_count == 1
            raise StandardError.new('DB error')
          else
            raise Sequel::DatabaseError.new('Connection lost')
          end
        end

        # Should not raise - both errors are handled
        expect { handler.send(:force_recovery_transition, fight_service) }.not_to raise_error
      end

      it 'allows non-Sequel errors from final update to propagate' do
        allow(fight).to receive(:status).and_return('resolving')
        allow(fight_service).to receive(:should_end?).and_return(true)
        # Both updates raise StandardError - the second one will propagate
        allow(fight).to receive(:update).and_raise(StandardError.new('Non-DB error'))

        # StandardError from final update propagates (only Sequel::DatabaseError is caught)
        expect { handler.send(:force_recovery_transition, fight_service) }.to raise_error(StandardError)
      end
    end
  end

  describe 'handle movement choice edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#handle_movement_choice' do
      before do
        allow(participant).to receive(:update)
      end

      it 'does not update when flee exit not found' do
        allow(participant).to receive(:available_flee_exits).and_return([])

        expect(participant).not_to receive(:update).with(hash_including(movement_action: 'flee'))

        handler.send(:handle_movement_choice, 'flee_north')
      end

      it 'processes flee correctly when exit found' do
        # exit is now the destination Room directly (not RoomExit with to_room)
        flee_exit = { direction: 'south', exit: double('Room', id: 5, name: 'Garden') }
        allow(participant).to receive(:available_flee_exits).and_return([flee_exit])

        expect(participant).to receive(:update).with(hash_including(
          movement_action: 'flee',
          is_fleeing: true,
          flee_direction: 'south',
          flee_exit_id: 5
        ))

        handler.send(:handle_movement_choice, 'flee_south')
      end
    end
  end

  describe 'build personal summary edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#build_personal_summary' do
      it 'handles empty events' do
        result = handler.send(:build_personal_summary, participant, [])

        expect(result).to eq('')
      end

      it 'handles damage_tick event type' do
        events = [
          { target_id: participant.id, event_type: 'damage_tick', details: { damage: 5 } }
        ]
        allow(handler).to receive(:status_text).and_return('HP: 5/10')

        result = handler.send(:build_personal_summary, participant, events)

        expect(result).to include('You took 5 total damage')
      end

      it 'handles hazard_damage event type' do
        events = [
          { target_id: participant.id, event_type: 'hazard_damage', details: { damage: 3 } }
        ]
        allow(handler).to receive(:status_text).and_return('HP: 7/10')

        result = handler.send(:build_personal_summary, participant, events)

        expect(result).to include('You took 3 total damage')
      end

      it 'handles healing_tick event type' do
        events = [
          { target_id: participant.id, event_type: 'healing_tick', details: { amount: 4 } }
        ]
        allow(handler).to receive(:status_text).and_return('HP: 9/10')

        result = handler.send(:build_personal_summary, participant, events)

        expect(result).to include('You healed 4 HP')
      end

      it 'handles status_applied without effect_name' do
        events = [
          { target_id: participant.id, event_type: 'status_applied', details: {} }
        ]
        allow(handler).to receive(:status_text).and_return('HP: 10/10')

        result = handler.send(:build_personal_summary, participant, events)

        # Should not include status line when no effect_name
        expect(result).not_to include('affected by')
      end

      it 'handles lifesteal with zero amount' do
        events = [
          { actor_id: participant.id, event_type: 'ability_lifesteal', details: { amount: 0 } }
        ]

        result = handler.send(:build_personal_summary, participant, events)

        # Should not include lifesteal line when amount is 0
        expect(result).not_to include('drained')
      end

      it 'handles ability_hit with ability name' do
        events = [
          {
            actor_id: participant.id,
            event_type: 'ability_hit',
            target_name: 'Enemy',
            details: { effective_damage: 10, ability_name: 'Fireball' }
          }
        ]
        allow(handler).to receive(:status_text).and_return('HP: 10/10')

        result = handler.send(:build_personal_summary, participant, events)

        expect(result).to include('You dealt 10 damage to Enemy with Fireball')
      end
    end
  end

  describe 'build tactical ability target options edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#build_tactical_ability_target_options' do
      it 'returns only back option when ability not found' do
        allow(participant).to receive(:tactical_ability_id).and_return(999)
        allow(Ability).to receive(:[]).with(999).and_return(nil)

        options = handler.send(:build_tactical_ability_target_options)

        expect(options.length).to eq(1)
        expect(options.first[:key]).to eq('back')
      end

      it 'marks out-of-range targets as disabled' do
        ability = double('Ability', target_type: 'ally', range_in_hexes: 2)
        ally = double('Ally', id: 2)
        allow(ally).to receive(:character_name).and_return('Far Ally')

        allow(participant).to receive(:tactical_ability_id).and_return(1)
        allow(Ability).to receive(:[]).with(1).and_return(ability)
        allow(handler).to receive(:eligible_targets_for_tactical_ability).and_return([ally])
        allow(participant).to receive(:respond_to?).with(:hex_distance_to).and_return(true)
        allow(participant).to receive(:hex_distance_to).with(ally).and_return(5)
        allow(handler).to receive(:status_text).with(ally).and_return('HP: 10/10')

        options = handler.send(:build_tactical_ability_target_options)

        target_opt = options.find { |o| o[:key] == '2' }
        expect(target_opt[:disabled]).to be true
        expect(target_opt[:description]).to include('out of range')
      end

      it 'handles nil distance gracefully' do
        ability = double('Ability', target_type: 'ally', range_in_hexes: 3)
        ally = double('Ally', id: 2)
        allow(ally).to receive(:character_name).and_return('Ally')

        allow(participant).to receive(:tactical_ability_id).and_return(1)
        allow(Ability).to receive(:[]).with(1).and_return(ability)
        allow(handler).to receive(:eligible_targets_for_tactical_ability).and_return([ally])
        allow(participant).to receive(:respond_to?).with(:hex_distance_to).and_return(false)
        allow(handler).to receive(:status_text).with(ally).and_return('HP: 10/10')

        options = handler.send(:build_tactical_ability_target_options)

        target_opt = options.find { |o| o[:key] == '2' }
        # nil distance treated as in-range
        expect(target_opt[:disabled]).to be false
      end
    end
  end

  describe 'side selection edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#handle_side_select_choice' do
      before do
        allow(participant).to receive(:update)
      end

      it 'ignores zero or negative side selection' do
        expect(participant).not_to receive(:update).with(hash_including(side: 0))

        handler.send(:handle_side_select_choice, '0')
      end

      it 'ignores non-numeric side selection' do
        expect(participant).not_to receive(:update).with(hash_including(side: 0))

        handler.send(:handle_side_select_choice, 'invalid')
      end
    end
  end

  describe 'main action summary edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#main_action_summary' do
      it 'returns Not set when main_action_set is false' do
        allow(participant).to receive(:main_action_set).and_return(false)

        result = handler.send(:main_action_summary)

        expect(result).to eq('Not set')
      end

      it 'handles surrender action' do
        allow(participant).to receive(:main_action_set).and_return(true)
        allow(participant).to receive(:main_action).and_return('surrender')

        result = handler.send(:main_action_summary)

        # Surrender falls through to 'Set' in the else clause
        expect(result).to eq('Set')
      end

      it 'handles attack with monster target where monster not found' do
        allow(participant).to receive(:main_action_set).and_return(true)
        allow(participant).to receive(:main_action).and_return('attack')
        allow(participant).to receive(:targeting_monster_id).and_return(999)
        allow(participant).to receive(:targeting_segment_id).and_return(nil)
        allow(LargeMonsterInstance).to receive(:[]).with(999).and_return(nil)

        result = handler.send(:main_action_summary)

        expect(result).to eq('Attack monster')
      end
    end
  end

  describe 'tactical action summary edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#tactical_action_summary' do
      it 'returns Not set when tactical_action_set is false' do
        allow(participant).to receive(:tactical_action_set).and_return(false)

        result = handler.send(:tactical_action_summary)

        expect(result).to eq('Not set')
      end

      it 'returns ability name without target for self-targeted ability' do
        ability = double('Ability', name: 'Shield')
        allow(participant).to receive(:tactical_action_set).and_return(true)
        allow(participant).to receive(:tactical_ability_id).and_return(1)
        allow(participant).to receive(:tactic_target_participant).and_return(nil)
        allow(Ability).to receive(:[]).with(1).and_return(ability)

        result = handler.send(:tactical_action_summary)

        expect(result).to eq('Shield')
      end
    end
  end

  describe 'done validation message edge cases' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#done_validation_message' do
      it 'returns ready when can_complete is true' do
        allow(participant).to receive(:main_action_set).and_return(true)

        result = handler.send(:done_validation_message)

        expect(result).to eq('Ready to submit')
      end

      it 'returns instruction when main action not set' do
        allow(participant).to receive(:main_action_set).and_return(false)

        result = handler.send(:done_validation_message)

        expect(result).to eq('Choose a main action first')
      end
    end
  end
end
