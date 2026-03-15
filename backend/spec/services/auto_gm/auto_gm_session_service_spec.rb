# frozen_string_literal: true

require 'spec_helper'
require_relative 'shared_context'

RSpec.describe AutoGm::AutoGmSessionService do
  include_context 'auto_gm_setup'

  describe 'constants' do
    it 'has SESSION_TIMEOUT_SECONDS' do
      expect(described_class::SESSION_TIMEOUT_SECONDS).to eq(2 * 60 * 60)
    end

    it 'has GM_LOOP_POLL_INTERVAL' do
      expect(described_class::GM_LOOP_POLL_INTERVAL).to eq(2)
    end

    it 'has GM_ACTION_COOLDOWN' do
      expect(described_class::GM_ACTION_COOLDOWN).to eq(30)
    end
  end

  describe '.start_session' do
    before do
      allow(GameSetting).to receive(:get).with('auto_gm_enabled').and_return(nil)
      allow(AutoGmSession).to receive(:create).and_return(session)
      allow(Thread).to receive(:new).and_yield
      allow(described_class).to receive(:execute_pipeline)
    end

    it 'raises error without room' do
      expect {
        described_class.start_session(room: nil, participants: [char_instance])
      }.to raise_error(ArgumentError, /Room is required/)
    end

    it 'raises error without participants' do
      expect {
        described_class.start_session(room: room, participants: [])
      }.to raise_error(ArgumentError, /At least one participant/)
    end

    it 'raises error when auto-gm is disabled' do
      allow(GameSetting).to receive(:get).with('auto_gm_enabled').and_return(false)
      expect {
        described_class.start_session(room: room, participants: [char_instance])
      }.to raise_error(ArgumentError, /currently disabled/)
    end

    it 'creates session with correct status' do
      expect(AutoGmSession).to receive(:create).with(hash_including(
        status: 'gathering',
        starting_room_id: room.id,
        chaos_level: 5
      ))
      described_class.start_session(room: room, participants: [char_instance])
    end

    it 'starts pipeline in background thread' do
      expect(Thread).to receive(:new)
      described_class.start_session(room: room, participants: [char_instance])
    end

    it 'returns the session' do
      result = described_class.start_session(room: room, participants: [char_instance])
      expect(result).to eq(session)
    end
  end

  describe '.execute_pipeline' do
    let(:context) { { room_context: {}, participant_context: [] } }
    let(:brainstorm_result) { { success: true, outputs: { creative_a: 'Idea A' } } }
    let(:synthesis_result) { { success: true, sketch: sketch, locations_used: [1] } }
    let(:incite_result) { { success: true, action: action } }

    before do
      allow(AutoGm::AutoGmContextService).to receive(:gather).and_return(context)
      allow(AutoGm::AutoGmBrainstormService).to receive(:brainstorm).and_return(brainstorm_result)
      allow(AutoGm::AutoGmSynthesisService).to receive(:synthesize).and_return(synthesis_result)
      allow(AutoGm::AutoGmInciteService).to receive(:deploy).and_return(incite_result)
      allow(described_class).to receive(:run_gm_loop)
    end

    it 'gathers context' do
      expect(AutoGm::AutoGmContextService).to receive(:gather).with(session)
      described_class.execute_pipeline(session)
    end

    it 'brainstorms ideas' do
      expect(AutoGm::AutoGmBrainstormService).to receive(:brainstorm).with(
        session: session,
        context: context,
        options: {}
      )
      described_class.execute_pipeline(session)
    end

    it 'synthesizes adventure sketch' do
      expect(AutoGm::AutoGmSynthesisService).to receive(:synthesize).with(
        brainstorm_outputs: brainstorm_result[:outputs],
        context: context,
        options: {}
      )
      described_class.execute_pipeline(session)
    end

    it 'deploys inciting incident' do
      expect(AutoGm::AutoGmInciteService).to receive(:deploy).with(session)
      described_class.execute_pipeline(session)
    end

    it 'enters GM loop' do
      expect(described_class).to receive(:run_gm_loop).with(session)
      described_class.execute_pipeline(session)
    end

    it 'updates session status through phases' do
      expect(session).to receive(:update).with(status: 'gathering')
      expect(session).to receive(:update).with(memory_context: context)
      expect(session).to receive(:update).with(status: 'sketching')
      expect(session).to receive(:update).with(brainstorm_outputs: brainstorm_result[:outputs])
      expect(session).to receive(:update).with(hash_including(:sketch))
      expect(session).to receive(:update).with(status: 'inciting')
      expect(session).to receive(:update).with(hash_including(status: 'running'))
      described_class.execute_pipeline(session)
    end

    context 'when brainstorming fails' do
      before do
        allow(AutoGm::AutoGmBrainstormService).to receive(:brainstorm).and_return({
          success: false,
          errors: ['Model A failed', 'Model B failed']
        })
      end

      it 'fails the session' do
        expect(session).to receive(:update).with(hash_including(status: 'abandoned'))
        described_class.execute_pipeline(session)
      end

      it 'broadcasts error' do
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(:content),
          hash_including(type: :auto_gm_error)
        )
        described_class.execute_pipeline(session)
      end
    end

    context 'when synthesis fails' do
      before do
        allow(AutoGm::AutoGmSynthesisService).to receive(:synthesize).and_return({
          success: false,
          error: 'Validation failed'
        })
      end

      it 'fails the session' do
        expect(session).to receive(:update).with(hash_including(status: 'abandoned'))
        described_class.execute_pipeline(session)
      end
    end

    context 'when inciting fails' do
      before do
        allow(AutoGm::AutoGmInciteService).to receive(:deploy).and_return({
          success: false,
          error: 'No inciting incident'
        })
      end

      it 'fails the session' do
        expect(session).to receive(:update).with(hash_including(status: 'abandoned'))
        described_class.execute_pipeline(session)
      end
    end

    context 'when exception occurs' do
      before do
        allow(AutoGm::AutoGmContextService).to receive(:gather).and_raise(StandardError.new('DB error'))
      end

      it 'fails the session with error' do
        expect(session).to receive(:update).with(hash_including(status: 'abandoned'))
        described_class.execute_pipeline(session)
      end
    end
  end

  describe '.status' do
    before do
      allow(session).to receive(:reload).and_return(session)
      allow(session).to receive(:started_at).and_return(Time.now - 600)
      allow(session).to receive(:countdown).and_return(3)
      allow(session).to receive(:in_combat?).and_return(false)
      allow(session).to receive(:resolved?).and_return(false)
      allow(session).to receive(:resolution_type).and_return(nil)
      allow(auto_gm_actions_dataset).to receive(:count).and_return(5)
    end

    it 'returns session status info' do
      result = described_class.status(session)

      expect(result[:id]).to eq(session.id)
      expect(result[:status]).to eq('running')
      expect(result[:title]).to eq('The Lost Temple')
      expect(result[:current_stage]).to eq(0)
      expect(result[:chaos_level]).to eq(5)
      expect(result[:countdown]).to eq(3)
      expect(result[:action_count]).to eq(5)
    end

    it 'calculates elapsed time' do
      result = described_class.status(session)
      expect(result[:elapsed_seconds]).to be_within(5).of(600)
    end

    it 'calculates timeout remaining' do
      result = described_class.status(session)
      expect(result[:timeout_in_seconds]).to be_within(5).of(7200 - 600)
    end
  end

  describe '.end_session' do
    context 'with success resolution' do
      before do
        allow(AutoGm::AutoGmResolutionService).to receive(:resolve)
      end

      it 'calls ResolutionService.resolve' do
        expect(AutoGm::AutoGmResolutionService).to receive(:resolve).with(
          session,
          resolution_type: :success
        )
        described_class.end_session(session, resolution_type: :success)
      end
    end

    context 'with failure resolution' do
      before do
        allow(AutoGm::AutoGmResolutionService).to receive(:resolve)
      end

      it 'calls ResolutionService.resolve' do
        expect(AutoGm::AutoGmResolutionService).to receive(:resolve).with(
          session,
          resolution_type: :failure
        )
        described_class.end_session(session, resolution_type: :failure)
      end
    end

    context 'with abandoned resolution' do
      before do
        allow(AutoGm::AutoGmResolutionService).to receive(:abandon)
      end

      it 'calls ResolutionService.abandon' do
        expect(AutoGm::AutoGmResolutionService).to receive(:abandon).with(
          session,
          reason: 'Test reason'
        )
        described_class.end_session(session, resolution_type: :abandoned, reason: 'Test reason')
      end
    end
  end

  describe '.leave_session' do
    before do
      allow(session).to receive(:participant_ids).and_return([char_instance.id, 2])
      allow(session).to receive(:remove_participant!).with(char_instance)
      allow(AutoGm::AutoGmResolutionService).to receive(:abandon)
    end

    it 'removes the participant' do
      expect(session).to receive(:remove_participant!).with(char_instance)
      described_class.leave_session(session, char_instance)
    end

    it 'returns ended false when participants remain' do
      result = described_class.leave_session(session, char_instance)
      expect(result).to eq(success: true, ended: false)
    end

    it 'abandons the session when last participant leaves' do
      allow(session).to receive(:participant_ids).and_return([char_instance.id], [])
      expect(AutoGm::AutoGmResolutionService).to receive(:abandon).with(
        session,
        reason: 'All participants left the adventure'
      )
      result = described_class.leave_session(session, char_instance)
      expect(result).to eq(success: true, ended: true)
    end

    it 'returns error when character is not a participant' do
      allow(session).to receive(:participant_ids).and_return([99])
      result = described_class.leave_session(session, char_instance)
      expect(result[:success]).to be false
      expect(result[:error]).to include('not in this adventure')
    end
  end

  describe '.active_sessions_for' do
    before do
      allow(AutoGmSession).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', all: [session]))
      )
    end

    it 'queries sessions with participant ID' do
      expect(AutoGmSession).to receive(:where)
      described_class.active_sessions_for(char_instance)
    end

    it 'returns array of sessions' do
      result = described_class.active_sessions_for(char_instance)
      expect(result).to eq([session])
    end
  end

  describe '.active_session_in_room' do
    before do
      allow(AutoGmSession).to receive(:where).and_return(
        double('Dataset', where: double('Dataset', first: session))
      )
    end

    it 'queries by current room' do
      expect(AutoGmSession).to receive(:where).with(current_room_id: room.id)
      described_class.active_session_in_room(room)
    end

    it 'returns the session' do
      result = described_class.active_session_in_room(room)
      expect(result).to eq(session)
    end
  end

  describe '.process_player_action' do
    before do
      allow(AutoGmAction).to receive(:create_with_next_sequence).and_return(action)
      allow(AutoGm::AutoGmDecisionService).to receive(:quick_response).and_return({
        action_type: 'emit',
        params: { 'emit_text' => 'Response' },
        reasoning: 'GM response'
      })
      allow(AutoGm::AutoGmActionExecutor).to receive(:execute)
      allow(auto_gm_actions_dataset).to receive(:max).and_return(5)
    end

    context 'with any action type' do
      it 'records player action' do
        expect(AutoGmAction).to receive(:create_with_next_sequence).with(
          session_id: session.id,
          attributes: hash_including(action_type: 'player_action')
        )
        described_class.process_player_action(session, char_instance, 'say', { description: 'Hello' })
      end

      it 'does not trigger immediate GM response (GM loop handles reactions)' do
        expect(AutoGm::AutoGmDecisionService).not_to receive(:quick_response)
        expect(AutoGm::AutoGmActionExecutor).not_to receive(:execute)
        described_class.process_player_action(session, char_instance, 'say', { description: 'Hello' })
      end
    end

    context 'when session is not running' do
      before do
        allow(session).to receive(:status).and_return('gathering')
      end

      it 'does nothing' do
        expect(AutoGmAction).not_to receive(:create_with_next_sequence)
        described_class.process_player_action(session, char_instance, 'say', {})
      end
    end
  end

  describe '.process_combat_complete' do
    before do
      allow(AutoGm::AutoGmEventService).to receive(:adjust_chaos)
      allow(AutoGm::AutoGmDecisionService).to receive(:quick_response).and_return({
        action_type: 'emit',
        params: {},
        reasoning: 'Test'
      })
      allow(AutoGm::AutoGmActionExecutor).to receive(:execute)
    end

    context 'with victory' do
      it 'updates session status' do
        expect(session).to receive(:update).with(status: 'running', current_fight_id: nil)
        described_class.process_combat_complete(session, double('Fight'), :victory)
      end

      it 'adjusts chaos with PC in control' do
        expect(AutoGm::AutoGmEventService).to receive(:adjust_chaos).with(session, pc_in_control: true)
        described_class.process_combat_complete(session, double('Fight'), :victory)
      end
    end

    context 'with defeat' do
      it 'adjusts chaos with PC not in control' do
        expect(AutoGm::AutoGmEventService).to receive(:adjust_chaos).with(session, pc_in_control: false)
        described_class.process_combat_complete(session, double('Fight'), :defeat)
      end
    end

    it 'triggers GM response' do
      expect(AutoGm::AutoGmDecisionService).to receive(:quick_response)
      expect(AutoGm::AutoGmActionExecutor).to receive(:execute)
      described_class.process_combat_complete(session, double('Fight'), :victory)
    end
  end

  describe 'constants' do
    it 'has HEARTBEAT_STALE_SECONDS' do
      expected = [GameConfig::AutoGm::TIMEOUTS[:decision].to_i + 45, 120].max
      expect(described_class::HEARTBEAT_STALE_SECONDS).to eq(expected)
    end
  end

  describe '.recover_orphaned_loops' do
    let(:stale_session) do
      double('AutoGmSession',
             id: 42,
             status: 'running',
             loop_heartbeat_at: Time.now - 60,
             loop_owner: '12345:old_thread',
             update: true)
    end

    # Build a flexible dataset double that supports all chained methods
    let(:flexible_dataset) do
      dbl = double('Dataset')
      allow(dbl).to receive(:where).and_return(dbl)
      allow(dbl).to receive(:all).and_return([])
      allow(dbl).to receive(:for_update).and_return(dbl)
      allow(dbl).to receive(:skip_locked).and_return(dbl)
      allow(dbl).to receive(:first).and_return(nil)
      dbl
    end

    before do
      allow(AutoGmSession).to receive(:where).and_return(flexible_dataset)
      allow(DB).to receive(:transaction).and_yield
      allow(Thread).to receive(:new)
    end

    context 'when no orphaned sessions exist' do
      it 'returns 0' do
        expect(described_class.recover_orphaned_loops).to eq(0)
      end

      it 'does not spawn threads' do
        expect(Thread).not_to receive(:new)
        described_class.recover_orphaned_loops
      end
    end

    context 'when orphaned sessions exist' do
      before do
        allow(flexible_dataset).to receive(:all).and_return([stale_session])
        allow(flexible_dataset).to receive(:first).and_return(stale_session)
      end

      it 'returns the count of recovered sessions' do
        expect(described_class.recover_orphaned_loops).to eq(1)
      end

      it 'claims the session with a fresh heartbeat' do
        expect(stale_session).to receive(:update).with(
          hash_including(loop_heartbeat_at: an_instance_of(Time))
        )
        described_class.recover_orphaned_loops
      end

      it 'spawns a recovery thread' do
        expect(Thread).to receive(:new)
        described_class.recover_orphaned_loops
      end
    end

    context 'when another worker claims the session first (SKIP LOCKED)' do
      before do
        allow(flexible_dataset).to receive(:all).and_return([stale_session])
        # FOR UPDATE SKIP LOCKED returns nil — another worker got it
        allow(flexible_dataset).to receive(:first).and_return(nil)
      end

      it 'returns 0' do
        expect(described_class.recover_orphaned_loops).to eq(0)
      end

      it 'does not spawn a thread' do
        expect(Thread).not_to receive(:new)
        described_class.recover_orphaned_loops
      end
    end
  end

  describe 'private methods' do
    describe '#should_continue_loop?' do
      it 'returns true for running status' do
        allow(session).to receive(:status).and_return('running')
        expect(described_class.send(:should_continue_loop?, session)).to be true
      end

      it 'returns true for climax status' do
        allow(session).to receive(:status).and_return('climax')
        expect(described_class.send(:should_continue_loop?, session)).to be true
      end

      it 'returns false for other statuses' do
        allow(session).to receive(:status).and_return('completed')
        expect(described_class.send(:should_continue_loop?, session)).to be false
      end
    end

    describe '#session_timed_out?' do
      it 'returns false if not started' do
        allow(session).to receive(:started_at).and_return(nil)
        expect(described_class.send(:session_timed_out?, session)).to be false
      end

      it 'returns false if within timeout' do
        allow(session).to receive(:started_at).and_return(Time.now - 3600)
        expect(described_class.send(:session_timed_out?, session)).to be false
      end

      it 'returns true if past timeout' do
        allow(session).to receive(:started_at).and_return(Time.now - 8000)
        expect(described_class.send(:session_timed_out?, session)).to be true
      end
    end

    describe '#should_gm_act?' do
      before do
        allow(session).to receive(:in_combat?).and_return(false)
      end

      context 'when not running' do
        before do
          allow(session).to receive(:status).and_return('gathering')
        end

        it 'returns false' do
          expect(described_class.send(:should_gm_act?, session)).to be false
        end
      end

      context 'when in combat' do
        before do
          allow(session).to receive(:in_combat?).and_return(true)
        end

        it 'returns false' do
          expect(described_class.send(:should_gm_act?, session)).to be false
        end
      end

      context 'when no actions' do
        before do
          allow(auto_gm_actions_dataset).to receive(:empty?).and_return(true)
        end

        it 'returns true' do
          expect(described_class.send(:should_gm_act?, session)).to be true
        end
      end

      context 'with recent GM action' do
        let(:recent_action) { double('Action', created_at: Time.now - 10) }

        before do
          allow(auto_gm_actions_dataset).to receive(:empty?).and_return(false)
          allow(auto_gm_actions_dataset).to receive(:exclude).and_return(
            double('Dataset', order: double('Dataset', first: recent_action))
          )
        end

        it 'returns false (cooldown not passed)' do
          expect(described_class.send(:should_gm_act?, session)).to be false
        end
      end

      context 'with old GM action' do
        let(:old_action) { double('Action', created_at: Time.now - 60) }

        before do
          allow(auto_gm_actions_dataset).to receive(:empty?).and_return(false)
          allow(auto_gm_actions_dataset).to receive(:exclude).and_return(
            double('Dataset', order: double('Dataset', first: old_action))
          )
        end

        it 'returns true (cooldown passed)' do
          expect(described_class.send(:should_gm_act?, session)).to be true
        end
      end
    end

    describe '#fail_session' do
      it 'updates session status' do
        expect(session).to receive(:update).with(hash_including(
          status: 'abandoned',
          resolution_type: 'abandoned'
        ))
        described_class.send(:fail_session, session, 'Test error')
      end

      it 'stores error in world state' do
        expect(session).to receive(:update).with(hash_including(:world_state))
        described_class.send(:fail_session, session, 'Test error')
      end

      it 'truncates long error messages' do
        long_error = 'x' * 200
        expect(BroadcastService).to receive(:to_room).with(
          room.id,
          hash_including(content: /\.\.\./),
          anything
        )
        described_class.send(:fail_session, session, long_error)
      end
    end
  end
end
