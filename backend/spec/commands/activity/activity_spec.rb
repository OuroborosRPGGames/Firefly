# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Activity::Activity do
  let(:universe) { create(:universe) }
  let(:world) { create(:world, universe: universe) }
  let(:area) { create(:area, world: world) }
  let(:location) { create(:location, zone: area) }
  let(:room) { create(:room, location: location, name: 'Activity Room') }
  let(:reality) { create(:reality) }

  let(:user) { create(:user) }
  let(:character) { create(:character, user: user, forename: 'Player', surname: 'One') }
  let(:character_instance) do
    create(:character_instance,
           character: character,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  # Second character for multiplayer tests
  let(:user2) { create(:user, email: 'player2@test.com') }
  let(:character2) { create(:character, user: user2, forename: 'Player', surname: 'Two') }
  let(:character_instance2) do
    create(:character_instance,
           character: character2,
           reality: reality,
           current_room: room,
           online: true,
           status: 'alive')
  end

  subject(:command) { described_class.new(character_instance) }

  # Prevent sync_pending_transition from calling running? on mocked instances
  before do
    allow(ActivityService).to receive(:process_pending_round_transition).and_return(:none)
  end

  def execute_command(args = nil)
    input = args.nil? ? 'activity' : "activity #{args}"
    command.execute(input)
  end

  describe 'command metadata' do
    it 'has correct command name' do
      expect(described_class.command_name).to eq('activity')
    end

    it 'has aliases' do
      alias_names = described_class.aliases.map { |a| a.is_a?(Hash) ? a[:name] : a }
      expect(alias_names).to include('act', 'mission', 'task')
    end

    it 'has events category' do
      expect(described_class.category).to eq(:events)
    end

    it 'requires character' do
      req_types = described_class.requirements.map { |r| r[:type] || r[:condition] }
      expect(req_types).to include(:character)
    end
  end

  describe 'subcommand: list' do
    context 'when no activities available' do
      before do
        allow(ActivityService).to receive(:available_activities).and_return([])
      end

      it 'returns message about no activities' do
        result = execute_command('list')

        expect(result[:success]).to be true
        expect(result[:message]).to include('No activities')
      end
    end

    context 'when activities are available' do
      let(:activity) do
        double('Activity',
               display_name: 'Test Heist',
               atype: 'mission',
               adesc: 'A thrilling heist')
      end

      before do
        allow(ActivityService).to receive(:available_activities).and_return([activity])
      end

      it 'lists available activities' do
        result = execute_command('list')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Test Heist')
        expect(result[:message]).to include('mission')
      end

      it 'includes activity descriptions' do
        result = execute_command('list')

        expect(result[:message]).to include('A thrilling heist')
      end
    end

    it 'works with ls alias' do
      allow(ActivityService).to receive(:available_activities).and_return([])

      result = execute_command('ls')

      expect(result[:success]).to be true
    end
  end

  describe 'subcommand: start' do
    let(:activity) do
      double('Activity',
             id: 1,
             display_name: 'Test Mission',
             aname: 'test_mission',
             atype: 'mission')
    end

    let(:activity_instance) do
      double('ActivityInstance',
             id: 1,
             activity: activity,
             current_round: nil)
    end

    context 'without name argument' do
      it 'returns usage error' do
        result = execute_command('start')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Usage')
      end
    end

    context 'when activity not found' do
      before do
        allow(ActivityService).to receive(:available_activities).and_return([])
      end

      it 'returns error' do
        result = execute_command('start NonExistent')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not found')
      end
    end

    context 'when another activity is running' do
      let(:existing_instance) do
        double('ActivityInstance',
               activity: double('Activity', display_name: 'Running Activity'))
      end

      before do
        allow(ActivityService).to receive(:available_activities).and_return([activity])
        allow(ActivityService).to receive(:running_activity).and_return(existing_instance)
      end

      it 'returns error about existing activity' do
        result = execute_command('start test')

        expect(result[:success]).to be false
        expect(result[:message]).to include('already an activity running')
      end
    end

    context 'when activity can be started' do
      before do
        allow(ActivityService).to receive(:available_activities).and_return([activity])
        allow(ActivityService).to receive(:running_activity).and_return(nil)
        allow(ActivityService).to receive(:start_activity).and_return(activity_instance)
      end

      it 'starts the activity' do
        expect(ActivityService).to receive(:start_activity).with(activity, hash_including(:room, :initiator))

        execute_command('start test')
      end

      it 'returns success message' do
        result = execute_command('start test')

        expect(result[:success]).to be true
        expect(result[:message]).to include('started')
        expect(result[:message]).to include('Test Mission')
      end

      it 'includes instance_id in data' do
        result = execute_command('start test')

        expect(result[:data][:instance_id]).to eq(1)
      end
    end

    context 'when service raises ActivityError' do
      before do
        allow(ActivityService).to receive(:available_activities).and_return([activity])
        allow(ActivityService).to receive(:running_activity).and_return(nil)
        allow(ActivityService).to receive(:start_activity).and_raise(ActivityService::ActivityError, 'Cannot start now')
      end

      it 'returns the service error as command error' do
        result = execute_command('start test')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Cannot start now')
      end
    end

    context 'finding activity by number' do
      let(:activity2) do
        double('Activity',
               id: 2,
               display_name: 'Second Activity',
               aname: 'second',
               atype: 'mission')
      end

      before do
        allow(ActivityService).to receive(:available_activities).and_return([activity, activity2])
        allow(ActivityService).to receive(:running_activity).and_return(nil)
        allow(ActivityService).to receive(:start_activity).and_return(activity_instance)
      end

      it 'starts activity by index' do
        expect(ActivityService).to receive(:start_activity).with(activity, anything)

        execute_command('start 1')
      end

      it 'starts second activity by index' do
        expect(ActivityService).to receive(:start_activity).with(activity2, anything)

        execute_command('start 2')
      end
    end
  end

  describe 'subcommand: join' do
    context 'when no activity running' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(nil)
      end

      it 'returns error' do
        result = execute_command('join')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no activity running')
      end
    end

    context 'when already participating' do
      let(:instance) do
        double('ActivityInstance',
               activity: double('Activity', display_name: 'Test Activity'),
               current_round: nil)
      end

      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(instance).to receive(:has_participant?).with(character_instance).and_return(true)
      end

      it 'returns error' do
        result = execute_command('join')

        expect(result[:success]).to be false
        expect(result[:message]).to include('already participating')
      end
    end

    context 'when can join' do
      let(:instance) do
        double('ActivityInstance',
               id: 1,
               activity: double('Activity', display_name: 'Test Activity'),
               current_round: nil)
      end

      let(:participant) { double('Participant') }

      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(instance).to receive(:has_participant?).and_return(false)
        allow(ActivityService).to receive(:add_participant).and_return(participant)
      end

      it 'adds participant' do
        expect(ActivityService).to receive(:add_participant).with(instance, character_instance)

        execute_command('join')
      end

      it 'returns success' do
        result = execute_command('join')

        expect(result[:success]).to be true
        expect(result[:message]).to include('joined')
      end
    end
  end

  describe 'subcommand: leave' do
    context 'when not participating' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(nil)
      end

      it 'returns error' do
        result = execute_command('leave')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not participating')
      end
    end

    context 'when participating' do
      let(:participant) { double('Participant') }
      let(:instance) { double('ActivityInstance') }

      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(ActivityService).to receive(:remove_participant)
      end

      it 'removes participant' do
        expect(ActivityService).to receive(:remove_participant).with(participant)

        execute_command('leave')
      end

      it 'returns success' do
        result = execute_command('leave')

        expect(result[:success]).to be true
        expect(result[:message]).to include('left')
      end
    end
  end

  describe 'subcommand: status' do
    context 'when no activity running' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(nil)
      end

      it 'returns error' do
        result = execute_command('status')

        expect(result[:success]).to be false
        expect(result[:message]).to include('no activity running')
      end
    end

    context 'when activity is running' do
      let(:activity) do
        double('Activity',
               display_name: 'Test Activity',
               atype: 'mission')
      end

      let(:participant) do
        double('Participant',
               character: character,
               status_text: 'active',
               available_willpower: 3)
      end

      let(:instance) do
        double('ActivityInstance',
               activity: activity,
               current_round: nil,
               current_round_number: 1,
               total_rounds: 5,
               status_text: 'in progress',
               participants: [participant])
      end

      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(nil)
      end

      it 'returns activity info' do
        result = execute_command('status')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Test Activity')
        expect(result[:message]).to include('mission')
      end

      it 'includes progress info' do
        result = execute_command('status')

        expect(result[:message]).to include('Round 1')
      end

      it 'lists participants' do
        result = execute_command('status')

        expect(result[:message]).to include('Participants')
        expect(result[:message]).to include('Player One')
      end
    end
  end

  describe 'subcommand: choose' do
    let(:round) do
      double('Round',
             branch?: false,
             available_actions: [action])
    end

    let(:action) do
      double('Action',
             id: 1,
             choice_text: 'Pick the lock')
    end

    let(:participant) do
      double('Participant',
             id: 1,
             instance: instance,
             active?: true)
    end

    let(:instance) do
      double('ActivityInstance',
             current_round: round)
    end

    context 'when not participating' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(nil)
      end

      it 'returns error' do
        result = execute_command('choose 1')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not participating')
      end
    end

    context 'when already chosen' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(participant).to receive(:active?).and_return(false)
      end

      it 'returns error' do
        result = execute_command('choose 1')

        expect(result[:success]).to be false
        expect(result[:message]).to include('already made your choice')
      end
    end

    context 'when can choose' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(ActivityService).to receive(:submit_choice)
      end

      it 'submits the choice' do
        expect(ActivityService).to receive(:submit_choice).with(
          participant,
          action_id: 1
        )

        execute_command('choose 1')
      end

      it 'returns success' do
        result = execute_command('choose 1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Pick the lock')
      end
    end

    context 'with invalid action' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(round).to receive(:available_actions).and_return([])
      end

      it 'returns error with available actions' do
        result = execute_command('choose 99')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Invalid action')
      end
    end

    context 'with missing action' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
      end

      it 'returns usage instead of auto-selecting the first action' do
        result = execute_command('choose')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Usage: activity choose')
      end
    end
  end

  describe 'subcommand: recover' do
    let(:participant) do
      double('Participant',
             update: true)
    end

    context 'when not participating' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(nil)
      end

      it 'returns error' do
        result = execute_command('recover')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not participating')
      end
    end

    context 'when participating' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(double('Instance'))
        allow(ActivityService).to receive(:participant_for).and_return(participant)
      end

      it 'updates participant to recover' do
        expect(participant).to receive(:update).with(hash_including(effort_chosen: 'recover'))

        execute_command('recover')
      end

      it 'returns success' do
        result = execute_command('recover')

        expect(result[:success]).to be true
        expect(result[:message]).to include('recovering')
      end
    end

    context 'during reflex rounds' do
      let(:round) { double('Round', reflex?: true, group_check?: false, round_type: 'reflex') }
      let(:instance) { double('Instance', current_round: round) }

      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
      end

      it 'blocks recover and tells player to ready' do
        result = execute_command('recover')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not available')
        expect(result[:message]).to include('activity ready')
      end
    end

    context 'during group_check rounds' do
      let(:round) { double('Round', reflex?: false, group_check?: true, round_type: 'group_check') }
      let(:instance) { double('Instance', current_round: round) }

      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
      end

      it 'blocks recover and tells player to ready' do
        result = execute_command('recover')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not available')
        expect(result[:message]).to include('activity ready')
      end
    end

    context 'during free_roll rounds' do
      let(:round) { double('Round', reflex?: false, group_check?: false, free_roll?: true, round_type: 'free_roll') }
      let(:instance) { double('Instance', current_round: round) }

      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
      end

      it 'blocks recover and tells player to ready' do
        result = execute_command('recover')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not available')
        expect(result[:message]).to include('activity ready')
      end
    end
  end

  describe 'subcommand: effort' do
    let(:participant) do
      double('Participant',
             available_willpower: 5,
             update: true)
    end

    context 'when not participating' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(nil)
      end

      it 'returns error' do
        result = execute_command('effort 2')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not participating')
      end
    end

    context 'with invalid effort level' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(double('Instance'))
        allow(ActivityService).to receive(:participant_for).and_return(participant)
      end

      it 'returns usage error' do
        result = execute_command('effort 5')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Usage')
      end
    end

    context 'with insufficient willpower' do
      before do
        allow(participant).to receive(:available_willpower).and_return(0)
        allow(ActivityService).to receive(:running_activity).and_return(double('Instance'))
        allow(ActivityService).to receive(:participant_for).and_return(participant)
      end

      it 'returns error for high effort' do
        result = execute_command('effort 4')

        expect(result[:success]).to be false
        expect(result[:message]).to include('willpower')
      end
    end

    context 'with valid willpower' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(double('Instance'))
        allow(ActivityService).to receive(:participant_for).and_return(participant)
      end

      it 'sets willpower to spend' do
        expect(participant).to receive(:update).with(willpower_to_spend: 2)

        execute_command('willpower 2')
      end

      it 'returns success' do
        result = execute_command('willpower 1')

        expect(result[:success]).to be true
        expect(result[:message]).to include('willpower')
      end
    end
  end

  describe 'subcommand: ready' do
    let(:participant) do
      double('Participant',
             has_chosen?: true,
             respond_to?: true,
             update: true,
             instance: instance)
    end

    let(:instance) { double('ActivityInstance', paused_for_combat?: false, current_round: nil) }

    context 'when not participating' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(nil)
      end

      it 'returns error' do
        result = execute_command('ready')

        expect(result[:success]).to be false
      end
    end

    context 'when no action chosen' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(participant).to receive(:has_chosen?).and_return(false)
      end

      it 'returns error' do
        result = execute_command('ready')

        expect(result[:success]).to be false
        expect(result[:message]).to include('choose an action first')
      end
    end

    context 'when ready' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(ActivityService).to receive(:check_all_ready)
      end

      it 'checks if all ready' do
        expect(ActivityService).to receive(:check_all_ready).with(instance)

        execute_command('ready')
      end

      it 'returns success' do
        result = execute_command('ready')

        expect(result[:success]).to be true
        expect(result[:message]).to include('ready')
      end
    end
  end

  describe 'subcommand: vote (branch rounds)' do
    let(:branch_choice) do
      { text: 'Take the left path', branch_to_round_id: 5 }
    end

    let(:round) do
      double('Round',
             branch?: true,
             expanded_branch_choices: [branch_choice])
    end

    let(:instance) do
      double('ActivityInstance',
             current_round: round)
    end

    let(:participant) do
      double('Participant',
             has_voted_branch?: false,
             instance: instance)
    end

    context 'when not a branch round' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(round).to receive(:branch?).and_return(false)
      end

      it 'returns error' do
        result = execute_command('vote 1')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not a branch round')
      end
    end

    context 'when already voted' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(participant).to receive(:has_voted_branch?).and_return(true)
      end

      it 'returns error' do
        result = execute_command('vote 1')

        expect(result[:success]).to be false
        expect(result[:message]).to include('already voted')
      end
    end

    context 'with no choice specified' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
      end

      it 'shows available choices' do
        result = execute_command('vote')

        expect(result[:success]).to be true
        expect(result[:message]).to include('Take the left path')
      end
    end
  end

  describe 'subcommand: heal (rest rounds)' do
    let(:round) { double('Round', rest?: true) }
    let(:instance) { double('ActivityInstance', current_round: round) }
    let(:participant) { double('Participant', instance: instance) }

    let(:heal_result) do
      double('HealResult',
             healed_amount: 2,
             new_hp: 8,
             max_hp: 10,
             permanent_damage: 0)
    end

    context 'when not a rest round' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(round).to receive(:rest?).and_return(false)
      end

      it 'returns error' do
        result = execute_command('heal')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not a rest round')
      end
    end

    context 'when at rest round' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(ActivityRestService).to receive(:heal_at_rest).and_return(heal_result)
      end

      it 'heals the participant' do
        result = execute_command('heal')

        expect(result[:success]).to be true
        expect(result[:message]).to include('recover 2 HP')
      end

      context 'when already at max HP' do
        let(:heal_result) do
          double('HealResult',
                 healed_amount: 0,
                 new_hp: 10,
                 max_hp: 10,
                 permanent_damage: 0)
        end

        it 'reports already at max' do
          result = execute_command('heal')

          expect(result[:success]).to be true
          expect(result[:message]).to include('maximum recoverable HP')
        end
      end
    end
  end

  describe 'subcommand: assess (free roll rounds)' do
    let(:round) { double('Round', free_roll?: true) }
    let(:instance) { double('ActivityInstance', current_round: round) }
    let(:participant) { double('Participant', instance: instance) }

    context 'when not a free roll round' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(round).to receive(:free_roll?).and_return(false)
      end

      it 'returns error' do
        result = execute_command('assess look around')

        expect(result[:success]).to be false
        expect(result[:message]).to include('does not support assess')
      end
    end

    context 'without description' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(ActivityFreeRollService).to receive(:enabled?).and_return(true)
      end

      it 'returns usage error' do
        result = execute_command('assess')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Usage')
      end
    end

    context 'when free roll disabled' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(ActivityFreeRollService).to receive(:enabled?).and_return(false)
      end

      it 'returns error' do
        result = execute_command('assess look for guards')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not enabled')
      end
    end

    context 'when free-roll service raises FreeRollError' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(ActivityFreeRollService).to receive(:enabled?).and_return(true)
        allow(ActivityFreeRollService).to receive(:assess!)
          .and_raise(ActivityFreeRollService::FreeRollError, 'LLM unavailable')
      end

      it 'returns the service error as a user-facing error' do
        result = execute_command('assess look for guards')

        expect(result[:success]).to be false
        expect(result[:message]).to include('LLM unavailable')
      end
    end

    context 'when free-roll service raises an unexpected error' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(ActivityFreeRollService).to receive(:enabled?).and_return(true)
        allow(ActivityFreeRollService).to receive(:assess!).and_raise(StandardError, 'boom')
      end

      it 'returns a generic retry-friendly error' do
        result = execute_command('assess look for guards')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Unable to assess right now')
      end
    end
  end

  describe 'subcommand: persuade' do
    let(:round) { double('Round', persuade?: true, persuade_npc_name: 'Guard') }
    let(:instance) { double('ActivityInstance', current_round: round) }
    let(:participant) { double('Participant', instance: instance) }

    context 'when not a persuade round' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(round).to receive(:persuade?).and_return(false)
      end

      it 'returns error' do
        result = execute_command('persuade')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not a persuade round')
      end
    end

    context 'when persuade disabled' do
      before do
        allow(ActivityService).to receive(:running_activity).and_return(instance)
        allow(ActivityService).to receive(:participant_for).and_return(participant)
        allow(ActivityPersuadeService).to receive(:enabled?).and_return(false)
      end

      it 'returns error' do
        result = execute_command('persuade')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not enabled')
      end
    end
  end

  describe 'default: show_usage' do
    it 'shows usage for unknown subcommand' do
      result = execute_command('unknown')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Activity Commands')
    end

    it 'shows usage when no subcommand given' do
      result = execute_command(nil)

      expect(result[:success]).to be true
      expect(result[:message]).to include('Activity Commands')
    end
  end

  # ===== EDGE CASE TESTS FOR ADDITIONAL COVERAGE =====

  describe 'subcommand: help' do
    let(:participant) { double('Participant', available_willpower: 2.0) }
    let(:instance) { double('ActivityInstance', id: 1, display_name: 'Test Mission') }

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
    end

    context 'when not participating' do
      before do
        allow(ActivityService).to receive(:participant_for).and_return(nil)
      end

      it 'returns error' do
        result = execute_command('help Bob')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not participating')
      end
    end

    context 'without player name' do
      it 'returns usage error' do
        result = execute_command('help')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Usage')
      end
    end

    context 'during a mandatory round' do
      let(:mandatory_round) do
        double('Round', mandatory_roll?: true, combat?: false, reflex?: true, group_check?: false, round_type: 'reflex')
      end
      let(:instance) { double('ActivityInstance', current_round: mandatory_round) }
      let(:participant) { double('Participant', available_willpower: 2.0, instance: instance) }

      it 'blocks help and tells player to ready' do
        result = execute_command('help Bob')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Help is not available')
        expect(result[:message]).to include('activity ready')
      end
    end
  end

  describe 'subcommand: continue' do
    let(:rest_round) { double('Round', rest?: true) }
    let(:instance) do
      double('ActivityInstance',
             id: 1,
             display_name: 'Test Mission',
             current_round: rest_round)
    end
    let(:participant) { double('Participant', voted_continue?: false, instance: instance) }

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
    end

    context 'when not participating' do
      before do
        allow(ActivityService).to receive(:participant_for).and_return(nil)
      end

      it 'returns error' do
        result = execute_command('continue')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not participating')
      end
    end

    context 'when not a rest round' do
      let(:action_round) { double('Round', rest?: false) }
      let(:action_instance) do
        double('ActivityInstance',
               id: 1,
               display_name: 'Test Mission',
               current_round: action_round)
      end

      before do
        allow(participant).to receive(:instance).and_return(action_instance)
      end

      it 'returns error' do
        result = execute_command('continue')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not a rest round')
      end
    end

    context 'when already voted' do
      before do
        allow(participant).to receive(:voted_continue?).and_return(true)
      end

      it 'returns error' do
        result = execute_command('continue')

        expect(result[:success]).to be false
        expect(result[:message]).to include('already voted')
      end
    end
  end

  describe 'subcommand: action' do
    let(:free_roll_round) { double('Round', free_roll?: true) }
    let(:instance) do
      double('ActivityInstance',
             id: 1,
             display_name: 'Test Mission',
             current_round: free_roll_round)
    end
    let(:participant) { double('Participant', instance: instance) }

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
      allow(ActivityFreeRollService).to receive(:enabled?).and_return(true)
    end

    context 'when not participating' do
      before do
        allow(ActivityService).to receive(:participant_for).and_return(nil)
      end

      it 'returns error' do
        result = execute_command('action pick the lock')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not participating')
      end
    end

    context 'when not a free roll round' do
      let(:action_round) { double('Round', free_roll?: false) }
      let(:action_instance) do
        double('ActivityInstance',
               id: 1,
               display_name: 'Test Mission',
               current_round: action_round)
      end

      before do
        allow(participant).to receive(:instance).and_return(action_instance)
      end

      it 'returns error' do
        result = execute_command('action pick the lock')

        expect(result[:success]).to be false
        expect(result[:message]).to include('does not support')
      end
    end

    context 'when free roll disabled' do
      before do
        allow(ActivityFreeRollService).to receive(:enabled?).and_return(false)
      end

      it 'returns error' do
        result = execute_command('action pick the lock')

        expect(result[:success]).to be false
        expect(result[:message]).to include('not enabled')
      end
    end

    context 'without action description' do
      it 'returns usage error' do
        result = execute_command('action')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Usage')
      end
    end

    context 'when free-roll service raises FreeRollError' do
      before do
        allow(ActivityFreeRollService).to receive(:take_action)
          .and_raise(ActivityFreeRollService::FreeRollError, 'Temporary GM outage')
      end

      it 'returns the service error as a user-facing error' do
        result = execute_command('action pick the lock')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Temporary GM outage')
      end
    end

    context 'when free-roll service raises an unexpected error' do
      before do
        allow(ActivityFreeRollService).to receive(:take_action).and_raise(StandardError, 'boom')
      end

      it 'returns a generic retry-friendly error' do
        result = execute_command('action pick the lock')

        expect(result[:success]).to be false
        expect(result[:message]).to include('Unable to resolve that action right now')
      end
    end
  end

  describe 'subcommand: accept/reject (delegation)' do
    before do
      # These delegate to observe command
      allow_any_instance_of(Commands::Activity::Activity).to receive(:delegate_to_observe).and_return(
        { success: true, message: 'Delegated to observe' }
      )
    end

    it 'handles accept subcommand' do
      expect_any_instance_of(Commands::Activity::Activity).to receive(:delegate_to_observe).with(['accept', 'Bob'])

      execute_command('accept Bob')
    end

    it 'handles reject subcommand' do
      expect_any_instance_of(Commands::Activity::Activity).to receive(:delegate_to_observe).with(['reject', 'Bob'])

      execute_command('reject Bob')
    end

    it 'handles deny as alias for reject' do
      expect_any_instance_of(Commands::Activity::Activity).to receive(:delegate_to_observe).with(['reject', 'Bob'])

      execute_command('deny Bob')
    end
  end

  describe 'subcommand aliases' do
    before do
      allow(ActivityService).to receive(:available_activities).and_return([])
    end

    it 'handles ls as alias for list' do
      result = execute_command('ls')

      expect(result[:success]).to be true
    end

    it 'handles begin as alias for start' do
      result = execute_command('begin Test')

      # Will fail to find activity but that's expected
      expect(result[:success]).to be false
    end

    it 'handles enter as alias for join' do
      allow(ActivityService).to receive(:running_activity).and_return(nil)

      result = execute_command('enter')

      expect(result[:success]).to be false
      expect(result[:message]).to include('no activity')
    end

    it 'handles quit as alias for leave' do
      allow(ActivityService).to receive(:running_activity).and_return(nil)

      result = execute_command('quit')

      expect(result[:success]).to be false
      expect(result[:message]).to include('not participating')
    end

    it 'handles stat as alias for status' do
      allow(ActivityService).to receive(:running_activity).and_return(nil)

      result = execute_command('stat')

      expect(result[:success]).to be false
    end

    it 'handles pick as alias for choose' do
      allow(ActivityService).to receive(:participant_for).and_return(nil)

      result = execute_command('pick 1')

      expect(result[:success]).to be false
      expect(result[:message]).to include('not participating')
    end

    it 'handles rest as alias for recover' do
      allow(ActivityService).to receive(:participant_for).and_return(nil)

      result = execute_command('rest')

      expect(result[:success]).to be false
    end

    it 'handles wp as alias for effort' do
      allow(ActivityService).to receive(:participant_for).and_return(nil)

      result = execute_command('wp 1')

      expect(result[:success]).to be false
    end

    it 'handles done as alias for ready' do
      allow(ActivityService).to receive(:participant_for).and_return(nil)

      result = execute_command('done')

      expect(result[:success]).to be false
    end
  end

  describe 'vote with valid choice' do
    let(:expanded_choices) { [{ text: 'Option A', branch_to_round_id: 1 }, { text: 'Option B', branch_to_round_id: 2 }] }
    let(:round) do
      double('Round',
             id: 1,
             round_type: 'branch',
             branch?: true,
             expanded_branch_choices: expanded_choices)
    end
    let(:active_participants) { double('Participants', count: 2) }
    let(:instance) do
      double('ActivityInstance',
             id: 1,
             display_name: 'Test Mission',
             current_round: round,
             post_resolution_hold_pending?: false,
             post_resolution_hold_remaining_seconds: 15,
             branch_votes: { 1 => 1 },
             active_participants: active_participants)
    end
    let(:participant) do
      double('Participant',
             has_voted_branch?: false,
             update: true,
             instance: instance)
    end

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
      allow(ActivityBranchService).to receive(:submit_vote)
      allow(ActivityBranchService).to receive(:voting_complete?).and_return(false)
    end

    it 'records vote for valid choice' do
      expect(ActivityBranchService).to receive(:submit_vote).with(participant, 1)

      execute_command('vote 1')
    end

    it 'returns success message' do
      result = execute_command('vote 1')

      expect(result[:success]).to be true
      expect(result[:message]).to include('voted')
    end

    it 'queues delayed transition when voting completes' do
      resolution = double('BranchResult', chosen_branch_text: 'Option A')
      allow(ActivityBranchService).to receive(:voting_complete?).and_return(true)
      allow(ActivityBranchService).to receive(:resolve).and_return(resolution)
      allow(ActivityService).to receive(:queue_post_resolution_transition).and_return(Time.now + 15)

      expect(ActivityService).to receive(:queue_post_resolution_transition).with(instance, round)

      result = execute_command('vote 1')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Continuing in')
    end
  end

  describe 'heal at rest round success' do
    let(:rest_round) { double('Round', rest?: true) }
    let(:instance) do
      double('ActivityInstance',
             id: 1,
             display_name: 'Test Mission',
             current_round: rest_round)
    end
    let(:participant) do
      double('Participant',
             current_hp: 4,
             max_hp: 6,
             update: true,
             instance: instance)
    end
    let(:heal_result) do
      double('HealResult',
             healed_amount: 1,
             new_hp: 5,
             max_hp: 6,
             permanent_damage: 0)
    end

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
      allow(ActivityRestService).to receive(:heal_at_rest).and_return(heal_result)
    end

    it 'heals participant' do
      expect(ActivityRestService).to receive(:heal_at_rest).with(participant)

      execute_command('heal')
    end

    it 'returns success message' do
      result = execute_command('heal')

      expect(result[:success]).to be true
      expect(result[:message]).to include('HP')
    end
  end

  # ===== ADDITIONAL EDGE CASE TESTS =====

  describe 'start activity by number' do
    let(:activities) { [double('Activity', id: 1, display_name: 'Test Mission', adesc: 'Do things')] }
    let(:instance) { double('ActivityInstance', id: 1, current_round: nil) }

    before do
      allow(ActivityService).to receive(:available_activities).and_return(activities)
      allow(ActivityService).to receive(:running_activity).and_return(nil)
      allow(ActivityService).to receive(:start_activity).and_return(instance)
    end

    it 'starts activity when given a valid number' do
      expect(ActivityService).to receive(:start_activity).with(activities.first, hash_including(:room, :initiator))

      execute_command('start 1')
    end
  end

  describe 'vote branch already voted' do
    let(:branch_round) { double('Round', branch?: true, expanded_branch_choices: []) }
    let(:instance) { double('ActivityInstance', id: 1, current_round: branch_round) }
    let(:participant) do
      double('Participant',
             instance: instance,
             has_voted_branch?: true)
    end

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
    end

    it 'returns error for already voted' do
      result = execute_command('vote 1')

      expect(result[:success]).to be false
      expect(result[:message]).to include('already voted')
    end
  end

  describe 'vote branch with invalid choice' do
    let(:choices) do
      [{ text: 'Option A', description: 'First choice' }]
    end
    let(:branch_round) { double('Round', branch?: true, expanded_branch_choices: choices) }
    let(:instance) { double('ActivityInstance', id: 1, current_round: branch_round) }
    let(:participant) do
      double('Participant',
             instance: instance,
             has_voted_branch?: false)
    end

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
    end

    it 'returns error for out of range choice' do
      result = execute_command('vote 99')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Invalid choice')
    end

    it 'returns error for zero choice' do
      result = execute_command('vote 0')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Invalid choice')
    end
  end

  describe 'heal at rest with no healing' do
    let(:rest_round) { double('Round', rest?: true) }
    let(:instance) do
      double('ActivityInstance',
             id: 1,
             current_round: rest_round)
    end
    let(:participant) do
      double('Participant',
             instance: instance)
    end
    let(:heal_result) do
      double('HealResult',
             healed_amount: 0,
             new_hp: 6,
             max_hp: 6,
             permanent_damage: 0)
    end

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
      allow(ActivityRestService).to receive(:heal_at_rest).and_return(heal_result)
    end

    it 'returns message about already at max HP' do
      result = execute_command('heal')

      expect(result[:success]).to be true
      expect(result[:message]).to include('already at maximum')
    end
  end

  describe 'heal at rest with permanent damage' do
    let(:rest_round) { double('Round', rest?: true) }
    let(:instance) do
      double('ActivityInstance',
             id: 1,
             current_round: rest_round)
    end
    let(:participant) do
      double('Participant',
             instance: instance)
    end
    let(:heal_result) do
      double('HealResult',
             healed_amount: 1,
             new_hp: 5,
             max_hp: 6,
             permanent_damage: 1)
    end

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
      allow(ActivityRestService).to receive(:heal_at_rest).and_return(heal_result)
    end

    it 'shows permanent damage message' do
      result = execute_command('heal')

      expect(result[:success]).to be true
      expect(result[:message]).to include('permanent')
    end
  end

  describe 'vote continue already voted' do
    let(:rest_round) { double('Round', rest?: true) }
    let(:instance) { double('ActivityInstance', id: 1, current_round: rest_round) }
    let(:participant) do
      double('Participant',
             instance: instance,
             voted_continue?: true)
    end

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
    end

    it 'returns error for already voted' do
      result = execute_command('continue')

      expect(result[:success]).to be false
      expect(result[:message]).to include('already voted')
    end
  end

  describe 'vote continue when group is ready' do
    let(:rest_round) { double('Round', rest?: true, round_type: 'rest') }
    let(:instance) do
      double('ActivityInstance',
             id: 1,
             current_round: rest_round,
             reset_continue_votes!: true,
             post_resolution_hold_pending?: false,
             post_resolution_hold_remaining_seconds: 15)
    end
    let(:participant) do
      double('Participant',
             instance: instance,
             voted_continue?: false)
    end

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
      allow(ActivityRestService).to receive(:vote_to_continue).and_return(true)
      allow(ActivityRestService).to receive(:ready_to_continue?).and_return(true)
      allow(ActivityService).to receive(:queue_post_resolution_transition).and_return(Time.now + 15)
      allow(ActivityService).to receive(:advance_round).and_return(true)
    end

    it 'queues delayed transition when ready' do
      expect(ActivityService).to receive(:queue_post_resolution_transition).with(instance, rest_round)

      execute_command('continue')
    end

    it 'shows ready message' do
      result = execute_command('continue')

      expect(result[:success]).to be true
      expect(result[:message]).to include('ready')
      expect(result[:message]).to include('Continuing in')
    end
  end

  describe 'action queues delayed transition when round completes' do
    let(:free_roll_round) { double('Round', free_roll?: true, round_type: 'free_roll') }
    let(:instance) do
      double('ActivityInstance',
             id: 1,
             current_round: free_roll_round,
             post_resolution_hold_pending?: false,
             post_resolution_hold_remaining_seconds: 30)
    end
    let(:participant) { double('Participant', instance: instance) }
    let(:action_result) do
      double('ActionResult',
             stat_names: ['Dexterity'],
             roll_total: 14,
             dc: 12,
             success: true,
             narration: 'You make progress.')
    end

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
      allow(ActivityFreeRollService).to receive(:enabled?).and_return(true)
      allow(ActivityFreeRollService).to receive(:take_action).and_return(action_result)
      allow(ActivityFreeRollService).to receive(:check_round_complete).and_return({ complete: true, success: true })
      allow(ActivityService).to receive(:queue_post_resolution_transition).and_return(Time.now + 30)
      allow(ActivityService).to receive(:finalize_observer_effects)
      allow(ActivityService).to receive(:advance_round)
    end

    it 'queues transition instead of immediate advance' do
      expect(ActivityService).to receive(:queue_post_resolution_transition).with(instance, free_roll_round)
      expect(ActivityService).not_to receive(:advance_round)

      result = execute_command('action pick the lock')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Round complete')
      expect(result[:message]).to include('Continuing in')
    end
  end

  describe 'persuade queues delayed transition on success' do
    let(:round) { double('Round', persuade?: true, round_type: 'persuade', persuade_npc_name: 'Guard') }
    let(:instance) do
      double('ActivityInstance',
             id: 1,
             current_round: round,
             post_resolution_hold_pending?: false,
             post_resolution_hold_remaining_seconds: 30)
    end
    let(:participant) { double('Participant', instance: instance) }
    let(:attempt_result) do
      double('AttemptResult',
             success: true,
             roll_total: 16,
             dc: 12,
             npc_response: 'Fine, you may pass.',
             attempts_made: 1)
    end

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
      allow(ActivityPersuadeService).to receive(:enabled?).and_return(true)
      allow(ActivityPersuadeService).to receive(:attempt_persuasion).and_return(attempt_result)
      allow(ActivityService).to receive(:queue_post_resolution_transition).and_return(Time.now + 30)
      allow(ActivityService).to receive(:finalize_observer_effects)
      allow(ActivityService).to receive(:advance_round)
    end

    it 'queues transition instead of immediate advance' do
      expect(ActivityService).to receive(:queue_post_resolution_transition).with(instance, round)
      expect(ActivityService).not_to receive(:advance_round)

      result = execute_command('persuade')

      expect(result[:success]).to be true
      expect(result[:message]).to include('SUCCESS!')
      expect(result[:message]).to include('Continuing in')
    end
  end

  describe 'vote continue when not ready yet' do
    let(:rest_round) { double('Round', rest?: true) }
    let(:instance) { double('ActivityInstance', id: 1, current_round: rest_round) }
    let(:participant) do
      double('Participant',
             instance: instance,
             voted_continue?: false)
    end
    let(:rest_status) { { continue_votes: 1, total_participants: 3 } }

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
      allow(ActivityRestService).to receive(:vote_to_continue).and_return(true)
      allow(ActivityRestService).to receive(:ready_to_continue?).and_return(false)
      allow(ActivityRestService).to receive(:rest_status).and_return(rest_status)
    end

    it 'shows vote count' do
      result = execute_command('continue')

      expect(result[:success]).to be true
      expect(result[:message]).to include('1/3')
    end
  end

  describe 'ready without choosing action first' do
    let(:instance) { double('ActivityInstance', id: 1, paused_for_combat?: false, current_round: nil) }
    let(:participant) do
      double('Participant',
             instance: instance,
             has_chosen?: false)
    end

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
    end

    it 'returns error about choosing first' do
      result = execute_command('ready')

      expect(result[:success]).to be false
      expect(result[:message]).to include('choose an action first')
    end
  end

  describe 'list with activity descriptions' do
    let(:activities) do
      [
        double('Activity', id: 1, display_name: 'Heist', atype: 'mission', adesc: 'Rob the bank'),
        double('Activity', id: 2, display_name: 'Guard Duty', atype: 'task', adesc: nil)
      ]
    end

    before do
      allow(ActivityService).to receive(:available_activities).and_return(activities)
    end

    it 'shows descriptions for activities that have them' do
      result = execute_command('list')

      expect(result[:success]).to be true
      expect(result[:message]).to include('Rob the bank')
      expect(result[:message]).to include('[task]')
    end
  end

  describe 'assess with no text' do
    let(:free_roll_round) { double('Round', free_roll?: true) }
    let(:instance) { double('ActivityInstance', id: 1, current_round: free_roll_round) }
    let(:participant) { double('Participant', instance: instance) }

    before do
      allow(ActivityFreeRollService).to receive(:enabled?).and_return(true)
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
    end

    it 'returns usage error' do
      result = execute_command('assess')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Usage')
    end
  end

  describe 'action with no text' do
    let(:free_roll_round) { double('Round', free_roll?: true) }
    let(:instance) { double('ActivityInstance', id: 1, current_round: free_roll_round) }
    let(:participant) { double('Participant', instance: instance) }

    before do
      allow(ActivityFreeRollService).to receive(:enabled?).and_return(true)
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
    end

    it 'returns usage error' do
      result = execute_command('action')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Usage')
    end
  end

  describe 'persuade when not in activity' do
    before do
      allow(ActivityService).to receive(:running_activity).and_return(nil)
    end

    it 'returns error about not participating' do
      result = execute_command('persuade')

      expect(result[:success]).to be false
      expect(result[:message]).to include('not participating')
    end
  end

  describe 'effort with invalid value' do
    let(:standard_round) { double('Round', standard?: true, free_roll?: false) }
    let(:instance) { double('ActivityInstance', id: 1, current_round: standard_round) }
    let(:participant) do
      double('Participant',
             instance: instance,
             current_willpower: 3)
    end

    before do
      allow(ActivityService).to receive(:running_activity).and_return(instance)
      allow(ActivityService).to receive(:participant_for).and_return(participant)
    end

    it 'returns error for non-numeric value' do
      result = execute_command('effort abc')

      expect(result[:success]).to be false
      expect(result[:message]).to include('Usage')
    end
  end
end
