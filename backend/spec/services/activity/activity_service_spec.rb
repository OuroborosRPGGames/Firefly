# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityService do
  let(:user) { create(:user) }
  let(:character) { create(:character, user: user) }
  let(:room) { create(:room) }
  let(:character_instance) do
    create(:character_instance, character: character, current_room: room, online: true)
  end
  let(:activity) { create(:activity, is_public: true, team_name_one: 'Red', team_name_two: 'Blue') }

  before do
    # Mock BroadcastService by default to avoid cluttering tests
    allow(BroadcastService).to receive(:to_room)
    allow(TriggerService).to receive(:check_mission_triggers)
  end

  # ============================================
  # Error Classes
  # ============================================
  describe 'error classes' do
    it 'defines ActivityError as a StandardError subclass' do
      expect(described_class::ActivityError).to be < StandardError
    end

    it 'defines NotAllowedError as an ActivityError subclass' do
      expect(described_class::NotAllowedError).to be < described_class::ActivityError
    end

    it 'defines NotFoundError as an ActivityError subclass' do
      expect(described_class::NotFoundError).to be < described_class::ActivityError
    end

    it 'defines InvalidStateError as an ActivityError subclass' do
      expect(described_class::InvalidStateError).to be < described_class::ActivityError
    end

    it 'allows catching all activity errors with ActivityError' do
      expect {
        raise described_class::NotFoundError, 'Test'
      }.to raise_error(described_class::ActivityError)
    end
  end

  # ============================================
  # Constants
  # ============================================
  describe 'INPUT_TIMEOUT_SECONDS constant' do
    it 'is defined from GameConfig' do
      expect(described_class::INPUT_TIMEOUT_SECONDS).to be_a(Integer)
    end

    it 'is a positive number' do
      expect(described_class::INPUT_TIMEOUT_SECONDS).to be > 0
    end
  end

  # ============================================
  # .start_activity
  # ============================================
  describe '.start_activity' do
    it 'raises NotFoundError when activity is nil' do
      expect {
        described_class.start_activity(nil, room: room, initiator: character_instance)
      }.to raise_error(described_class::NotFoundError, 'Activity not found')
    end

    it 'raises InvalidStateError when activity is already running in room' do
      # Create an existing running instance
      create(:activity_instance, activity: activity, room: room, running: true)

      expect {
        described_class.start_activity(activity, room: room, initiator: character_instance)
      }.to raise_error(described_class::InvalidStateError, 'Activity is already running in this room')
    end

    it 'raises NotAllowedError when activity is anchored to a different room' do
      other_room = create(:room)
      locked_activity = create(:activity, location: other_room.id, launch_mode: nil)

      expect {
        described_class.start_activity(locked_activity, room: room, initiator: character_instance)
      }.to raise_error(described_class::NotAllowedError)
    end

    it 'creates a new activity instance' do
      instance = described_class.start_activity(activity, room: room, initiator: character_instance)

      expect(instance).to be_a(ActivityInstance)
      expect(instance.activity_id).to eq(activity.id)
      expect(instance.room_id).to eq(room.id)
      expect(instance.running).to be true
    end

    it 'sets up instance with correct initial values' do
      instance = described_class.start_activity(activity, room: room, initiator: character_instance)

      expect(instance.setup_stage).to eq(2)
      expect(instance.rounds_done).to eq(0)
      expect(instance.branch).to eq(0)
      expect(instance.running).to be true
    end

    it 'copies team names from activity' do
      instance = described_class.start_activity(activity, room: room, initiator: character_instance)

      expect(instance.team_name_one).to eq('Red')
      expect(instance.team_name_two).to eq('Blue')
    end

    it 'associates event when provided' do
      event = create(:event, room: room)
      instance = described_class.start_activity(activity, room: room, initiator: character_instance, event: event)

      expect(instance.event_id).to eq(event.id)
    end

    it 'adds initiator as participant' do
      instance = described_class.start_activity(activity, room: room, initiator: character_instance)

      participant = instance.participants.first
      expect(participant).not_to be_nil
      expect(participant.char_id).to eq(character.id)
    end

    it 'broadcasts activity start to room' do
      expect(BroadcastService).to receive(:to_room).with(
        room.id,
        anything,
        type: :activity_start,
        data: hash_including(:instance_id, :activity_name)
      )

      described_class.start_activity(activity, room: room, initiator: character_instance)
    end

    it 'returns the created instance' do
      instance = described_class.start_activity(activity, room: room, initiator: character_instance)

      expect(instance.id).to be_a(Integer)
      expect(instance.id).to be > 0
    end
  end

  # ============================================
  # .add_participant
  # ============================================
  describe '.add_participant' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }

    it 'raises InvalidStateError when activity is not running' do
      instance.update(running: false)

      expect {
        described_class.add_participant(instance, character_instance)
      }.to raise_error(described_class::InvalidStateError, 'Activity is not running')
    end

    it 'creates a new participant record' do
      participant = described_class.add_participant(instance, character_instance)

      expect(participant).to be_a(ActivityParticipant)
      expect(participant.instance_id).to eq(instance.id)
      expect(participant.char_id).to eq(character.id)
    end

    it 'sets default participant values' do
      participant = described_class.add_participant(instance, character_instance)

      expect(participant.score).to eq(0.0)
      expect(participant.willpower).to eq(10)
      expect(participant.willpower_ticks).to eq(10)
      expect(participant.continue).to be true
    end

    it 'assigns team when specified' do
      participant = described_class.add_participant(instance, character_instance, team: 'one')

      expect(participant.team).to eq('one')
    end

    it 'assigns role when specified' do
      participant = described_class.add_participant(instance, character_instance, role: 'leader')

      expect(participant.role).to eq('leader')
    end

    it 'returns existing participant if already participating' do
      first_participant = described_class.add_participant(instance, character_instance)
      second_participant = described_class.add_participant(instance, character_instance)

      expect(second_participant.id).to eq(first_participant.id)
    end

    it 'associates participant with activity parent' do
      participant = described_class.add_participant(instance, character_instance)

      expect(participant.activity_parent).to eq(activity.id)
    end
  end

  # ============================================
  # .remove_participant
  # ============================================
  describe '.remove_participant' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }
    let!(:participant) { create(:activity_participant, instance: instance, character: character, continue: true) }

    it 'sets participant continue to false' do
      described_class.remove_participant(participant)

      participant.refresh
      expect(participant.continue).to be false
    end

    it 'broadcasts participant left message' do
      expect(BroadcastService).to receive(:to_room).with(
        instance.room_id,
        anything,
        type: :activity_leave,
        data: hash_including(:instance_id)
      )

      described_class.remove_participant(participant)
    end

    it 'ends the activity when the last participant leaves' do
      described_class.remove_participant(participant)

      instance.refresh
      expect(instance.running).to be false
    end
  end

  # ============================================
  # .submit_choice
  # ============================================
  describe '.submit_choice' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }
    let!(:participant) { create(:activity_participant, instance: instance, character: character, continue: true) }
    let(:action) { create(:activity_action, activity: activity) }

    before do
      # Mock the instance methods
      allow(participant).to receive(:active?).and_return(true)
      allow(participant).to receive(:instance).and_return(instance)
      allow(participant).to receive(:submit_choice!)
      allow(instance).to receive(:running?).and_return(true)
      allow(instance).to receive(:all_ready?).and_return(false)
      allow(instance).to receive(:input_timed_out?).and_return(false)
    end

    it 'raises InvalidStateError when participant is not active' do
      allow(participant).to receive(:active?).and_return(false)

      expect {
        described_class.submit_choice(participant, action_id: action.id)
      }.to raise_error(described_class::InvalidStateError, 'You are not in an active activity')
    end

    it 'raises InvalidStateError when activity is not running' do
      allow(instance).to receive(:running?).and_return(false)

      expect {
        described_class.submit_choice(participant, action_id: action.id)
      }.to raise_error(described_class::InvalidStateError, 'Activity is not waiting for input')
    end

    it 'submits choice to participant' do
      expect(participant).to receive(:submit_choice!).with(
        action_id: action.id,
        risk: nil,
        target_id: nil,
        willpower: 0
      )

      described_class.submit_choice(participant, action_id: action.id)
    end

    it 'passes willpower to spend' do
      expect(participant).to receive(:submit_choice!).with(
        action_id: action.id,
        risk: nil,
        target_id: nil,
        willpower: 2
      )

      described_class.submit_choice(participant, action_id: action.id, willpower: 2)
    end

    it 'passes risk and target options' do
      expect(participant).to receive(:submit_choice!).with(
        action_id: action.id,
        risk: 'high',
        target_id: 123,
        willpower: 0
      )

      described_class.submit_choice(participant, action_id: action.id, risk: 'high', target_id: 123)
    end

    it 'returns the participant' do
      result = described_class.submit_choice(participant, action_id: action.id)

      expect(result).to eq(participant)
    end

    it 'does not auto-resolve (waits for explicit ready)' do
      expect(described_class).not_to receive(:check_all_ready)

      described_class.submit_choice(participant, action_id: action.id)
    end
  end

  # ============================================
  # .check_all_ready
  # ============================================
  describe '.check_all_ready' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }

    it 'returns nil when instance is not running' do
      instance.update(running: false)

      result = described_class.check_all_ready(instance)

      expect(result).to be_nil
    end

    context 'when all participants are ready' do
      before do
        allow(instance).to receive(:all_ready?).and_return(true)
        allow(instance).to receive(:input_timed_out?).and_return(false)
        allow(described_class).to receive(:resolve_round)
      end

      it 'calls resolve_round' do
        expect(described_class).to receive(:resolve_round).with(instance)

        described_class.check_all_ready(instance)
      end
    end

    context 'when current round is manually resolved' do
      let(:round) { double('ActivityRound', round_type: 'free_roll', branch?: false) }

      before do
        allow(instance).to receive(:current_round).and_return(round)
        allow(instance).to receive(:all_ready?).and_return(true)
        allow(instance).to receive(:input_timed_out?).and_return(false)
      end

      it 'does not call resolve_round' do
        expect(described_class).not_to receive(:resolve_round)

        described_class.check_all_ready(instance)
      end
    end

    context 'when input has timed out' do
      before do
        allow(instance).to receive(:all_ready?).and_return(false)
        allow(instance).to receive(:input_timed_out?).and_return(true)
        allow(described_class).to receive(:resolve_round)
      end

      it 'calls resolve_round' do
        expect(described_class).to receive(:resolve_round).with(instance)

        described_class.check_all_ready(instance)
      end
    end

    context 'when not ready and not timed out' do
      before do
        allow(instance).to receive(:all_ready?).and_return(false)
        allow(instance).to receive(:input_timed_out?).and_return(false)
      end

      it 'does not call resolve_round' do
        expect(described_class).not_to receive(:resolve_round)

        described_class.check_all_ready(instance)
      end
    end
  end

  # ============================================
  # .resolve_round
  # ============================================
  describe '.resolve_round' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }
    let(:round) { double('ActivityRound', id: 999, round_number: 1, round_type: 'standard', success_text: 'Win!', failure_text: 'Lose!', combat?: false, reflex?: false, group_check?: false, branch?: false, has_media?: false, display_name: 'Round 1', emit_text: nil) }
    let(:resolution_result) { { success: true, participant_rolls: [] } }

    before do
      allow(instance).to receive(:current_round).and_return(round)
      allow(ActivityResolutionService).to receive(:resolve).and_return(resolution_result)
      allow(instance).to receive(:active_participants).and_return([])
      allow(described_class).to receive(:advance_to_next_round)
      allow(described_class).to receive(:handle_round_failure)
    end

    it 'returns nil when no current round' do
      allow(instance).to receive(:current_round).and_return(nil)

      result = described_class.resolve_round(instance)

      expect(result).to be_nil
    end

    it 'calls ActivityResolutionService.resolve' do
      expect(ActivityResolutionService).to receive(:resolve).with(instance, round)

      described_class.resolve_round(instance)
    end

    it 'uses reflex resolver for reflex rounds' do
      allow(round).to receive(:round_type).and_return('reflex')
      allow(ActivityReflexService).to receive(:resolve).and_return(
        ActivityReflexService::ReflexResult.new(success: true, participant_results: [])
      )

      expect(ActivityReflexService).to receive(:resolve).with(instance, round)
      described_class.resolve_round(instance)
    end

    it 'advances to next round on success' do
      expect(described_class).to receive(:advance_to_next_round).with(instance, round)

      described_class.resolve_round(instance)
    end

    it 'handles failure on unsuccessful result' do
      allow(ActivityResolutionService).to receive(:resolve).and_return({ success: false, participant_rolls: [] })
      expect(described_class).to receive(:handle_round_failure).with(instance, round, skip_consequence: false)

      described_class.resolve_round(instance)
    end

    it 'broadcasts round result' do
      expect(BroadcastService).to receive(:to_room).with(
        anything,
        anything,
        type: :activity_result,
        data: hash_including(:instance_id, :success, :rolls)
      )

      described_class.resolve_round(instance)
    end

    it 'broadcasts result before advancing the round' do
      order = []
      allow(described_class).to receive(:broadcast_round_result) { order << :result }
      allow(described_class).to receive(:emit_observer_effects) { order << :observer }
      allow(described_class).to receive(:advance_to_next_round) { order << :advance }

      described_class.resolve_round(instance)
      expect(order).to eq(%i[result observer advance])
    end

    it 'returns the resolution result' do
      result = described_class.resolve_round(instance)

      expect(result).to eq(resolution_result)
    end
  end

  # ============================================
  # .advance_to_next_round
  # ============================================
  describe '.advance_to_next_round' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true, branch: 0) }
    let(:current_round) { double('ActivityRound', round_number: 1, has_media?: false) }
    let(:next_round) { double('ActivityRound', round_number: 2, action_ids: [], round_type: 'standard', emit_text: nil, branch?: false, has_media?: false) }

    before do
      allow(current_round).to receive(:next_round).and_return(nil)
      allow(instance).to receive(:activity).and_return(activity)
      allow(instance).to receive(:current_round).and_return(next_round)
      allow(instance).to receive(:advance_round!)
      allow(instance).to receive(:reset_participant_choices!)
      allow(instance).to receive(:active_participants).and_return([])
      allow(instance).to receive(:current_round_number).and_return(2)
      # push_quickmenus_to_participants checks round type
      allow(next_round).to receive_messages(persuade?: false, free_roll?: false, rest?: false, branch?: false, combat?: false)
    end

    it 'checks mission triggers for round completion' do
      allow(current_round).to receive(:next_round).and_return(next_round)

      expect(TriggerService).to receive(:check_mission_triggers).with(
        activity_instance: instance,
        event_type: 'round_complete',
        round: 1
      )

      described_class.advance_to_next_round(instance, current_round)
    end

    context 'when next round exists' do
      before do
        allow(current_round).to receive(:next_round).and_return(next_round)
      end

      it 'advances to next round' do
        expect(instance).to receive(:advance_round!)

        described_class.advance_to_next_round(instance, current_round)
      end

      it 'broadcasts round start' do
        expect(BroadcastService).to receive(:to_room).with(
          anything,
          anything,
          type: :activity_round,
          data: hash_including(:instance_id, :round_number, :round_type)
        )

        described_class.advance_to_next_round(instance, current_round)
      end
    end

    context 'when no next round exists' do
      before do
        allow(current_round).to receive(:next_round).and_return(nil)
        allow(described_class).to receive(:complete_activity)
      end

      it 'completes the activity with success' do
        expect(described_class).to receive(:complete_activity).with(instance, success: true)

        described_class.advance_to_next_round(instance, current_round)
      end
    end

    context 'when on a branch and no next round' do
      let(:main_branch_round) { double('ActivityRound', round_number: 2, action_ids: [], round_type: 'standard', emit_text: nil, branch?: false, has_media?: false) }

      before do
        allow(instance).to receive(:branch).and_return(1)
        allow(current_round).to receive(:next_round).and_return(nil)
        allow(activity).to receive(:round_at).with(2, 0).and_return(main_branch_round)
        allow(instance).to receive(:update)
        allow(instance).to receive(:current_round).and_return(main_branch_round)
        # push_quickmenus_to_participants checks round type
        allow(main_branch_round).to receive_messages(persuade?: false, free_roll?: false, rest?: false, branch?: false, combat?: false)
      end

      it 'attempts to rejoin main branch' do
        expect(activity).to receive(:round_at).with(2, 0)

        described_class.advance_to_next_round(instance, current_round)
      end

      it 'updates branch to main when rejoining' do
        expect(instance).to receive(:update).with(
          hash_including(branch: 0)
        )

        described_class.advance_to_next_round(instance, current_round)
      end
    end
  end

  # ============================================
  # .handle_round_failure
  # ============================================
  describe '.handle_round_failure' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }
    let(:round) { double('ActivityRound') }

    before do
      allow(instance).to receive(:reset_participant_choices!)
      allow(instance).to receive(:update)
      allow(instance).to receive(:switch_branch!)
      allow(instance).to receive(:advance_round!)
      allow(instance).to receive(:active_participants).and_return([])
      allow(instance).to receive(:current_round).and_return(round)
      allow(round).to receive(:action_ids).and_return([])
      allow(round).to receive(:round_type).and_return('standard')
      allow(round).to receive(:emit_text).and_return(nil)
    end

    context 'when round can be repeated on failure' do
      before do
        allow(round).to receive(:can_fail_repeat?).and_return(true)
        allow(round).to receive(:failure_consequence).and_return('Try again!')
      end

      it 'increments round_repeated counter' do
        expect(instance).to receive(:update).with(round_repeated: 1)

        described_class.handle_round_failure(instance, round)
      end

      it 'resets participant choices' do
        expect(instance).to receive(:reset_participant_choices!)

        described_class.handle_round_failure(instance, round)
      end

      it 'broadcasts retry message' do
        expect(BroadcastService).to receive(:to_room).with(
          anything,
          'Try again!',
          type: :activity_retry,
          data: hash_including(:instance_id)
        )

        described_class.handle_round_failure(instance, round)
      end
    end

    context 'when round is branch that reverts to main' do
      before do
        allow(round).to receive(:can_fail_repeat?).and_return(false)
        allow(round).to receive(:branch?).and_return(true)
        allow(round).to receive(:reverts_to_main?).and_return(true)
        allow(round).to receive(:knockout).and_return(false)
      end

      it 'switches to main branch' do
        expect(instance).to receive(:switch_branch!).with(0)

        described_class.handle_round_failure(instance, round)
      end

      it 'advances round' do
        expect(instance).to receive(:advance_round!)

        described_class.handle_round_failure(instance, round)
      end

      it 'broadcasts branch change' do
        expect(BroadcastService).to receive(:to_room).with(
          anything,
          anything,
          type: :activity_branch,
          data: hash_including(:instance_id, :branch)
        )

        described_class.handle_round_failure(instance, round)
      end
    end

    context 'when round is knockout' do
      before do
        allow(round).to receive(:can_fail_repeat?).and_return(false)
        allow(round).to receive(:branch?).and_return(false)
        allow(round).to receive(:knockout).and_return(true)
        allow(described_class).to receive(:complete_activity)
      end

      it 'completes activity with failure' do
        expect(described_class).to receive(:complete_activity).with(instance, success: false)

        described_class.handle_round_failure(instance, round)
      end
    end

    context 'when regular failure' do
      before do
        allow(round).to receive(:can_fail_repeat?).and_return(false)
        allow(round).to receive(:branch?).and_return(false)
        allow(round).to receive(:knockout).and_return(false)
        allow(round).to receive(:fail_consequence_type).and_return('none')
        allow(described_class).to receive(:advance_to_next_round)
      end

      it 'applies failure consequence and advances' do
        expect(described_class).to receive(:advance_to_next_round).with(instance, round)

        described_class.handle_round_failure(instance, round)
      end
    end

    context 'when failure consequence is branch with a target round' do
      before do
        allow(round).to receive(:can_fail_repeat?).and_return(false)
        allow(round).to receive(:branch?).and_return(false)
        allow(round).to receive(:knockout).and_return(false)
        allow(round).to receive(:fail_consequence_type).and_return('branch')
        allow(round).to receive(:fail_branch_to).and_return(42)
        allow(described_class).to receive(:advance_with_branch)
        allow(described_class).to receive(:advance_to_next_round)
      end

      it 'jumps directly to the configured failure target round' do
        expect(described_class).to receive(:advance_with_branch).with(instance, 42)
        expect(described_class).not_to receive(:advance_to_next_round)

        described_class.handle_round_failure(instance, round)
      end
    end
  end

  # ============================================
  # .apply_failure_consequence
  # ============================================
  describe '.apply_failure_consequence' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }
    let(:round) { double('ActivityRound') }

    before do
      allow(instance).to receive(:active_participants).and_return([])
    end

    context 'difficulty consequence' do
      before do
        allow(round).to receive(:fail_consequence_type).and_return('difficulty')
      end

      it 'increases difficulty modifier' do
        allow(instance).to receive(:inc_difficulty).and_return(0)
        expect(instance).to receive(:update).with(inc_difficulty: 2)

        described_class.apply_failure_consequence(instance, round)
      end

      it 'adds to existing difficulty' do
        allow(instance).to receive(:inc_difficulty).and_return(3)
        expect(instance).to receive(:update).with(inc_difficulty: 5)

        described_class.apply_failure_consequence(instance, round)
      end
    end

    context 'injury consequence' do
      let(:participant1) { double('ActivityParticipant') }
      let(:participant2) { double('ActivityParticipant') }

      before do
        allow(round).to receive(:fail_consequence_type).and_return('injury')
        allow(instance).to receive(:active_participants).and_return([participant1, participant2])
      end

      it 'injures all participants' do
        expect(participant1).to receive(:update).with(injured: true)
        expect(participant2).to receive(:update).with(injured: true)

        described_class.apply_failure_consequence(instance, round)
      end
    end

    context 'harder_finale consequence' do
      before do
        allow(round).to receive(:fail_consequence_type).and_return('harder_finale')
      end

      it 'increases finale modifier' do
        allow(instance).to receive(:finale_modifier).and_return(0)
        expect(instance).to receive(:update).with(finale_modifier: 3)

        described_class.apply_failure_consequence(instance, round)
      end
    end

    context 'branch consequence' do
      before do
        allow(round).to receive(:fail_consequence_type).and_return('branch')
      end

      it 'does not mutate branch state directly' do
        allow(round).to receive(:fail_branch_to).and_return(2)
        expect(instance).not_to receive(:switch_branch!)
        expect(instance).not_to receive(:update)

        described_class.apply_failure_consequence(instance, round)
      end

      it 'is also a no-op when fail_branch_to is nil' do
        allow(round).to receive(:fail_branch_to).and_return(nil)
        expect(instance).not_to receive(:switch_branch!)
        expect(instance).not_to receive(:update)

        described_class.apply_failure_consequence(instance, round)
      end
    end

    context 'none consequence' do
      before do
        allow(round).to receive(:fail_consequence_type).and_return('none')
      end

      it 'does nothing' do
        expect(instance).not_to receive(:update)

        described_class.apply_failure_consequence(instance, round)
      end
    end
  end

  # ============================================
  # .switch_branch
  # ============================================
  describe '.switch_branch' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }
    let(:round) { double('ActivityRound', action_ids: [], round_type: 'standard', emit_text: nil) }

    before do
      allow(instance).to receive(:switch_branch!)
      allow(instance).to receive(:active_participants).and_return([])
      allow(instance).to receive(:current_round).and_return(round)
    end

    it 'switches to the new branch' do
      expect(instance).to receive(:switch_branch!).with(2)

      described_class.switch_branch(instance, 2)
    end

    it 'broadcasts branch change' do
      expect(BroadcastService).to receive(:to_room).with(
        anything,
        anything,
        type: :activity_branch,
        data: hash_including(:instance_id, :branch)
      )

      described_class.switch_branch(instance, 2)
    end

    it 'checks mission triggers for branch change' do
      expect(TriggerService).to receive(:check_mission_triggers).with(
        activity_instance: instance,
        event_type: 'branch',
        branch: 2
      )

      described_class.switch_branch(instance, 2)
    end
  end

  # ============================================
  # .advance_round
  # ============================================
  describe '.advance_round' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }
    let(:round) { double('ActivityRound', round_number: 1, next_round: nil) }

    before do
      allow(instance).to receive(:current_round).and_return(round)
      allow(described_class).to receive(:advance_to_next_round)
    end

    it 'returns nil when no current round' do
      allow(instance).to receive(:current_round).and_return(nil)

      result = described_class.advance_round(instance)

      expect(result).to be_nil
    end

    it 'calls advance_to_next_round' do
      expect(described_class).to receive(:advance_to_next_round).with(instance, round)

      described_class.advance_round(instance)
    end
  end

  # ============================================
  # Delayed post-resolution transitions
  # ============================================
  describe 'delayed post-resolution transitions' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }

    describe '.queue_post_resolution_transition' do
      let(:rest_round) { double('ActivityRound', round_type: 'rest') }
      let(:standard_round) { double('ActivityRound', round_type: 'standard') }

      it 'queues a hold for delayed round types' do
        hold_until = described_class.queue_post_resolution_transition(instance, rest_round)

        expect(hold_until).to be_a(Time)
        expect(instance.refresh.post_resolution_hold_pending?).to be true
      end

      it 'does not queue for non-delayed round types' do
        hold_until = described_class.queue_post_resolution_transition(instance, standard_round)

        expect(hold_until).to be_nil
        expect(instance.refresh.post_resolution_hold_pending?).to be false
      end
    end

    describe '.process_pending_round_transition' do
      it 'returns waiting when hold is active' do
        instance.queue_post_resolution_hold!(30)

        result = described_class.process_pending_round_transition(instance)

        expect(result).to eq(:waiting)
      end

      it 'advances rest rounds when hold is due' do
        instance.update(current_round: (Time.now - 1).to_i)
        round = double('ActivityRound', round_type: 'rest', branch?: false)
        allow(instance).to receive(:current_round).and_return(round)
        allow(instance).to receive(:reset_continue_votes!)
        allow(described_class).to receive(:advance_round)

        expect(instance).to receive(:reset_continue_votes!)
        expect(described_class).to receive(:advance_round).with(instance)

        result = described_class.process_pending_round_transition(instance)

        expect(result).to eq(:advanced)
      end

      it 'resolves and advances branch rounds when hold is due' do
        instance.update(current_round: (Time.now - 1).to_i)
        round = double('ActivityRound', round_type: 'branch', branch?: false)
        resolution = double('BranchResult', chosen_branch_id: 42)
        allow(instance).to receive(:current_round).and_return(round)
        allow(ActivityBranchService).to receive(:resolve).and_return(resolution)
        allow(described_class).to receive(:advance_with_branch)

        expect(ActivityBranchService).to receive(:resolve).with(instance, round)
        expect(described_class).to receive(:advance_with_branch).with(instance, 42)

        result = described_class.process_pending_round_transition(instance)

        expect(result).to eq(:advanced)
      end

      it 'resolves timed-out branch rounds even before a hold exists' do
        branch_round = double('ActivityRound', branch?: true)
        resolution = double('BranchResult', chosen_branch_id: 42, chosen_branch_text: 'Left path')
        allow(instance).to receive(:current_round).and_return(branch_round)
        allow(instance).to receive(:input_timed_out?).and_return(true)
        allow(instance).to receive(:post_resolution_hold_pending?).and_return(false)
        allow(ActivityBranchService).to receive(:resolve).and_return(resolution)
        allow(described_class).to receive(:queue_post_resolution_transition).and_return(nil)
        allow(described_class).to receive(:advance_with_branch)

        expect(ActivityBranchService).to receive(:resolve).with(instance, branch_round)
        expect(described_class).to receive(:advance_with_branch).with(instance, 42)

        result = described_class.process_pending_round_transition(instance)

        expect(result).to eq(:advanced)
      end

      it 'returns waiting for timed-out branch rounds when a post-resolution hold is queued' do
        branch_round = double('ActivityRound', branch?: true)
        resolution = double('BranchResult', chosen_branch_id: nil, chosen_branch_text: 'Stay on course')
        allow(instance).to receive(:current_round).and_return(branch_round)
        allow(instance).to receive(:input_timed_out?).and_return(true)
        allow(instance).to receive(:post_resolution_hold_pending?).and_return(false)
        allow(ActivityBranchService).to receive(:resolve).and_return(resolution)
        allow(described_class).to receive(:queue_post_resolution_transition).and_return(Time.now + 5)
        allow(described_class).to receive(:advance_with_branch)

        result = described_class.process_pending_round_transition(instance)

        expect(result).to eq(:waiting)
        expect(described_class).not_to have_received(:advance_with_branch)
      end
    end
  end

  # ============================================
  # .advance_with_branch
  # ============================================
  describe '.advance_with_branch' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }

    before do
      allow(instance).to receive(:update)
      allow(instance).to receive(:reset_participant_choices!)
      allow(instance).to receive(:active_participants).and_return([])
      allow(instance).to receive(:current_round_number).and_return(2)
    end

    context 'when target round exists' do
      let(:target_round) do
        round = create(:activity_round, activity: activity, round_number: 3, branch: 1)
        round
      end

      before do
        allow(instance).to receive(:current_round).and_return(target_round)
      end

      it 'updates instance to target round' do
        expect(instance).to receive(:update).with(
          hash_including(
            branch: target_round.branch,
            rounds_done: target_round.round_number - 1
          )
        )

        described_class.advance_with_branch(instance, target_round.id)
      end

      it 'resets participant choices' do
        expect(instance).to receive(:reset_participant_choices!)

        described_class.advance_with_branch(instance, target_round.id)
      end

      it 'broadcasts round start' do
        expect(BroadcastService).to receive(:to_room).with(
          anything,
          anything,
          type: :activity_round,
          data: hash_including(:instance_id)
        )

        described_class.advance_with_branch(instance, target_round.id)
      end
    end

    context 'when target round does not exist' do
      before do
        allow(described_class).to receive(:advance_round)
      end

      it 'falls back to normal advance' do
        expect(described_class).to receive(:advance_round).with(instance)

        described_class.advance_with_branch(instance, 999999)
      end
    end

    context 'when target round belongs to a different activity' do
      let(:other_activity) { create(:activity, is_public: true) }
      let(:foreign_round) { create(:activity_round, activity: other_activity, round_number: 2, branch: 0) }

      before do
        allow(described_class).to receive(:advance_round)
      end

      it 'falls back to normal advance' do
        expect(described_class).to receive(:advance_round).with(instance)

        described_class.advance_with_branch(instance, foreign_round.id)
      end
    end
  end

  # ============================================
  # .resolve_round_typed
  # ============================================
  describe '.resolve_round_typed' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }
    let(:round) { double('ActivityRound') }

    before do
      allow(instance).to receive(:current_round).and_return(round)
    end

    it 'returns nil when no current round' do
      allow(instance).to receive(:current_round).and_return(nil)

      result = described_class.resolve_round_typed(instance)

      expect(result).to be_nil
    end

    context 'reflex round type' do
      before do
        allow(round).to receive(:round_type).and_return('reflex')
      end

      it 'calls ActivityReflexService.resolve' do
        expect(ActivityReflexService).to receive(:resolve).with(instance, round)

        described_class.resolve_round_typed(instance)
      end
    end

    context 'group_check round type' do
      before do
        allow(round).to receive(:round_type).and_return('group_check')
      end

      it 'calls ActivityGroupCheckService.resolve' do
        expect(ActivityGroupCheckService).to receive(:resolve).with(instance, round)

        described_class.resolve_round_typed(instance)
      end
    end

    context 'branch round type' do
      before do
        allow(round).to receive(:round_type).and_return('branch')
      end

      it 'returns nil (resolved by voting)' do
        result = described_class.resolve_round_typed(instance)

        expect(result).to be_nil
      end
    end

    context 'rest round type' do
      before do
        allow(round).to receive(:round_type).and_return('rest')
      end

      it 'returns nil (resolved by vote)' do
        result = described_class.resolve_round_typed(instance)

        expect(result).to be_nil
      end
    end

    context 'free_roll round type' do
      before do
        allow(round).to receive(:round_type).and_return('free_roll')
      end

      it 'returns nil (resolved by free-roll commands)' do
        result = described_class.resolve_round_typed(instance)

        expect(result).to be_nil
      end
    end

    context 'persuade round type' do
      before do
        allow(round).to receive(:round_type).and_return('persuade')
      end

      it 'returns nil (resolved by persuade command)' do
        result = described_class.resolve_round_typed(instance)

        expect(result).to be_nil
      end
    end

    context 'combat round type' do
      before do
        allow(round).to receive(:round_type).and_return('combat')
      end

      it 'calls ActivityCombatService.start_combat' do
        expect(ActivityCombatService).to receive(:start_combat).with(instance, round)

        described_class.resolve_round_typed(instance)
      end
    end

    context 'standard round type' do
      before do
        allow(round).to receive(:round_type).and_return('standard')
      end

      it 'calls ActivityResolutionService.resolve' do
        expect(ActivityResolutionService).to receive(:resolve).with(instance, round)

        described_class.resolve_round_typed(instance)
      end
    end
  end

  # ============================================
  # .complete_activity
  # ============================================
  describe '.complete_activity' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }

    before do
      allow(instance).to receive(:complete!)
      allow(instance).to receive(:active_participants).and_return([])
    end

    it 'marks instance as complete' do
      expect(instance).to receive(:complete!).with(success: true)

      described_class.complete_activity(instance, success: true)
    end

    it 'marks instance as failed when success is false' do
      expect(instance).to receive(:complete!).with(success: false)

      described_class.complete_activity(instance, success: false)
    end

    it 'broadcasts completion message' do
      expect(BroadcastService).to receive(:to_room).with(
        anything,
        anything,
        type: :activity_complete,
        data: hash_including(:instance_id, :success, :activity_name)
      )

      described_class.complete_activity(instance, success: true)
    end

    it 'checks mission triggers for success' do
      expect(TriggerService).to receive(:check_mission_triggers).with(
        activity_instance: instance,
        event_type: 'succeed'
      )

      described_class.complete_activity(instance, success: true)
    end

    it 'checks mission triggers for failure' do
      expect(TriggerService).to receive(:check_mission_triggers).with(
        activity_instance: instance,
        event_type: 'fail'
      )

      described_class.complete_activity(instance, success: false)
    end
  end

  # ============================================
  # .available_activities
  # ============================================
  describe '.available_activities' do
    let(:room) { create(:room) }

    before do
      create(:activity, is_public: true, name: 'Public Activity', location: room.id, launch_mode: nil)
      create(:activity, is_public: false, name: 'Private Activity')
    end

    it 'returns only public activities' do
      activities = described_class.available_activities(room)

      expect(activities.map(&:name)).to include('Public Activity')
      expect(activities.map(&:name)).not_to include('Private Activity')
    end

    it 'returns an array of activities' do
      activities = described_class.available_activities(room)

      expect(activities).to all(be_a(Activity))
    end

    it 'includes global activities without a room location' do
      create(:activity, is_public: true, name: 'Global Activity', location: nil, launch_mode: nil)

      activities = described_class.available_activities(room)
      expect(activities.map(&:name)).to include('Global Activity')
    end
  end

  # ============================================
  # .running_activity
  # ============================================
  describe '.running_activity' do
    let(:room) { create(:room) }

    it 'returns running activity in room' do
      running = create(:activity_instance, room: room, running: true)
      create(:activity_instance, room: room, running: false)

      result = described_class.running_activity(room)

      expect(result.id).to eq(running.id)
    end

    it 'returns nil when no running activity' do
      create(:activity_instance, room: room, running: false)

      result = described_class.running_activity(room)

      expect(result).to be_nil
    end

    it 'returns nil for room with no activities' do
      result = described_class.running_activity(room)

      expect(result).to be_nil
    end
  end

  # ============================================
  # .participant_for
  # ============================================
  describe '.participant_for' do
    let!(:instance) { create(:activity_instance, activity: activity, room: room, running: true) }

    it 'delegates to instance.participant_for' do
      expect(instance).to receive(:participant_for).with(character_instance)

      described_class.participant_for(instance, character_instance)
    end
  end

  # ============================================
  # Integration Tests
  # ============================================
  describe 'integration' do
    describe 'full activity lifecycle' do
      let(:user2) { create(:user) }
      let(:character2) { create(:character, user: user2) }
      let(:character_instance2) do
        create(:character_instance, character: character2, current_room: room, online: true)
      end

      before do
        allow(ActivityResolutionService).to receive(:resolve).and_return({ success: true, participant_rolls: [] })
      end

      it 'can start activity, add participants, and complete' do
        # Start activity
        instance = described_class.start_activity(activity, room: room, initiator: character_instance)
        expect(instance).to be_running

        # Add second participant
        participant2 = described_class.add_participant(instance, character_instance2)
        expect(instance.participants.count).to eq(2)

        # Complete activity
        described_class.complete_activity(instance, success: true)
        instance.refresh
        expect(instance).not_to be_running
      end
    end
  end
end
