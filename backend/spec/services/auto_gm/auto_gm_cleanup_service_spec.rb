# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AutoGm::AutoGmCleanupService do
  let(:now) { Time.now }

  # Helper to build a session double with sensible defaults
  def build_session(overrides = {})
    opts = {
      id: 1,
      status: 'running',
      current_room_id: 100,
      starting_room_id: 100,
      started_at: now - 300,
      created_at: now - 600,
      loop_heartbeat_at: now - 10,
      participant_ids: [1],
      participant_instances: [],
      last_action_at: now - 60,
      gm_can_act?: true
    }.merge(overrides)

    double('AutoGmSession', opts)
  end

  def build_char_instance(online:, current_room_id:)
    double('CharacterInstance', online: online, current_room_id: current_room_id)
  end

  before do
    allow(AutoGm::AutoGmResolutionService).to receive(:abandon)
  end

  describe '.cleanup_all!' do
    context 'when AutoGmSession is not defined' do
      before do
        allow(described_class).to receive(:defined?).and_call_original
        hide_const('AutoGmSession')
      end

      it 'returns empty results without errors' do
        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
        expect(result[:errors]).to be_empty
      end
    end

    context 'when there are no active sessions' do
      before { allow(AutoGmSession).to receive(:active).and_return([]) }

      it 'returns empty results' do
        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end
    end

    context ':all_offline - all participants offline' do
      it 'cleans up the session' do
        ci = build_char_instance(online: false, current_room_id: 100)
        session = build_session(participant_instances: [ci])
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(1)
        expect(result[:reasons][:all_offline]).to eq(1)
        expect(AutoGm::AutoGmResolutionService).to have_received(:abandon)
          .with(session, reason: 'All participants went offline')
      end

      it 'detects all_offline with multiple participants' do
        ci1 = build_char_instance(online: false, current_room_id: 100)
        ci2 = build_char_instance(online: false, current_room_id: 100)
        session = build_session(participant_instances: [ci1, ci2])
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        expect(result[:reasons][:all_offline]).to eq(1)
      end
    end

    context ':left_room - all online participants left the session room' do
      it 'cleans up when last action was over 10 minutes ago' do
        ci = build_char_instance(online: true, current_room_id: 999)
        session = build_session(
          participant_instances: [ci],
          current_room_id: 100,
          last_action_at: now - 601
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(1)
        expect(result[:reasons][:left_room]).to eq(1)
        expect(AutoGm::AutoGmResolutionService).to have_received(:abandon)
          .with(session, reason: 'All participants left the area')
      end

      it 'does NOT clean up if last action was within 10 minutes' do
        ci = build_char_instance(online: true, current_room_id: 999)
        session = build_session(
          participant_instances: [ci],
          current_room_id: 100,
          last_action_at: now - 500
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end

      it 'ignores offline participants when checking room' do
        ci_online_left = build_char_instance(online: true, current_room_id: 999)
        ci_offline_in_room = build_char_instance(online: false, current_room_id: 100)
        session = build_session(
          participant_instances: [ci_online_left, ci_offline_in_room],
          current_room_id: 100,
          last_action_at: now - 601
        )
        # all_offline is false (one is online), but all online ones have left
        # However, all_offline check comes first; with one online, it won't trigger
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        # Should NOT be :all_offline (one is online, one offline)
        # Should be :left_room (all online participants left)
        expect(result[:reasons][:left_room]).to eq(1)
      end

      it 'does NOT trigger left_room when some online participants are still in room' do
        ci_in_room = build_char_instance(online: true, current_room_id: 100)
        ci_left = build_char_instance(online: true, current_room_id: 999)
        session = build_session(
          participant_instances: [ci_in_room, ci_left],
          current_room_id: 100,
          last_action_at: now - 601,
          # Ensure it won't trigger orphaned either
          loop_heartbeat_at: now - 10,
          started_at: now - 300
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end

      it 'falls back to started_at when last_action_at is nil' do
        ci = build_char_instance(online: true, current_room_id: 999)
        session = build_session(
          participant_instances: [ci],
          current_room_id: 100,
          last_action_at: nil,
          started_at: now - 601
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        expect(result[:reasons][:left_room]).to eq(1)
      end
    end

    context ':orphaned - GM loop died (no heartbeat, no recent actions)' do
      it 'cleans up when both heartbeat and last action exceed 30 minutes' do
        ci = build_char_instance(online: true, current_room_id: 100)
        session = build_session(
          participant_instances: [ci],
          current_room_id: 100,
          gm_can_act?: true,
          loop_heartbeat_at: now - 1801,
          last_action_at: now - 1801,
          started_at: now - 3600
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(1)
        expect(result[:reasons][:orphaned]).to eq(1)
        expect(AutoGm::AutoGmResolutionService).to have_received(:abandon)
          .with(session, reason: 'GM loop stopped responding')
      end

      it 'does NOT trigger when heartbeat is recent' do
        ci = build_char_instance(online: true, current_room_id: 100)
        session = build_session(
          participant_instances: [ci],
          current_room_id: 100,
          gm_can_act?: true,
          loop_heartbeat_at: now - 60,
          last_action_at: now - 1801,
          started_at: now - 3600
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end

      it 'does NOT trigger when last action is recent' do
        ci = build_char_instance(online: true, current_room_id: 100)
        session = build_session(
          participant_instances: [ci],
          current_room_id: 100,
          gm_can_act?: true,
          loop_heartbeat_at: now - 1801,
          last_action_at: now - 60,
          started_at: now - 3600
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end

      it 'does NOT trigger when gm_can_act? is false' do
        ci = build_char_instance(online: true, current_room_id: 100)
        session = build_session(
          participant_instances: [ci],
          current_room_id: 100,
          gm_can_act?: false,
          loop_heartbeat_at: now - 1801,
          last_action_at: now - 1801,
          started_at: now - 3600
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end

      it 'treats nil heartbeat as infinitely old' do
        ci = build_char_instance(online: true, current_room_id: 100)
        session = build_session(
          participant_instances: [ci],
          current_room_id: 100,
          gm_can_act?: true,
          loop_heartbeat_at: nil,
          last_action_at: now - 1801,
          started_at: now - 3600
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        expect(result[:reasons][:orphaned]).to eq(1)
      end
    end

    context ':too_long - session exceeds 8 hours' do
      it 'cleans up sessions running over 8 hours' do
        ci = build_char_instance(online: true, current_room_id: 100)
        session = build_session(
          participant_instances: [ci],
          current_room_id: 100,
          gm_can_act?: true,
          loop_heartbeat_at: now - 10,
          last_action_at: now - 10,
          started_at: now - 28_801
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(1)
        expect(result[:reasons][:too_long]).to eq(1)
        expect(AutoGm::AutoGmResolutionService).to have_received(:abandon)
          .with(session, reason: 'Maximum session duration reached')
      end

      it 'does NOT trigger when under 8 hours' do
        ci = build_char_instance(online: true, current_room_id: 100)
        session = build_session(
          participant_instances: [ci],
          current_room_id: 100,
          gm_can_act?: true,
          loop_heartbeat_at: now - 10,
          last_action_at: now - 10,
          started_at: now - 28_700
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end

      it 'falls back to created_at when started_at is nil' do
        ci = build_char_instance(online: true, current_room_id: 100)
        session = build_session(
          participant_instances: [ci],
          current_room_id: 100,
          gm_can_act?: false,
          loop_heartbeat_at: now - 10,
          last_action_at: now - 10,
          started_at: nil,
          created_at: now - 28_801
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        expect(result[:reasons][:too_long]).to eq(1)
      end
    end

    context 'priority ordering' do
      it 'returns :all_offline before :left_room when all offline' do
        # All offline AND in a different room - should pick all_offline first
        ci = build_char_instance(online: false, current_room_id: 999)
        session = build_session(
          participant_instances: [ci],
          current_room_id: 100,
          last_action_at: now - 601
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        expect(result[:reasons][:all_offline]).to eq(1)
        expect(result[:reasons][:left_room]).to eq(0)
      end
    end

    context 'no cleanup needed' do
      it 'skips healthy sessions' do
        ci = build_char_instance(online: true, current_room_id: 100)
        session = build_session(
          participant_instances: [ci],
          current_room_id: 100,
          gm_can_act?: true,
          loop_heartbeat_at: now - 10,
          last_action_at: now - 10,
          started_at: now - 300
        )
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
        expect(AutoGm::AutoGmResolutionService).not_to have_received(:abandon)
      end

      it 'skips sessions with empty participant_instances' do
        session = build_session(participant_instances: [])
        allow(AutoGmSession).to receive(:active).and_return([session])

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end
    end

    context 'multiple sessions' do
      it 'processes each independently and aggregates results' do
        ci_offline = build_char_instance(online: false, current_room_id: 100)
        ci_healthy = build_char_instance(online: true, current_room_id: 200)

        session_offline = build_session(id: 1, participant_instances: [ci_offline])
        session_too_long = build_session(
          id: 2,
          participant_instances: [ci_healthy],
          current_room_id: 200,
          gm_can_act?: true,
          loop_heartbeat_at: now - 10,
          last_action_at: now - 10,
          started_at: now - 28_801
        )

        allow(AutoGmSession).to receive(:active).and_return([session_offline, session_too_long])

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(2)
        expect(result[:reasons][:all_offline]).to eq(1)
        expect(result[:reasons][:too_long]).to eq(1)
      end
    end

    context 'error handling' do
      it 'captures errors per session and continues processing others' do
        ci1 = build_char_instance(online: false, current_room_id: 100)
        ci2 = build_char_instance(online: false, current_room_id: 100)

        session_error = build_session(id: 1, participant_instances: [ci1])
        session_ok = build_session(id: 2, participant_instances: [ci2])

        allow(AutoGmSession).to receive(:active).and_return([session_error, session_ok])
        allow(AutoGm::AutoGmResolutionService).to receive(:abandon).with(session_error, anything)
          .and_raise(StandardError, 'DB connection lost')
        allow(AutoGm::AutoGmResolutionService).to receive(:abandon).with(session_ok, anything)

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(1)
        expect(result[:errors].size).to eq(1)
        expect(result[:errors].first[:session_id]).to eq(1)
        expect(result[:errors].first[:error]).to eq('DB connection lost')
      end
    end
  end
end
