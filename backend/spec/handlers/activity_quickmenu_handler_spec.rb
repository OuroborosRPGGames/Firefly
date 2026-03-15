# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityQuickmenuHandler do
  let(:room) { create(:room) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }

  # Mock activity models - using double to avoid verifying methods
  let(:activity_action) do
    double('ActivityAction', id: 1, choice_text: 'Test Action', skill_ids: [], risk_dice: nil, risk_sides_value: nil,
           :[] => nil)
  end

  let(:activity_round) do
    double('ActivityRound', available_actions: [activity_action], has_tasks?: false, tasks: [],
           persuade?: false, free_roll?: false, rest?: false, no_roll?: false,
           branch?: false, reflex?: false, group_check?: false, combat?: false,
           mandatory_roll?: false, round_type: 'standard')
  end

  let(:activity_instance) do
    double(
      'ActivityInstance',
      id: 1,
      current_round: activity_round,
      all_ready?: false,
      input_timed_out?: false
    )
  end

  let(:participant) do
    double(
      'ActivityParticipant',
      id: 1,
      instance: activity_instance,
      character: character,
      has_chosen?: false,
      action_chosen: nil,
      effort_chosen: nil,
      risk_chosen: nil,
      action_target: nil,
      chosen_when: nil,
      available_willpower: 2,
      chosen_action: nil,
      task_chosen: nil,
      :[] => nil
    )
  end

  before do
    allow(participant).to receive(:reload).and_return(participant)
    allow(participant).to receive(:respond_to?).and_return(true)
    allow(activity_instance).to receive(:reload).and_return(activity_instance)
    allow(activity_instance).to receive(:active_participants).and_return([participant])
    allow(ActivityService).to receive(:broadcast_participant_choice)
  end

  describe '.show_menu' do
    it 'creates handler and shows current menu' do
      result = described_class.show_menu(participant, character_instance)

      expect(result[:type]).to eq(:quickmenu)
    end
  end

  describe '#show_current_menu' do
    subject(:handler) { described_class.new(participant, character_instance) }

    context 'when on main menu' do
      it 'shows activity actions menu with actions, help, and recover' do
        result = handler.show_current_menu

        expect(result[:prompt]).to eq('Activity Actions:')
        keys = result[:options].map { |o| o[:key] }
        expect(keys).to include('action_1', 'help', 'recover')
      end

      it 'labels help as Assist someone' do
        result = handler.show_current_menu

        help_opt = result[:options].find { |o| o[:key] == 'help' }
        expect(help_opt[:label]).to eq('Assist someone')
      end

      it 'labels recover as Skip / Recover' do
        result = handler.show_current_menu

        recover_opt = result[:options].find { |o| o[:key] == 'recover' }
        expect(recover_opt[:label]).to eq('Skip / Recover')
      end
    end

    context 'when round is persuade' do
      before do
        allow(activity_round).to receive(:persuade?).and_return(true)
      end

      it 'returns no options (non-quickmenu round type)' do
        result = handler.show_current_menu

        expect(result[:options]).to be_empty
      end
    end

    context 'when round is reflex' do
      before do
        allow(activity_round).to receive(:reflex?).and_return(true)
      end

      it 'does not include recover or help options' do
        result = handler.show_current_menu

        keys = result[:options].map { |o| o[:key] }
        expect(keys).not_to include('recover')
        expect(keys).not_to include('help')
      end
    end
  end

  describe 'main menu choices' do
    subject(:handler) { described_class.new(participant, character_instance) }

    context 'when selecting an action' do
      before do
        allow(ActivityAction).to receive(:[]).with(1).and_return(activity_action)
        allow(participant).to receive(:update)
      end

      it 'updates participant with chosen action' do
        handler.handle_response('action_1')

        expect(participant).to have_received(:update).with(hash_including(action_chosen: 1))
      end
    end

    context 'when selecting an action with risk dice' do
      let(:risky_action) do
        double('ActivityAction', id: 2, choice_text: 'Risky', skill_ids: [], risk_dice: true, risk_sides_value: 6,
               :[] => nil)
      end

      before do
        allow(ActivityAction).to receive(:[]).with(2).and_return(risky_action)
        allow(participant).to receive(:update)
      end

      it 'auto-sets risk_chosen to yes' do
        handler.handle_response('action_2')

        expect(participant).to have_received(:update).with(hash_including(action_chosen: 2, risk_chosen: 'yes'))
      end
    end

    context 'when selecting help' do
      before do
        allow(participant).to receive(:update)
      end

      it 'sets effort to help' do
        handler.handle_response('help')

        expect(participant).to have_received(:update).with(effort_chosen: 'help')
      end
    end

    context 'when selecting recover' do
      before do
        allow(participant).to receive(:update)
      end

      it 'sets recover state' do
        handler.handle_response('recover')

        expect(participant).to have_received(:update).with(hash_including(effort_chosen: 'recover'))
      end
    end

    context 'when selecting recover in a mandatory round' do
      before do
        allow(participant).to receive(:update)
        allow(activity_round).to receive(:reflex?).and_return(true)
      end

      it 'ignores recover selection' do
        handler.handle_response('recover')

        expect(participant).not_to have_received(:update).with(hash_including(effort_chosen: 'recover'))
      end
    end

    context 'when selecting recover in a free-roll round' do
      before do
        allow(participant).to receive(:update)
        allow(activity_round).to receive(:free_roll?).and_return(true)
      end

      it 'ignores recover selection' do
        handler.handle_response('recover')

        expect(participant).not_to have_received(:update).with(hash_including(effort_chosen: 'recover'))
      end
    end
  end

  describe 'target selection' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:other_participant) do
      double(
        'ActivityParticipant',
        id: 2,
        character: double('Character', full_name: 'Other Character'),
        chosen_action: nil
      )
    end

    before do
      allow(participant).to receive(:effort_chosen).and_return('help')
      allow(participant).to receive(:action_target).and_return(nil)
      allow(activity_instance).to receive(:active_participants).and_return([participant, other_participant])
      allow(activity_instance).to receive(:participants_dataset).and_return(
        double(where: double(first: other_participant))
      )
    end

    it 'shows other participants as targets' do
      result = handler.show_current_menu

      expect(result[:prompt]).to eq('Choose who to help:')
      expect(result[:options].map { |o| o[:label] }).to include('Other Character')
    end

    context 'when selecting a target' do
      before do
        allow(participant).to receive(:update)
      end

      it 'updates participant with target' do
        handler.handle_response('2')

        expect(participant).to have_received(:update).with(hash_including(action_target: 2))
      end
    end
  end

  describe 'willpower selection' do
    subject(:handler) { described_class.new(participant, character_instance) }

    before do
      allow(participant).to receive(:action_chosen).and_return(1)
      allow(participant).to receive(:effort_chosen).and_return(nil)
      allow(participant).to receive(:willpower_to_spend).and_return(nil)
    end

    it 'shows willpower options' do
      result = handler.show_current_menu

      expect(result[:prompt]).to eq('Spend willpower dice?')
      expect(result[:options].map { |o| o[:label] }).to include('None', '+1d8 (1 WP)', '+2d8 (2 WP)')
    end

    it 'disables expensive options when low willpower' do
      allow(participant).to receive(:available_willpower).and_return(0)

      result = handler.show_current_menu
      max_option = result[:options].find { |o| o[:label] == '+2d8 (2 WP)' }

      expect(max_option[:disabled]).to be true
    end

    context 'when selecting willpower amount' do
      before do
        allow(participant).to receive(:update)
      end

      it 'updates participant with willpower to spend' do
        handler.handle_response('2')

        expect(participant).to have_received(:update).with(willpower_to_spend: 2)
      end
    end
  end

  describe 'helper methods' do
    subject(:handler) { described_class.new(participant, character_instance) }

    describe '#action_description' do
      it 'shows standard action for empty skills' do
        desc = handler.send(:action_description, activity_action)

        expect(desc).to eq('Standard action')
      end

      context 'when action has skills' do
        let(:stat) { double('Stat', abbreviation: 'STR') }
        let(:activity_action) do
          double('ActivityAction', id: 1, choice_text: 'Strong Action', skill_ids: [1], risk_dice: nil,
                 risk_sides_value: nil, :[] => nil)
        end

        before do
          allow(Stat).to receive(:find).with(id: 1).and_return(stat)
        end

        it 'shows skill abbreviations' do
          desc = handler.send(:action_description, activity_action)

          expect(desc).to include('STR')
        end
      end

      context 'when action has risk dice' do
        let(:activity_action) do
          double('ActivityAction', id: 1, choice_text: 'Risky', skill_ids: [], risk_dice: true,
                 risk_sides_value: 6, :[] => nil)
        end

        it 'shows risk indicator' do
          desc = handler.send(:action_description, activity_action)

          expect(desc).to include('Risk d6')
        end
      end
    end

    describe '#help_target_description' do
      it 'shows still deciding when no action chosen' do
        target = double('ActivityParticipant', chosen_action: nil)

        desc = handler.send(:help_target_description, target)

        expect(desc).to eq('Still deciding...')
      end

      it 'shows chosen action when available' do
        action = double('ActivityAction', choice_text: 'Test Action')
        target = double('ActivityParticipant', chosen_action: action)

        desc = handler.send(:help_target_description, target)

        expect(desc).to eq('Choosing: Test Action')
      end
    end
  end

  # ============================================
  # Task-based flow
  # ============================================

  describe 'task-based menu' do
    subject(:handler) { described_class.new(participant, character_instance) }

    let(:task1) do
      double('ActivityTask', id: 10, task_number: 1, description: 'Break door',
             stat_set_a: [1], stat_set_b: nil, secondary?: false, stat_set_b?: false,
             actions: [activity_action], stat_set_for: [1])
    end

    let(:task_round) do
      double('ActivityRound', available_actions: [activity_action], has_tasks?: true,
             tasks: [task1], persuade?: false, free_roll?: false, rest?: false,
             no_roll?: false, branch?: false, reflex?: false, group_check?: false, combat?: false,
             mandatory_roll?: false, round_type: 'standard')
    end

    let(:task_instance) do
      double('ActivityInstance', id: 1, current_round: task_round,
             all_ready?: false, input_timed_out?: false)
    end

    let(:task_participant) do
      double('ActivityParticipant',
             id: 1, instance: task_instance, character: character,
             has_chosen?: false, action_chosen: nil, effort_chosen: nil,
             risk_chosen: nil, action_target: nil, chosen_when: nil,
             available_willpower: 2, chosen_action: nil, task_chosen: nil,
             :[] => nil)
    end

    before do
      allow(task_participant).to receive(:reload).and_return(task_participant)
      allow(task_participant).to receive(:respond_to?).and_return(true)
      allow(task_instance).to receive(:reload).and_return(task_instance)
      allow(task_instance).to receive(:active_participants).and_return([task_participant])
      allow(ActivityService).to receive(:broadcast_participant_choice)
      allow(Stat).to receive(:find).and_return(double('Stat', abbreviation: 'STR'))
    end

    it 'shows actions grouped under task sections' do
      handler = described_class.new(task_participant, character_instance)
      result = handler.show_current_menu

      # Actions should have section field matching task description
      sectioned = result[:options].select { |o| o[:section] == 'Break door' }
      expect(sectioned).not_to be_empty

      # Should include the action and a per-task help option
      keys = sectioned.map { |o| o[:key] }
      expect(keys).to include('action_1', 'help_task_10')
    end

    it 'includes Skip / Recover as the last option without a section' do
      handler = described_class.new(task_participant, character_instance)
      result = handler.show_current_menu

      last_non_done = result[:options].reject { |o| o[:key] == 'done' }.last
      expect(last_non_done[:key]).to eq('recover')
      expect(last_non_done[:section]).to be_nil
    end

    context 'when selecting a per-task help option' do
      before do
        allow(task_participant).to receive(:update)
      end

      it 'sets effort to help with task_chosen' do
        handler = described_class.new(task_participant, character_instance)
        handler.handle_response('help_task_10')

        expect(task_participant).to have_received(:update).with(effort_chosen: 'help', task_chosen: 10)
      end
    end

    context 'when task round is mandatory' do
      before do
        allow(task_round).to receive(:mandatory_roll?).and_return(true)
        allow(task_round).to receive(:reflex?).and_return(true)
        allow(task_participant).to receive(:update)
      end

      it 'does not include per-task help options' do
        handler = described_class.new(task_participant, character_instance)
        result = handler.show_current_menu

        keys = result[:options].map { |o| o[:key] }
        expect(keys).not_to include('help_task_10')
      end

      it 'ignores per-task help selection' do
        handler = described_class.new(task_participant, character_instance)
        handler.handle_response('help_task_10')

        expect(task_participant).not_to have_received(:update).with(effort_chosen: 'help', task_chosen: 10)
      end
    end

    context 'when selecting an action under a task' do
      before do
        allow(ActivityAction).to receive(:[]).with(1).and_return(activity_action)
        allow(task_participant).to receive(:update)
      end

      it 'sets action_chosen directly from main menu' do
        handler = described_class.new(task_participant, character_instance)
        handler.handle_response('action_1')

        expect(task_participant).to have_received(:update).with(hash_including(action_chosen: 1))
      end
    end
  end

  describe 'round resolution check' do
    subject(:handler) { described_class.new(participant, character_instance) }

    context 'when all participants ready' do
      before do
        allow(participant).to receive(:has_chosen?).and_return(true)
        allow(participant).to receive(:action_chosen).and_return(1)
        allow(participant).to receive(:effort_chosen).and_return(nil)
        allow(participant).to receive(:willpower_to_spend).and_return(0)
        # Raw column access used by action_complete?
        allow(participant).to receive(:[]) do |key|
          case key
          when :willpower_to_spend then 0
          when :task_chosen then nil
          else nil
          end
        end
        allow(participant).to receive(:update)
        allow(activity_instance).to receive(:all_ready?).and_return(true)
        allow(activity_instance).to receive(:running?).and_return(true)
        allow(activity_instance).to receive(:post_resolution_hold_pending?).and_return(false)
        allow(ActivityService).to receive(:resolve_round)
      end

      it 'triggers round resolution after done' do
        handler.handle_response('done')

        expect(ActivityService).to have_received(:resolve_round).with(activity_instance)
      end
    end
  end
end
