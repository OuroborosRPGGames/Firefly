# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityResolutionService do
  describe '.roll_base_dice' do
    it 'returns a RollResult with 2 base dice without helpers' do
      result = described_class.roll_base_dice(0)
      expect(result).to be_a(DiceRollService::RollResult)
      expect(result.count).to eq(2)
      expect(result.dice.length).to be >= 2
      expect(result.sides).to eq(8)
    end

    it 'can produce values above 8 when exploding' do
      results = 500.times.map { described_class.roll_base_dice(0) }
      has_explosion = results.any? { |r| r.dice.any? { |d| d == 8 } && r.explosions.any? }
      expect(has_explosion).to be true
    end

    it 'does not explode when explode: false' do
      100.times do
        result = described_class.roll_base_dice(0, explode: false)
        expect(result.dice).to all(be_between(1, 8))
        expect(result.explosions).to be_empty
      end
    end
  end

  describe '.roll_single_with_advantage' do
    it 'returns a RollResult' do
      result = described_class.roll_single_with_advantage
      expect(result).to be_a(DiceRollService::RollResult)
    end

    it 'returns 1 if either initial face is 1 (critical failure)' do
      # Mock DiceRollService.roll to return 1 on second call
      call_count = 0
      allow(DiceRollService).to receive(:roll).with(1, 8, explode_on: 8) do
        call_count += 1
        if call_count.odd?
          DiceRollService::RollResult.new(
            dice: [5], base_dice: [5], explosions: [],
            modifier: 0, total: 5, count: 1, sides: 8, explode_on: 8
          )
        else
          DiceRollService::RollResult.new(
            dice: [1], base_dice: [1], explosions: [],
            modifier: 0, total: 1, count: 1, sides: 8, explode_on: 8
          )
        end
      end

      result = described_class.roll_single_with_advantage
      expect(result.total).to eq(1)
      expect(result.dice).to eq([1])
    end

    it 'takes the higher total when neither is 1' do
      call_count = 0
      allow(DiceRollService).to receive(:roll).with(1, 8, explode_on: 8) do
        call_count += 1
        if call_count.odd?
          DiceRollService::RollResult.new(
            dice: [3], base_dice: [3], explosions: [],
            modifier: 0, total: 3, count: 1, sides: 8, explode_on: 8
          )
        else
          DiceRollService::RollResult.new(
            dice: [7], base_dice: [7], explosions: [],
            modifier: 0, total: 7, count: 1, sides: 8, explode_on: 8
          )
        end
      end

      result = described_class.roll_single_with_advantage
      expect(result.total).to eq(7)
    end

    it 'does not explode when explode: false' do
      100.times do
        result = described_class.roll_single_with_advantage(explode: false)
        expect(result.dice).to all(be_between(1, 8))
        expect(result.explosions).to be_empty
      end
    end
  end

  describe '.roll_risk_dice' do
    it 'returns a value from RISK_VALUES' do
      100.times do
        result = described_class.roll_risk_dice
        expect(described_class::RISK_VALUES).to include(result)
      end
    end

    it 'has equal chance for positive and negative values' do
      results = 1000.times.map { described_class.roll_risk_dice }
      positive = results.count { |r| r > 0 }
      negative = results.count { |r| r < 0 }

      # With 1000 samples, should be roughly 50/50 within margin
      expect(positive).to be_within(100).of(500)
      expect(negative).to be_within(100).of(500)
    end
  end

  describe '.reroll_ones' do
    it 'rerolls dice faces that show 1' do
      allow(DiceRollService).to receive(:roll).with(1, 8, explode_on: 8).and_return(
        DiceRollService::RollResult.new(
          dice: [4], base_dice: [4], explosions: [],
          modifier: 0, total: 4, count: 1, sides: 8, explode_on: 8
        )
      )

      new_dice, new_explosions = described_class.reroll_ones([1, 5, 6], [])
      expect(new_dice).to eq([4, 5, 6])
      expect(new_explosions).to be_empty
    end

    it 'does not reroll dice that are not 1' do
      new_dice, = described_class.reroll_ones([2, 5, 6], [])
      expect(new_dice).to eq([2, 5, 6])
    end

    it 'preserves explosion indices for non-rerolled dice' do
      new_dice, new_explosions = described_class.reroll_ones([8, 5, 6], [0])
      expect(new_dice).to eq([8, 5, 6])
      expect(new_explosions).to eq([0])
    end

    it 'handles reroll that explodes' do
      allow(DiceRollService).to receive(:roll).with(1, 8, explode_on: 8).and_return(
        DiceRollService::RollResult.new(
          dice: [8, 3], base_dice: [8], explosions: [0],
          modifier: 0, total: 11, count: 1, sides: 8, explode_on: 8
        )
      )

      new_dice, new_explosions = described_class.reroll_ones([1, 5], [])
      expect(new_dice).to eq([8, 3, 5])
      expect(new_explosions).to eq([0]) # The rerolled 8 is an explosion source
    end

    it 'uses non-exploding roll when explode: false' do
      allow(DiceRollService).to receive(:roll).with(1, 8, explode_on: nil).and_return(
        DiceRollService::RollResult.new(
          dice: [7], base_dice: [7], explosions: [],
          modifier: 0, total: 7, count: 1, sides: 8, explode_on: nil
        )
      )

      new_dice, = described_class.reroll_ones([1, 5], [], explode: false)
      expect(new_dice).to eq([7, 5])
    end
  end

  describe 'RISK_VALUES constant' do
    it 'contains expected values' do
      expect(described_class::RISK_VALUES).to eq([-4, -3, -2, -1, 1, 2, 3, 4])
    end

    it 'has 8 possible outcomes' do
      expect(described_class::RISK_VALUES.length).to eq(8)
    end

    it 'is symmetric around zero' do
      expect(described_class::RISK_VALUES.sum).to eq(0)
    end
  end

  describe 'ParticipantRoll struct' do
    it 'stores all roll information including observer_effects' do
      roll = described_class::ParticipantRoll.new(
        participant_id: 1,
        character_name: 'Test',
        action_type: 'option',
        action_name: 'Attack',
        dice_results: [5, 6],
        stat_bonus: 3,
        willpower_spent: 1,
        risk_result: 2,
        total: 14,
        helped_by: ['Helper'],
        observer_effects: [:reroll_ones, :block_explosions]
      )

      expect(roll.participant_id).to eq(1)
      expect(roll.character_name).to eq('Test')
      expect(roll.action_type).to eq('option')
      expect(roll.action_name).to eq('Attack')
      expect(roll.dice_results).to eq([5, 6])
      expect(roll.stat_bonus).to eq(3)
      expect(roll.willpower_spent).to eq(1)
      expect(roll.risk_result).to eq(2)
      expect(roll.total).to eq(14)
      expect(roll.helped_by).to eq(['Helper'])
      expect(roll.observer_effects).to eq([:reroll_ones, :block_explosions])
    end
  end

  describe 'RoundResult struct' do
    it 'stores round resolution information' do
      result = described_class::RoundResult.new(
        success: true,
        highest_roll: 15,
        avg_risk: 1.5,
        final_total: 16.5,
        dc: 12,
        participant_rolls: [],
        emit_text: 'Test emit',
        result_text: 'Success!'
      )

      expect(result.success).to be true
      expect(result.highest_roll).to eq(15)
      expect(result.avg_risk).to eq(1.5)
      expect(result.final_total).to eq(16.5)
      expect(result.dc).to eq(12)
      expect(result.participant_rolls).to eq([])
      expect(result.emit_text).to eq('Test emit')
      expect(result.result_text).to eq('Success!')
    end
  end

  describe '.calculate_help_bonuses' do
    let(:universe) { create(:universe) }
    let(:world) { create(:world, universe: universe) }
    let(:area) { create(:area, world: world) }
    let(:location) { create(:location, zone: area) }
    let(:room) { create(:room, location: location) }
    let(:reality) { create(:reality) }

    let(:user1) { create(:user) }
    let(:user2) { create(:user) }
    let(:char1) { create(:character, user: user1, forename: 'Alice') }
    let(:char2) { create(:character, user: user2, forename: 'Bob') }

    it 'returns empty hash when no helpers' do
      participants = []
      result = described_class.calculate_help_bonuses(participants)
      expect(result).to be_empty
    end
  end

  describe '.roll_variable_risk' do
    it 'returns nil when sides is nil' do
      expect(described_class.roll_variable_risk(nil)).to be_nil
    end

    it 'returns nil when sides is 0' do
      expect(described_class.roll_variable_risk(0)).to be_nil
    end

    it 'returns a value between -sides and +sides (excluding 0)' do
      100.times do
        result = described_class.roll_variable_risk(3)
        expect(result.abs).to be_between(1, 3)
        expect(result).not_to eq(0)
      end
    end

    it 'produces both positive and negative results' do
      results = 500.times.map { described_class.roll_variable_risk(5) }
      expect(results.any? { |r| r > 0 }).to be true
      expect(results.any? { |r| r < 0 }).to be true
    end
  end

  describe 'observer effects integration' do
    let(:room) { create(:room) }
    let(:activity) { create(:activity) }
    let(:instance) { create(:activity_instance, activity: activity, room: room) }
    let(:character) { create(:character) }
    let(:character_instance) { create(:character_instance, character: character, current_room: room) }
    let(:participant) do
      character_instance # Ensure created first
      create(:activity_participant,
             instance: instance,
             character: character,
             willpower: 5,
             willpower_to_spend: 0,
             action_chosen: action.id)
    end
    let(:action) { create(:activity_action, activity: activity) }

    let(:observer_char) { create(:character) }
    let(:observer_instance) { create(:character_instance, character: observer_char, current_room: room) }

    # Helper to build a mock RollResult for stubbing
    def mock_roll_result(dice, explosions: [])
      DiceRollService::RollResult.new(
        dice: dice,
        base_dice: dice[0..1],
        explosions: explosions,
        modifier: 0,
        total: dice.sum,
        count: 2,
        sides: 8,
        explode_on: 8
      )
    end

    # Stub action.stat_bonus_for to avoid needing universe setup
    before do
      allow(action).to receive(:stat_bonus_for).and_return(0)
    end

    describe 'reroll_ones effect' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: observer_instance,
               role: 'support',
               active: true,
               action_type: 'reroll_ones',
               action_target_id: participant.id)
      end

      it 'applies reroll_ones effect and records it' do
        # Mock base dice to include a 1
        allow(described_class).to receive(:roll_base_dice).and_return(mock_roll_result([1, 5]))
        # Mock the reroll to return 4
        allow(DiceRollService).to receive(:roll).with(1, 8, explode_on: 8).and_return(
          DiceRollService::RollResult.new(
            dice: [4], base_dice: [4], explosions: [],
            modifier: 0, total: 4, count: 1, sides: 8, explode_on: 8
          )
        )

        result = described_class.roll_for_participant(participant, action, nil)

        expect(result.observer_effects).to include(:reroll_ones)
        expect(result.dice_results).to eq([4, 5]) # 1 was rerolled to 4
      end
    end

    describe 'block_explosions effect' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: observer_instance,
               role: 'oppose',
               active: true,
               action_type: 'block_explosions',
               action_target_id: participant.id)
      end

      it 'applies block_explosions effect and uses non-exploding dice' do
        allow(described_class).to receive(:roll_base_dice).with(0, explode: false).and_return(mock_roll_result([8, 8]))

        result = described_class.roll_for_participant(participant, action, nil)

        expect(result.observer_effects).to include(:block_explosions)
        expect(result.dice_results).to eq([8, 8])
        expect(result.dice_results).to all(be <= 8)
      end
    end

    describe 'block_willpower effect' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: observer_instance,
               role: 'oppose',
               active: true,
               action_type: 'block_willpower',
               action_target_id: participant.id)
      end

      before do
        # Update participant to try to spend willpower
        participant.update(willpower_to_spend: 1)
      end

      it 'prevents willpower dice from being added' do
        allow(described_class).to receive(:roll_base_dice).and_return(mock_roll_result([5, 6]))

        result = described_class.roll_for_participant(participant, action, nil)

        expect(result.observer_effects).to include(:block_willpower)
        expect(result.willpower_spent).to eq(0)
        expect(result.dice_results.length).to eq(2) # Only base dice, no willpower dice
      end
    end

    describe 'damage_on_ones effect' do
      let!(:observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: observer_instance,
               role: 'oppose',
               active: true,
               action_type: 'damage_on_ones',
               action_target_id: participant.id)
      end

      it 'applies damage when a 1 is rolled' do
        allow(described_class).to receive(:roll_base_dice).and_return(mock_roll_result([1, 5]))
        allow_any_instance_of(CharacterInstance).to receive(:take_damage).with(1)

        result = described_class.roll_for_participant(participant, action, nil)

        expect(result.observer_effects).to include(:damage_on_ones)
      end

      it 'does not apply damage when no 1s are rolled' do
        allow(described_class).to receive(:roll_base_dice).and_return(mock_roll_result([5, 6]))

        result = described_class.roll_for_participant(participant, action, nil)

        expect(result.observer_effects).not_to include(:damage_on_ones)
      end
    end

    describe 'combined effects' do
      let!(:block_explosions_observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: observer_instance,
               role: 'oppose',
               active: true,
               action_type: 'block_explosions',
               action_target_id: participant.id)
      end

      let(:supporter_char) { create(:character) }
      let(:supporter_instance) { create(:character_instance, character: supporter_char, current_room: room) }

      let!(:reroll_ones_observer) do
        create(:activity_remote_observer,
               activity_instance: instance,
               character_instance: supporter_instance,
               role: 'support',
               active: true,
               action_type: 'reroll_ones',
               action_target_id: participant.id)
      end

      it 'applies multiple effects together' do
        # When block_explosions is active, reroll_ones should use non-exploding rerolls
        allow(described_class).to receive(:roll_base_dice).with(0, explode: false).and_return(mock_roll_result([1, 8]))
        allow(DiceRollService).to receive(:roll).with(1, 8, explode_on: nil).and_return(
          DiceRollService::RollResult.new(
            dice: [6], base_dice: [6], explosions: [],
            modifier: 0, total: 6, count: 1, sides: 8, explode_on: nil
          )
        )

        result = described_class.roll_for_participant(participant, action, nil)

        expect(result.observer_effects).to include(:block_explosions)
        expect(result.observer_effects).to include(:reroll_ones)
        # The 1 should have been rerolled to 6 (non-exploding)
        expect(result.dice_results).to eq([6, 8])
      end
    end

    describe 'no effects' do
      it 'returns empty observer_effects when no observers' do
        allow(described_class).to receive(:roll_base_dice).and_return(mock_roll_result([5, 6]))

        result = described_class.roll_for_participant(participant, action, nil)

        expect(result.observer_effects).to eq([])
      end
    end

    describe 'stat_swap effect' do
      before do
        # Mock ObserverEffectService to return stat_swap effect
        allow(ObserverEffectService).to receive(:effects_for).and_return({ stat_swap: :strength })
        allow(described_class).to receive(:roll_base_dice).and_return(mock_roll_result([5, 6]))
      end

      it 'uses the swapped stat for bonus calculation' do
        allow(StatAllocationService).to receive(:get_stat_value).with(anything, 'strength').and_return(5)

        result = described_class.roll_for_participant(participant, action, nil)

        expect(result.observer_effects).to include(:stat_swap)
        expect(result.stat_bonus).to eq(5)
      end

      it 'falls back to action stat_bonus if swapped stat is nil' do
        allow(StatAllocationService).to receive(:get_stat_value).with(anything, 'strength').and_return(nil)
        allow(action).to receive(:stat_bonus_for).and_return(3)

        result = described_class.roll_for_participant(participant, action, nil)

        expect(result.observer_effects).to include(:stat_swap)
        expect(result.stat_bonus).to eq(3)
      end

      it 'falls back to action stat_bonus if character_instance does not respond to get_stat_value' do
        allow_any_instance_of(CharacterInstance).to receive(:respond_to?).and_call_original
        allow_any_instance_of(CharacterInstance).to receive(:respond_to?).with(:get_stat_value).and_return(false)
        allow(action).to receive(:stat_bonus_for).and_return(4)

        result = described_class.roll_for_participant(participant, action, nil)

        expect(result.observer_effects).to include(:stat_swap)
        expect(result.stat_bonus).to eq(4)
      end
    end
  end

  # ============================================
  # Task-based resolution
  # ============================================

  describe 'TaskResult struct' do
    it 'stores task outcome information' do
      result = described_class::TaskResult.new(
        task_id: 1,
        task_description: 'Break the door',
        success: true,
        dc: 12,
        highest_roll: 15,
        avg_risk: 2.0,
        final_total: 17.0
      )

      expect(result.task_id).to eq(1)
      expect(result.task_description).to eq('Break the door')
      expect(result.success).to be true
      expect(result.dc).to eq(12)
    end
  end

  describe '.resolve with tasks' do
    let(:room) { create(:room) }
    let(:activity) { create(:activity) }
    let(:round) { create(:activity_round, activity: activity, rtype: 'standard') }
    let(:instance) { create(:activity_instance, activity: activity, room: room, rounds_done: round.round_number - 1, branch: 0) }

    let(:char1) { create(:character) }
    let(:char2) { create(:character) }
    let(:ci1) { create(:character_instance, character: char1, current_room: room) }
    let(:ci2) { create(:character_instance, character: char2, current_room: room) }

    let!(:task1) do
      create(:activity_task, round: round, task_number: 1, description: 'Break barricade', dc_reduction: 3)
    end

    let(:action1) { create(:activity_action, activity: activity, task_id: task1.id, stat_set_label: 'a') }

    # Helper to build a mock RollResult for stubbing
    def mock_roll_result(dice, explosions: [])
      DiceRollService::RollResult.new(
        dice: dice,
        base_dice: dice[0..1],
        explosions: explosions,
        modifier: 0,
        total: dice.sum,
        count: 2,
        sides: 8,
        explode_on: 8
      )
    end

    before do
      # Stub action stat methods
      allow_any_instance_of(ActivityAction).to receive(:task_stat_bonus_for).and_return(3)
      allow_any_instance_of(ActivityAction).to receive(:risk_sides_value).and_return(nil)
      allow_any_instance_of(ActivityAction).to receive(:risk_dice).and_return(nil)
    end

    context 'with single task' do
      let!(:p1) do
        ci1 # ensure created
        create(:activity_participant,
               instance: instance, character: char1,
               action_chosen: action1.id, task_chosen: task1.id,
               willpower_to_spend: 0)
      end

      it 'returns task_results in the round result' do
        allow(described_class).to receive(:roll_base_dice).and_return(mock_roll_result([6, 7]))

        result = described_class.resolve(instance, round)

        expect(result.task_results).not_to be_nil
        expect(result.task_results.length).to eq(1)
        expect(result.task_results.first.task_id).to eq(task1.id)
        expect(result.task_results.first.task_description).to eq('Break barricade')
      end

      it 'succeeds when roll meets DC' do
        allow(described_class).to receive(:roll_base_dice).and_return(mock_roll_result([8, 8]))

        result = described_class.resolve(instance, round)

        expect(result.success).to be true
        expect(result.task_results.first.success).to be true
      end

      it 'fails when roll below DC' do
        allow(described_class).to receive(:roll_base_dice).and_return(mock_roll_result([1, 1]))

        result = described_class.resolve(instance, round)

        expect(result.success).to be false
        expect(result.task_results.first.success).to be false
      end
    end

    context 'with two tasks' do
      let!(:task2) do
        create(:activity_task, round: round, task_number: 2, description: 'Disable trap',
               dc_reduction: 3, min_participants: 1)
      end
      let(:action2) { create(:activity_action, activity: activity, task_id: task2.id, stat_set_label: 'a') }

      let!(:p1) do
        ci1
        create(:activity_participant,
               instance: instance, character: char1,
               action_chosen: action1.id, task_chosen: task1.id,
               willpower_to_spend: 0)
      end

      let!(:p2) do
        ci2
        create(:activity_participant,
               instance: instance, character: char2,
               action_chosen: action2.id, task_chosen: task2.id,
               willpower_to_spend: 0)
      end

      it 'reduces DC when both tasks are active' do
        allow(described_class).to receive(:roll_base_dice).and_return(mock_roll_result([8, 8]))

        result = described_class.resolve(instance, round)

        # DC should be reduced by dc_reduction (3) when multiple tasks active
        result.task_results.each do |tr|
          expect(tr.dc).to be < (instance.current_difficulty || 10)
        end
      end

      it 'fails overall when one task fails' do
        call_count = 0
        allow(described_class).to receive(:roll_base_dice) do
          call_count += 1
          call_count == 1 ? mock_roll_result([8, 8]) : mock_roll_result([1, 1])
        end

        result = described_class.resolve(instance, round)

        expect(result.task_results.count(&:success)).to eq(1)
        expect(result.success).to be false
      end

      it 'succeeds when both tasks pass' do
        allow(described_class).to receive(:roll_base_dice).and_return(mock_roll_result([8, 8]))

        result = described_class.resolve(instance, round)

        expect(result.task_results.all?(&:success)).to be true
        expect(result.success).to be true
      end
    end

    context 'cross-task help constraint' do
      let!(:task2) do
        create(:activity_task, round: round, task_number: 2, description: 'Other task',
               dc_reduction: 3, min_participants: 1)
      end

      let!(:helper) do
        ci2
        create(:activity_participant,
               instance: instance, character: char2,
               effort_chosen: 'help', action_target: nil,
               task_chosen: task2.id,
               willpower_to_spend: 0)
      end

      let!(:target) do
        ci1
        create(:activity_participant,
               instance: instance, character: char1,
               action_chosen: action1.id, task_chosen: task1.id,
               willpower_to_spend: 0)
      end

      it 'ignores help from different task' do
        helper.update(action_target: target.id, action_chosen: 0)

        help_map = described_class.calculate_help_bonuses_with_tasks([helper, target])

        expect(help_map[target.id][:helper_count]).to eq(0)
      end

      it 'allows help from same task' do
        helper.update(action_target: target.id, action_chosen: 0, task_chosen: task1.id)

        help_map = described_class.calculate_help_bonuses_with_tasks([helper, target])

        expect(help_map[target.id][:helper_count]).to eq(1)
      end
    end
  end

  describe 'backward compatibility' do
    let(:room) { create(:room) }
    let(:activity) { create(:activity) }
    let(:round) { create(:activity_round, activity: activity, rtype: 'standard') }
    let(:instance) { create(:activity_instance, activity: activity, room: room, rounds_done: round.round_number - 1, branch: 0) }
    let(:action) { create(:activity_action, activity: activity) }
    let(:character) { create(:character) }
    let(:character_instance) { create(:character_instance, character: character, current_room: room) }

    let!(:participant) do
      character_instance
      create(:activity_participant,
             instance: instance, character: character,
             action_chosen: action.id, willpower_to_spend: 0)
    end

    # Helper to build a mock RollResult
    def mock_roll_result(dice, explosions: [])
      DiceRollService::RollResult.new(
        dice: dice,
        base_dice: dice[0..1],
        explosions: explosions,
        modifier: 0,
        total: dice.sum,
        count: 2,
        sides: 8,
        explode_on: 8
      )
    end

    before do
      allow_any_instance_of(ActivityAction).to receive(:stat_bonus_for).and_return(0)
    end

    it 'uses existing logic when round has no tasks' do
      allow(described_class).to receive(:roll_base_dice).and_return(mock_roll_result([5, 6]))

      result = described_class.resolve(instance, round)

      expect(result.task_results).to be_nil
      expect(result.success).not_to be_nil
    end
  end
end
