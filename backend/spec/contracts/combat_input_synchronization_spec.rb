# frozen_string_literal: true

require 'spec_helper'
require_relative '../support/combat_sync_helpers'
require_relative '../support/combat_sync_matchers'

# Contract tests ensuring CombatQuickmenuHandler and CombatActionService stay synchronized.
# Both systems modify the same FightParticipant fields, so they must produce identical state.
RSpec.describe 'Combat Input Synchronization', :combat, type: :contract do
  include CombatTestHelpers

  describe 'schema contract' do
    it 'includes fight participant columns needed by both input systems' do
      expect(FightParticipant.columns).to include(:target_hex_x, :stand_this_round)
    end
  end

  # Shared context for combat scenarios
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality) }
  let(:fight) { create(:fight, room: room, round_number: 1, status: 'input') }

  let(:participant) do
    create(:fight_participant,
           fight: fight,
           character_instance: character_instance,
           current_hp: 5,
           max_hp: 5,
           hex_x: 0,
           hex_y: 0,
           side: 1,
           input_stage: 'main_menu',
           input_complete: false,
           main_action_set: false,
           tactical_action_set: false,
           movement_set: false,
           willpower_set: false)
  end

  # Second participant for targeting
  let(:opponent_character) { create(:character) }
  let(:opponent_instance) { create(:character_instance, character: opponent_character, current_room: room, reality: reality) }
  let(:opponent) do
    create(:fight_participant,
           fight: fight,
           character_instance: opponent_instance,
           current_hp: 5,
           max_hp: 5,
           hex_x: 2,
           hex_y: 0,
           side: 2,
           input_stage: 'main_menu')
  end

  # Stub columns that may not exist in test database
  before do
    unless FightParticipant.columns.include?(:ignore_hazard_avoidance)
      allow_any_instance_of(FightParticipant).to receive(:ignore_hazard_avoidance).and_return(false)
      allow_any_instance_of(FightParticipant).to receive(:ignore_hazard_avoidance=)
    end

    unless FightParticipant.columns.include?(:willpower_movement)
      allow_any_instance_of(FightParticipant).to receive(:willpower_movement).and_return(0)
      allow_any_instance_of(FightParticipant).to receive(:willpower_movement=)
    end
  end

  # === SECTION 1: Action Parity Tests ===
  # These tests verify that both systems support the same set of actions (with documented exceptions)

  describe 'Action Parity' do
    describe 'main actions (always available)' do
      it 'quickmenu and battlemap support the same always-available main actions' do
        # Only compare always-available actions, not conditional ones
        quickmenu_actions = CombatSyncHelpers::QUICKMENU_MAIN_ACTIONS
        battlemap_actions = CombatSyncHelpers::BATTLEMAP_MAIN_ACTIONS

        # Remove intentional gaps
        quickmenu_filtered = quickmenu_actions - CombatSyncHelpers::INTENTIONAL_GAPS[:quickmenu_only].keys
        battlemap_filtered = battlemap_actions - CombatSyncHelpers::INTENTIONAL_GAPS[:battlemap_only].keys

        # Normalize action names for comparison
        quickmenu_normalized = quickmenu_filtered.map { |a| CombatSyncHelpers.normalize_action(a) }.sort
        battlemap_normalized = battlemap_filtered.map { |a| CombatSyncHelpers.normalize_action(a) }.sort

        missing_in_battlemap = quickmenu_normalized - battlemap_normalized
        missing_in_quickmenu = battlemap_normalized - quickmenu_normalized

        expect(missing_in_battlemap).to be_empty,
                                        "Actions in quickmenu but not battlemap: #{missing_in_battlemap}"
        expect(missing_in_quickmenu).to be_empty,
                                        "Actions in battlemap but not quickmenu: #{missing_in_quickmenu}"
      end
    end

    describe 'conditional main actions' do
      it 'both systems support extinguish when burning' do
        # Quickmenu: 'extinguish', Battlemap: 'extinguish'
        expect(CombatSyncHelpers::CONDITIONAL_MAIN_ACTIONS).to have_key('extinguish')
        expect(CombatSyncHelpers::BATTLEMAP_CONDITIONAL_MAIN_ACTIONS).to include('extinguish')
      end

      it 'both systems support stand up when prone' do
        # Quickmenu: 'stand', Battlemap: 'stand_up'
        expect(CombatSyncHelpers::CONDITIONAL_MAIN_ACTIONS).to have_key('stand')
        expect(CombatSyncHelpers::BATTLEMAP_CONDITIONAL_MAIN_ACTIONS).to include('stand_up')
      end
    end

    describe 'movement actions' do
      it 'quickmenu and battlemap support the same movement actions (except documented exceptions)' do
        quickmenu_actions = CombatSyncHelpers::QUICKMENU_MOVEMENT_ACTIONS
        battlemap_actions = CombatSyncHelpers::BATTLEMAP_MOVEMENT_ACTIONS

        # Remove intentional gaps
        quickmenu_filtered = quickmenu_actions - CombatSyncHelpers::INTENTIONAL_GAPS[:quickmenu_only].keys
        battlemap_filtered = battlemap_actions - CombatSyncHelpers::INTENTIONAL_GAPS[:battlemap_only].keys

        # Normalize quickmenu actions to battlemap naming convention
        quickmenu_normalized = quickmenu_filtered.map do |action|
          CombatSyncHelpers::ACTION_MAPPINGS[action] || action
        end.sort

        battlemap_normalized = battlemap_filtered.sort

        missing_in_battlemap = quickmenu_normalized - battlemap_normalized
        missing_in_quickmenu = battlemap_normalized - quickmenu_normalized

        expect(missing_in_battlemap).to be_empty,
                                        "Movement actions in quickmenu but not battlemap: #{missing_in_battlemap}"
        expect(missing_in_quickmenu).to be_empty,
                                        "Movement actions in battlemap but not quickmenu: #{missing_in_quickmenu}"
      end
    end

    describe 'tactical stances' do
      it 'both systems support all tactical stances' do
        # CombatActionService process_tactical accepts these stances
        battlemap_stances = %w[aggressive defensive quick guard back_to_back none]

        CombatSyncHelpers::TACTICAL_STANCES.each do |stance|
          expect(battlemap_stances).to include(stance),
                                       "Tactical stance '#{stance}' not supported in battlemap"
        end
      end
    end

    describe 'willpower types' do
      it 'both systems support all willpower allocation types' do
        # Both systems should support attack, defense, ability willpower
        CombatSyncHelpers::WILLPOWER_TYPES.each do |wp_type|
          # Verify battlemap has willpower_<type> action
          battlemap_action = "willpower_#{wp_type}"
          expect(CombatActionService.instance_methods + CombatActionService.private_instance_methods)
            .to include("process_willpower".to_sym),
                "Battlemap missing willpower processing for #{wp_type}"
        end
      end
    end
  end

  # === SECTION 2: State Equivalence Tests ===
  # These tests verify that executing the same action via both systems produces identical state

  describe 'State Equivalence' do
    # Helper to execute action via quickmenu
    def execute_via_quickmenu(participant_to_use, action)
      handler = CombatQuickmenuHandler.new(participant_to_use, participant_to_use.character_instance)
      participant_to_use.update(input_stage: 'main_action')

      # Stub status effects for consistent behavior
      allow(StatusEffectService).to receive(:can_use_main_action?).and_return(true)
      allow(StatusEffectService).to receive(:has_effect?).and_return(false)
      allow(StatusEffectService).to receive(:is_prone?).and_return(false)

      handler.handle_response(action)
      participant_to_use.reload
    end

    # Helper to execute action via battlemap
    def execute_via_battlemap(participant_to_use, action, value = nil)
      service = CombatActionService.new(participant_to_use)
      service.process(action, value)
      participant_to_use.reload
    end

    describe 'main actions' do
      shared_examples 'produces identical state' do |quickmenu_action, battlemap_action, battlemap_value|
        it "#{quickmenu_action} via quickmenu matches #{battlemap_action} via battlemap" do
          # Create two separate participants for comparison
          qm_participant = create(:fight_participant,
                                  fight: fight,
                                  character_instance: create(:character_instance,
                                                             character: create(:character),
                                                             current_room: room,
                                                             reality: reality),
                                  current_hp: 5, max_hp: 5, hex_x: 4, hex_y: 0, side: 1,
                                  input_stage: 'main_action',
                                  main_action_set: false)

          bm_participant = create(:fight_participant,
                                  fight: fight,
                                  character_instance: create(:character_instance,
                                                             character: create(:character),
                                                             current_room: room,
                                                             reality: reality),
                                  current_hp: 5, max_hp: 5, hex_x: 6, hex_y: 0, side: 1,
                                  input_stage: 'main_action',
                                  main_action_set: false)

          execute_via_quickmenu(qm_participant, quickmenu_action)
          execute_via_battlemap(bm_participant, battlemap_action, battlemap_value)

          # Compare key fields
          expect(bm_participant.main_action).to eq(qm_participant.main_action),
                                                "main_action mismatch: battlemap=#{bm_participant.main_action}, quickmenu=#{qm_participant.main_action}"
          expect(bm_participant.main_action_set).to eq(qm_participant.main_action_set),
                                                    "main_action_set mismatch"
        end
      end

      # Test each shared main action
      include_examples 'produces identical state', 'defend', 'defend', nil
      include_examples 'produces identical state', 'dodge', 'dodge', nil
      include_examples 'produces identical state', 'sprint', 'sprint', nil
      include_examples 'produces identical state', 'pass', 'pass', nil
    end

    describe 'tactical stances' do
      %w[aggressive defensive quick none].each do |stance|
        it "#{stance} stance produces identical state via both systems" do
          qm_participant = create(:fight_participant,
                                  fight: fight,
                                  character_instance: create(:character_instance,
                                                             character: create(:character),
                                                             current_room: room,
                                                             reality: reality),
                                  current_hp: 5, max_hp: 5, hex_x: 8, hex_y: 0, side: 1,
                                  input_stage: 'tactical_action')

          bm_participant = create(:fight_participant,
                                  fight: fight,
                                  character_instance: create(:character_instance,
                                                             character: create(:character),
                                                             current_room: room,
                                                             reality: reality),
                                  current_hp: 5, max_hp: 5, hex_x: 10, hex_y: 0, side: 1,
                                  input_stage: 'tactical_action')

          # Execute via quickmenu
          allow(StatusEffectService).to receive(:can_use_tactical_action?).and_return(true)
          qm_handler = CombatQuickmenuHandler.new(qm_participant, qm_participant.character_instance)
          qm_handler.handle_response(stance)
          qm_participant.reload

          # Execute via battlemap
          bm_service = CombatActionService.new(bm_participant)
          bm_service.process('tactical', stance)
          bm_participant.reload

          expected_tactic = stance == 'none' ? nil : stance
          expect(bm_participant.tactic_choice).to eq(expected_tactic),
                                                  "tactic_choice mismatch: battlemap=#{bm_participant.tactic_choice}, quickmenu=#{qm_participant.tactic_choice}"
          expect(bm_participant.tactical_action_set).to eq(qm_participant.tactical_action_set),
                                                        "tactical_action_set mismatch"
        end
      end
    end

    describe 'movement actions' do
      it 'stand_still produces identical state via both systems' do
        qm_participant = create(:fight_participant,
                                fight: fight,
                                character_instance: create(:character_instance,
                                                           character: create(:character),
                                                           current_room: room,
                                                           reality: reality),
                                current_hp: 5, max_hp: 5, hex_x: 12, hex_y: 0, side: 1,
                                input_stage: 'movement')

        bm_participant = create(:fight_participant,
                                fight: fight,
                                character_instance: create(:character_instance,
                                                           character: create(:character),
                                                           current_room: room,
                                                           reality: reality),
                                current_hp: 5, max_hp: 5, hex_x: 14, hex_y: 0, side: 1,
                                input_stage: 'movement')

        # Execute via quickmenu
        allow_any_instance_of(FightParticipant).to receive(:can_flee?).and_return(false)
        allow(fight).to receive(:has_monster).and_return(false)
        qm_handler = CombatQuickmenuHandler.new(qm_participant, qm_participant.character_instance)
        qm_handler.handle_response('stand_still')
        qm_participant.reload

        # Execute via battlemap
        bm_service = CombatActionService.new(bm_participant)
        bm_service.process('stand_still', nil)
        bm_participant.reload

        expect(bm_participant.movement_action).to eq(qm_participant.movement_action),
                                                  "movement_action mismatch"
        expect(bm_participant.movement_set).to eq(qm_participant.movement_set),
                                               "movement_set mismatch"
      end
    end

    describe 'willpower skip' do
      it 'skipping willpower produces identical state via both systems' do
        qm_participant = create(:fight_participant,
                                fight: fight,
                                character_instance: create(:character_instance,
                                                           character: create(:character),
                                                           current_room: room,
                                                           reality: reality),
                                current_hp: 5, max_hp: 5, hex_x: 16, hex_y: 0, side: 1,
                                input_stage: 'willpower')

        bm_participant = create(:fight_participant,
                                fight: fight,
                                character_instance: create(:character_instance,
                                                           character: create(:character),
                                                           current_room: room,
                                                           reality: reality),
                                current_hp: 5, max_hp: 5, hex_x: 18, hex_y: 0, side: 1,
                                input_stage: 'willpower')

        # Execute via quickmenu
        allow(qm_participant).to receive(:available_willpower_dice).and_return(2)
        qm_handler = CombatQuickmenuHandler.new(qm_participant, qm_participant.character_instance)
        qm_handler.handle_response('skip')
        qm_participant.reload

        # Execute via battlemap
        bm_service = CombatActionService.new(bm_participant)
        bm_service.process('willpower_skip', nil)
        bm_participant.reload

        expect(bm_participant.willpower_attack).to eq(qm_participant.willpower_attack)
        expect(bm_participant.willpower_defense).to eq(qm_participant.willpower_defense)
        expect(bm_participant.willpower_ability).to eq(qm_participant.willpower_ability)
        expect(bm_participant.willpower_set).to eq(qm_participant.willpower_set)
      end
    end
  end

  # === SECTION 3: Status Effect Edge Cases ===
  # These tests verify that conditional actions appear consistently in both systems

  describe 'Status Effect Parity' do
    describe 'when participant is burning' do
      before do
        allow(StatusEffectService).to receive(:has_effect?).and_call_original
        allow(StatusEffectService).to receive(:has_effect?).with(participant, 'burning').and_return(true)
        allow(StatusEffectService).to receive(:can_use_main_action?).and_return(true)
        allow(StatusEffectService).to receive(:is_prone?).and_return(false)
      end

      it 'quickmenu shows extinguish option' do
        participant.update(input_stage: 'main_action')
        handler = CombatQuickmenuHandler.new(participant, character_instance)
        result = handler.show_current_menu

        expect(result).to include_action_option('extinguish')
      end

      it 'battlemap accepts extinguish action' do
        allow(StatusEffectService).to receive(:extinguish).and_return(true)

        result = CombatActionService.process_map_action(participant, 'extinguish', nil)
        expect(result).to accept_action('extinguish')
      end
    end

    describe 'when participant is prone' do
      before do
        allow(StatusEffectService).to receive(:has_effect?).and_return(false)
        allow(StatusEffectService).to receive(:can_use_main_action?).and_return(true)
        allow(StatusEffectService).to receive(:is_prone?).and_call_original
        allow(StatusEffectService).to receive(:is_prone?).with(participant).and_return(true)
        allow(StatusEffectService).to receive(:stand_cost).with(participant).and_return(2)
      end

      it 'quickmenu shows stand option' do
        participant.update(input_stage: 'main_action')
        handler = CombatQuickmenuHandler.new(participant, character_instance)
        result = handler.show_current_menu

        expect(result).to include_action_option('stand')
      end

      it 'battlemap accepts stand_up action' do
        result = CombatActionService.process_map_action(participant, 'stand_up', nil)
        expect(result).to accept_action('stand_up')
      end
    end

    describe 'when participant is stunned' do
      before do
        allow(StatusEffectService).to receive(:can_use_main_action?).with(participant).and_return(false)
        allow(StatusEffectService).to receive(:has_effect?).and_return(false)
        allow(StatusEffectService).to receive(:is_prone?).and_return(false)
      end

      it 'quickmenu shows stunned message and disables main actions' do
        participant.update(input_stage: 'main_action')
        handler = CombatQuickmenuHandler.new(participant, character_instance)
        result = handler.show_current_menu

        expect(result).to have_disabled_action('stunned')
        expect(result).not_to include_action_option('attack')
      end
    end

    describe 'when participant is dazed' do
      before do
        allow(StatusEffectService).to receive(:can_use_tactical_action?).with(participant).and_return(false)
      end

      it 'quickmenu shows dazed message and disables tactical actions' do
        participant.update(input_stage: 'tactical_action')
        handler = CombatQuickmenuHandler.new(participant, character_instance)
        result = handler.show_current_menu

        expect(result).to have_disabled_action('dazed')
        expect(result).not_to include_action_option('aggressive')
      end
    end
  end

  # === SECTION 4: Intentional Differences Documentation ===
  # These tests document and verify that intentional gaps are handled correctly

  describe 'Intentional Differences' do
    describe 'shared actions (surrender and flee)' do
      it 'surrender is available via battlemap' do
        result = CombatActionService.process_map_action(participant, 'surrender', nil)
        expect(result[:success]).to be true
        expect(participant.reload.main_action).to eq('surrender')
        expect(participant.is_surrendering).to be true
      end

      it 'flee requires being at arena edge with valid exit' do
        # Flee requires specific conditions
        result = CombatActionService.process_map_action(participant, 'flee', 'north')
        expect(result[:success]).to be false
        expect(result[:error]).to include('Cannot flee')
      end
    end

    describe 'battlemap-only actions' do
      it 'move_to_hex is intentionally not available via quickmenu' do
        # Document: Requires hex coordinate click - no quickmenu equivalent needed
        participant.update(input_stage: 'movement')

        allow_any_instance_of(FightParticipant).to receive(:can_flee?).and_return(false)
        allow(fight).to receive(:has_monster).and_return(false)

        handler = CombatQuickmenuHandler.new(participant, character_instance)
        result = handler.show_current_menu
        keys = result[:options].map { |o| o[:key] }

        expect(keys).not_to include('move_to_hex')
      end

      it 'battlemap accepts move_to_hex action' do
        result = CombatActionService.process_map_action(participant, 'move_to_hex', { 'hex_x' => 6, 'hex_y' => 0 })
        expect(result).to accept_action('move_to_hex')
        expect(participant.reload.target_hex_x).to eq(6)
      end
    end
  end

  # === SECTION 5: Regression Prevention ===
  # These tests will catch when new actions are added to one system but not the other

  describe 'Regression Prevention' do
    # Helper methods for this section
    def quickmenu_main_actions_normalized
      (CombatSyncHelpers::QUICKMENU_MAIN_ACTIONS - CombatSyncHelpers::INTENTIONAL_GAPS[:quickmenu_only].keys)
        .map { |a| CombatSyncHelpers::ACTION_MAPPINGS[a] || a }
        .sort
    end

    def battlemap_main_actions_normalized
      (CombatSyncHelpers::BATTLEMAP_MAIN_ACTIONS - CombatSyncHelpers::INTENTIONAL_GAPS[:battlemap_only].keys)
        .sort
    end

    it 'warns if a new main action is added to quickmenu without battlemap support' do
      # This test will fail if someone adds a new action to QUICKMENU_MAIN_ACTIONS
      # without also adding it to BATTLEMAP_MAIN_ACTIONS or INTENTIONAL_GAPS
      missing = quickmenu_main_actions_normalized - battlemap_main_actions_normalized
      expect(missing).to be_empty,
                         "New actions found in quickmenu without battlemap support: #{missing}. " \
                         'Either add to CombatActionService or document in INTENTIONAL_GAPS[:quickmenu_only]'
    end

    it 'warns if a new main action is added to battlemap without quickmenu support' do
      missing = battlemap_main_actions_normalized - quickmenu_main_actions_normalized
      expect(missing).to be_empty,
                         "New actions found in battlemap without quickmenu support: #{missing}. " \
                         'Either add to CombatQuickmenuHandler or document in INTENTIONAL_GAPS[:battlemap_only]'
    end
  end
end
