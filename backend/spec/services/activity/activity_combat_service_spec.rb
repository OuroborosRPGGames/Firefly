# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityCombatService do
  let(:room) { create(:room) }
  let(:character) { create(:character) }
  let(:char_instance) { create(:character_instance, character: character, current_room: room, online: true) }

  let(:npc_archetype) do
    double('NpcArchetype',
           id: 1,
           name: 'Goblin',
           level: 1)
  end

  let(:participant) do
    double('ActivityParticipant',
           id: 1,
           character_instance: char_instance,
           character: character)
  end

  let(:round) do
    double('ActivityRound',
           id: 1,
           combat?: true,
           combat_npcs: [npc_archetype],
           combat_difficulty_level: 'normal',
           finale?: false,
           emit_text: 'Combat begins!',
           branches_on_failure?: false,
           fail_consequence_type: nil,
           can_fail_repeat?: false,
           fail_branch_to: nil,
           failure_branch_target: nil)
  end

  let(:instance) do
    double('ActivityInstance',
           id: 1,
           room: room,
           active_participants: [participant],
           current_round: round,
           paused_for_combat?: false,
           active_fight: nil,
           finale_npc_modifier: 0,
           pause_for_fight!: true,
           resume_from_fight!: true,
           add_difficulty_modifier!: true,
           add_finale_modifier!: true,
           switch_branch!: true)
  end

  let(:fight) do
    double('Fight',
           id: 1,
           room_id: room.id,
           ongoing?: false,
           player_victory?: true,
           winner: 'players',
           fight_participants: [],
           reset_input_deadline!: true,
           save_changes: true)
  end

  let(:balance_result) do
    {
      composition: { npc_archetype.id => { count: 1 } },
      stat_modifiers: { npc_archetype.id => 0.0 },
      difficulty_variants: {
        'normal' => {
          composition: { npc_archetype.id => { count: 1 } },
          stat_modifiers: { npc_archetype.id => 0.0 }
        }
      },
      status: 'balanced'
    }
  end

  let(:balance_service) { instance_double(BattleBalancingService, balance!: balance_result) }

  before do
    allow(FightService).to receive(:create_fight).and_return(fight)
    allow(FightService).to receive(:add_combatant)
    allow(FightService).to receive(:spawn_npc_combatant)
    allow(BattleBalancingService).to receive(:new).and_return(balance_service)
    allow(ActivityService).to receive(:advance_round)
    allow(ActivityService).to receive(:complete_activity)
  end

  describe 'CombatError' do
    it 'is a StandardError subclass' do
      expect(described_class::CombatError.superclass).to eq(StandardError)
    end
  end

  describe 'CombatResult' do
    it 'has fight_created attribute' do
      result = described_class::CombatResult.new(fight_created: true)
      expect(result.fight_created).to be true
    end

    it 'has fight_id attribute' do
      result = described_class::CombatResult.new(fight_id: 123)
      expect(result.fight_id).to eq(123)
    end

    it 'has npc_count attribute' do
      result = described_class::CombatResult.new(npc_count: 3)
      expect(result.npc_count).to eq(3)
    end

    it 'has participant_count attribute' do
      result = described_class::CombatResult.new(participant_count: 4)
      expect(result.participant_count).to eq(4)
    end

    it 'has is_finale attribute' do
      result = described_class::CombatResult.new(is_finale: true)
      expect(result.is_finale).to be true
    end

    it 'has emit_text attribute' do
      result = described_class::CombatResult.new(emit_text: 'Fight!')
      expect(result.emit_text).to eq('Fight!')
    end
  end

  describe '.start_combat' do
    context 'with valid setup' do
      it 'returns a CombatResult' do
        result = described_class.start_combat(instance, round)

        expect(result).to be_a(described_class::CombatResult)
      end

      it 'sets fight_created to true' do
        result = described_class.start_combat(instance, round)

        expect(result.fight_created).to be true
      end

      it 'sets fight_id from created fight' do
        result = described_class.start_combat(instance, round)

        expect(result.fight_id).to eq(1)
      end

      it 'sets npc_count from round NPCs' do
        result = described_class.start_combat(instance, round)

        expect(result.npc_count).to eq(1)
      end

      it 'sets participant_count from instance' do
        result = described_class.start_combat(instance, round)

        expect(result.participant_count).to eq(1)
      end

      it 'sets is_finale from round' do
        result = described_class.start_combat(instance, round)

        expect(result.is_finale).to be false
      end

      it 'sets emit_text from round' do
        result = described_class.start_combat(instance, round)

        expect(result.emit_text).to eq('Combat begins!')
      end

      it 'creates a fight via FightService' do
        expect(FightService).to receive(:create_fight).with(
          hash_including(room: room, activity_instance_id: 1)
        )

        described_class.start_combat(instance, round)
      end

      it 'adds participants as combatants' do
        expect(FightService).to receive(:add_combatant).with(fight, char_instance)

        described_class.start_combat(instance, round)
      end

      it 'spawns NPCs from archetypes' do
        expect(FightService).to receive(:spawn_npc_combatant).with(
          fight, npc_archetype, level: 1, stat_modifier: 0.0
        )

        described_class.start_combat(instance, round)
      end

      it 'uses difficulty variants from BattleBalancingService when available' do
        allow(round).to receive(:combat_difficulty_level).and_return('hard')
        allow(balance_service).to receive(:balance!).and_return(
          balance_result.merge(
            difficulty_variants: {
              'hard' => {
                composition: { npc_archetype.id => { count: 1 } },
                stat_modifiers: { npc_archetype.id => 0.15 }
              }
            }
          )
        )

        expect(FightService).to receive(:spawn_npc_combatant).with(
          fight, npc_archetype, level: 1, stat_modifier: 0.15
        )

        described_class.start_combat(instance, round)
      end

      it 'falls back to unmodified NPCs when balancing fails' do
        allow(balance_service).to receive(:balance!).and_raise(StandardError.new('boom'))

        expect(FightService).to receive(:spawn_npc_combatant).with(
          fight, npc_archetype, level: 1, stat_modifier: 0.0
        )

        described_class.start_combat(instance, round)
      end

      it 'pauses activity for fight' do
        expect(instance).to receive(:pause_for_fight!).with(fight)

        described_class.start_combat(instance, round)
      end
    end

    context 'with finale round' do
      before do
        allow(round).to receive(:finale?).and_return(true)
        allow(instance).to receive(:finale_npc_modifier).and_return(2)
      end

      it 'sets is_finale to true' do
        result = described_class.start_combat(instance, round)

        expect(result.is_finale).to be true
      end

      it 'applies finale modifier to NPC level' do
        expect(FightService).to receive(:spawn_npc_combatant).with(
          fight, npc_archetype, level: 3, stat_modifier: 0.0
        )

        described_class.start_combat(instance, round)
      end
    end

    context 'when round is not combat' do
      before do
        allow(round).to receive(:combat?).and_return(false)
      end

      it 'raises CombatError' do
        expect {
          described_class.start_combat(instance, round)
        }.to raise_error(described_class::CombatError, 'Not a combat round')
      end
    end

    context 'when no active participants' do
      before do
        allow(instance).to receive(:active_participants).and_return([])
      end

      it 'raises CombatError' do
        expect {
          described_class.start_combat(instance, round)
        }.to raise_error(described_class::CombatError, 'No active participants')
      end
    end

    context 'when already in combat' do
      before do
        allow(instance).to receive(:paused_for_combat?).and_return(true)
      end

      it 'raises CombatError' do
        expect {
          described_class.start_combat(instance, round)
        }.to raise_error(described_class::CombatError, 'Already in combat')
      end
    end

    context 'when no NPCs defined' do
      before do
        allow(round).to receive(:combat_npcs).and_return([])
      end

      it 'raises CombatError' do
        expect {
          described_class.start_combat(instance, round)
        }.to raise_error(described_class::CombatError, 'No NPCs defined for combat round')
      end
    end

    context 'when FightService is available' do
      it 'always uses FightService.create_fight' do
        expect(FightService).to receive(:create_fight).with(
          hash_including(room: room, activity_instance_id: 1)
        ).and_return(fight)

        described_class.start_combat(instance, round)
      end
    end
  end

  describe '.resolve_fight_result' do
    context 'when not paused for combat' do
      it 'returns nil' do
        result = described_class.resolve_fight_result(instance)

        expect(result).to be_nil
      end
    end

    context 'when paused but no active fight' do
      before do
        allow(instance).to receive(:paused_for_combat?).and_return(true)
      end

      it 'returns nil' do
        result = described_class.resolve_fight_result(instance)

        expect(result).to be_nil
      end
    end

    context 'when fight is still ongoing' do
      before do
        allow(instance).to receive(:paused_for_combat?).and_return(true)
        allow(instance).to receive(:active_fight).and_return(fight)
        allow(fight).to receive(:ongoing?).and_return(true)
      end

      it 'returns nil' do
        result = described_class.resolve_fight_result(instance)

        expect(result).to be_nil
      end
    end

    context 'when fight is complete with victory' do
      before do
        allow(instance).to receive(:paused_for_combat?).and_return(true)
        allow(instance).to receive(:active_fight).and_return(fight)
      end

      it 'returns success true' do
        result = described_class.resolve_fight_result(instance)

        expect(result[:success]).to be true
      end

      it 'returns can_continue true' do
        result = described_class.resolve_fight_result(instance)

        expect(result[:can_continue]).to be true
      end

      it 'resumes activity from fight' do
        expect(instance).to receive(:resume_from_fight!)

        described_class.resolve_fight_result(instance)
      end
    end

    context 'when fight is complete with defeat' do
      before do
        allow(instance).to receive(:paused_for_combat?).and_return(true)
        allow(instance).to receive(:active_fight).and_return(fight)
        allow(fight).to receive(:player_victory?).and_return(false)
        allow(fight).to receive(:winner).and_return('npcs')
      end

      it 'returns success false' do
        result = described_class.resolve_fight_result(instance)

        expect(result[:success]).to be false
      end

      context 'when round branches on failure' do
        before do
          allow(round).to receive(:branches_on_failure?).and_return(true)
        end

        it 'returns can_continue false' do
          result = described_class.resolve_fight_result(instance)

          expect(result[:can_continue]).to be false
        end
      end

      context 'when round does not branch on failure' do
        it 'returns can_continue true' do
          result = described_class.resolve_fight_result(instance)

          expect(result[:can_continue]).to be true
        end
      end

      context 'with difficulty consequence' do
        before do
          allow(round).to receive(:fail_consequence_type).and_return('difficulty')
        end

        it 'adds difficulty modifier' do
          expect(instance).to receive(:add_difficulty_modifier!).with(1)

          described_class.resolve_fight_result(instance)
        end
      end

      context 'with harder_finale consequence' do
        before do
          allow(round).to receive(:fail_consequence_type).and_return('harder_finale')
        end

        it 'adds finale modifier' do
          expect(instance).to receive(:add_finale_modifier!).with(1)

          described_class.resolve_fight_result(instance)
        end
      end
    end
  end

  describe '.on_fight_complete' do
    before do
      allow(ActivityInstance).to receive(:first).with(paused_for_fight_id: 1).and_return(instance)
    end

    context 'when no activity is paused for this fight' do
      before do
        allow(ActivityInstance).to receive(:first).and_return(nil)
      end

      it 'does nothing' do
        expect(instance).not_to receive(:resume_from_fight!)

        described_class.on_fight_complete(fight, true)
      end
    end

    context 'with victory' do
      it 'resumes activity from fight' do
        expect(instance).to receive(:resume_from_fight!)

        described_class.on_fight_complete(fight, true)
      end

      it 'advances to next round' do
        expect(ActivityService).to receive(:advance_round).with(instance)

        described_class.on_fight_complete(fight, true)
      end
    end

    context 'with defeat' do
      it 'resumes activity from fight' do
        expect(instance).to receive(:resume_from_fight!)

        described_class.on_fight_complete(fight, false)
      end

      context 'when round branches on failure' do
        before do
          allow(round).to receive(:branches_on_failure?).and_return(true)
          allow(round).to receive(:fail_branch_to).and_return(77)
          allow(ActivityService).to receive(:advance_with_branch)
        end

        it 'jumps to configured failure target round' do
          expect(ActivityService).to receive(:advance_with_branch).with(instance, 77)

          described_class.on_fight_complete(fight, false)
        end
      end

      context 'when round can fail and repeat' do
        before do
          allow(round).to receive(:can_fail_repeat?).and_return(true)
        end

        it 'does not complete activity' do
          expect(ActivityService).not_to receive(:complete_activity)

          described_class.on_fight_complete(fight, false)
        end
      end

      context 'when round cannot branch or repeat' do
        it 'completes activity as failure' do
          expect(ActivityService).to receive(:complete_activity).with(instance, success: false)

          described_class.on_fight_complete(fight, false)
        end
      end
    end
  end

  describe 'private methods' do
    describe 'fight_was_won?' do
      let(:fight_with_player_victory) do
        double('Fight', player_victory?: true)
      end

      let(:fight_with_winner) do
        fight = double('Fight')
        allow(fight).to receive(:player_victory?).and_return(false)
        allow(fight).to receive(:winner).and_return('players')
        fight
      end

      let(:simple_fight) do
        fight = double('Fight')
        allow(fight).to receive(:player_victory?).and_return(false)
        allow(fight).to receive(:winner).and_return(nil)
        fight
      end

      it 'returns true when player_victory? returns true' do
        result = described_class.send(:fight_was_won?, fight_with_player_victory, instance)

        expect(result).to be true
      end

      it 'returns true when winner is players' do
        result = described_class.send(:fight_was_won?, fight_with_winner, instance)

        expect(result).to be true
      end

      it 'checks participant HP as fallback' do
        allow(char_instance).to receive(:current_hp).and_return(5)

        result = described_class.send(:fight_was_won?, simple_fight, instance)

        expect(result).to be true
      end

      it 'returns false when participant HP is 0' do
        allow(char_instance).to receive(:current_hp).and_return(0)

        result = described_class.send(:fight_was_won?, simple_fight, instance)

        expect(result).to be false
      end
    end
  end
end
