# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActivityCleanupService do
  let(:room_id) { 42 }

  before do
    allow(BroadcastService).to receive(:to_room)
    allow(ActivityService).to receive(:complete_activity)
  end

  def build_instance(overrides = {})
    participants = overrides.delete(:participants) || []
    active_participants_dataset = double('dataset', all: participants)

    defaults = {
      id: rand(1000),
      running: true,
      room_id: room_id,
      created_at: Time.now,
      round_started_at: Time.now,
      setup_stage: nil,
      paused_for_fight_id: nil
    }

    attrs = defaults.merge(overrides)

    instance = double('ActivityInstance', **attrs)
    allow(instance).to receive(:in_setup?).and_return(attrs[:setup_stage] && attrs[:setup_stage] < 3)
    allow(instance).to receive(:paused_for_combat?).and_return(!attrs[:paused_for_fight_id].nil?)
    allow(instance).to receive(:active_participants).and_return(active_participants_dataset)
    allow(instance).to receive(:complete!)
    instance
  end

  def build_participant(char_instance:, char_id: rand(1000))
    participant = double('ActivityParticipant', char_id: char_id, continue: true)
    allow(participant).to receive(:character_instance).and_return(char_instance)
    participant
  end

  def online_character(current_room_id: room_id)
    double('CharacterInstance', current_room_id: current_room_id)
  end

  def stub_running_instances(*instances)
    allow(ActivityInstance).to receive(:where).with(running: true).and_return(instances)
  end

  describe '.cleanup_all!' do
    it 'returns a results hash with required keys' do
      stub_running_instances
      result = described_class.cleanup_all!
      expect(result).to include(:cleaned, :reasons, :errors)
    end

    it 'returns zeroes when no running activities exist' do
      stub_running_instances
      result = described_class.cleanup_all!
      expect(result[:cleaned]).to eq(0)
      expect(result[:errors]).to be_empty
    end

    it 'skips instances with no active participants' do
      instance = build_instance(participants: [])
      stub_running_instances(instance)

      result = described_class.cleanup_all!
      expect(result[:cleaned]).to eq(0)
      expect(ActivityService).not_to have_received(:complete_activity).with(instance, anything)
    end

    context ':stuck_setup - in setup too long' do
      it 'cleans up activities stuck in setup for over 15 minutes' do
        participant = build_participant(char_instance: online_character)
        instance = build_instance(
          setup_stage: 1,
          created_at: Time.now - GameConfig::Cleanup::ACTIVITY_STUCK_SETUP_SECONDS - 60,
          participants: [participant]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(1)
        expect(result[:reasons][:stuck_setup]).to eq(1)
        expect(ActivityService).to have_received(:complete_activity).with(instance, success: false, broadcast: false)
        expect(BroadcastService).to have_received(:to_room).with(
          room_id,
          hash_including(content: 'The activity has ended - setup was not completed in time.'),
          type: :activity
        )
      end

      it 'does not clean up activities in setup under 15 minutes' do
        participant = build_participant(char_instance: online_character)
        instance = build_instance(
          setup_stage: 1,
          created_at: Time.now - 60,
          participants: [participant]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
        expect(ActivityService).not_to have_received(:complete_activity).with(instance, anything)
      end

      it 'does not flag setup_stage >= 3 as stuck in setup' do
        participant = build_participant(char_instance: online_character)
        instance = build_instance(
          setup_stage: 3,
          created_at: Time.now - GameConfig::Cleanup::ACTIVITY_STUCK_SETUP_SECONDS - 60,
          round_started_at: Time.now,
          participants: [participant]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!
        expect(result[:reasons][:stuck_setup]).to eq(0)
      end
    end

    context ':too_long - exceeded max duration' do
      it 'cleans up activities running over 24 hours' do
        participant = build_participant(char_instance: online_character)
        instance = build_instance(
          created_at: Time.now - GameConfig::Cleanup::ACTIVITY_MAX_DURATION_SECONDS - 60,
          round_started_at: Time.now,
          participants: [participant]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(1)
        expect(result[:reasons][:too_long]).to eq(1)
        expect(ActivityService).to have_received(:complete_activity).with(instance, success: false, broadcast: false)
        expect(BroadcastService).to have_received(:to_room).with(
          room_id,
          hash_including(content: 'The activity has ended - maximum duration reached.'),
          type: :activity
        )
      end

      it 'does not clean up activities under 24 hours' do
        participant = build_participant(char_instance: online_character)
        instance = build_instance(
          created_at: Time.now - 3600,
          round_started_at: Time.now,
          participants: [participant]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end
    end

    context ':all_offline - all participants offline' do
      it 'cleans up when all participants have no online character_instance' do
        p1 = build_participant(char_instance: nil)
        p2 = build_participant(char_instance: nil)
        instance = build_instance(
          created_at: Time.now - 60,
          participants: [p1, p2]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(1)
        expect(result[:reasons][:all_offline]).to eq(1)
        expect(ActivityService).to have_received(:complete_activity).with(instance, success: false, broadcast: false)
        expect(BroadcastService).to have_received(:to_room).with(
          room_id,
          hash_including(content: 'The activity has ended - all participants have gone offline.'),
          type: :activity
        )
      end

      it 'does not clean up when at least one participant is online' do
        p1 = build_participant(char_instance: online_character)
        p2 = build_participant(char_instance: nil)
        instance = build_instance(
          created_at: Time.now - 60,
          round_started_at: Time.now,
          participants: [p1, p2]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end
    end

    context ':left_room - all online participants left the room' do
      it 'cleans up when all online participants are in a different room and round_started_at > 5 min ago' do
        other_room_id = room_id + 1
        p1 = build_participant(char_instance: online_character(current_room_id: other_room_id))
        p2 = build_participant(char_instance: nil) # offline, ignored
        instance = build_instance(
          created_at: Time.now - 600,
          round_started_at: Time.now - GameConfig::Cleanup::ACTIVITY_ALL_LEFT_ROOM_SECONDS - 60,
          participants: [p1, p2]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(1)
        expect(result[:reasons][:left_room]).to eq(1)
        expect(ActivityService).to have_received(:complete_activity).with(instance, success: false, broadcast: false)
        expect(BroadcastService).to have_received(:to_room).with(
          room_id,
          hash_including(content: 'The activity has ended - all participants have left the area.'),
          type: :activity
        )
      end

      it 'does not clean up when participants left recently (under 5 min)' do
        other_room_id = room_id + 1
        p1 = build_participant(char_instance: online_character(current_room_id: other_room_id))
        instance = build_instance(
          created_at: Time.now - 600,
          round_started_at: Time.now - 60,
          participants: [p1]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end

      it 'does not clean up when some online participants are still in the room' do
        other_room_id = room_id + 1
        p1 = build_participant(char_instance: online_character(current_room_id: room_id))
        p2 = build_participant(char_instance: online_character(current_room_id: other_room_id))
        instance = build_instance(
          created_at: Time.now - 600,
          round_started_at: Time.now - GameConfig::Cleanup::ACTIVITY_ALL_LEFT_ROOM_SECONDS - 60,
          participants: [p1, p2]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end

      it 'falls back to created_at when round_started_at is nil' do
        other_room_id = room_id + 1
        p1 = build_participant(char_instance: online_character(current_room_id: other_room_id))
        instance = build_instance(
          created_at: Time.now - GameConfig::Cleanup::ACTIVITY_ALL_LEFT_ROOM_SECONDS - 60,
          round_started_at: nil,
          participants: [p1]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(1)
        expect(result[:reasons][:left_room]).to eq(1)
      end
    end

    context ':inactive - no round progress for 30+ minutes' do
      it 'cleans up when round_started_at is over 30 minutes ago' do
        p1 = build_participant(char_instance: online_character)
        instance = build_instance(
          created_at: Time.now - 3600,
          round_started_at: Time.now - GameConfig::Cleanup::ACTIVITY_INACTIVITY_SECONDS - 60,
          participants: [p1]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(1)
        expect(result[:reasons][:inactive]).to eq(1)
        expect(ActivityService).to have_received(:complete_activity).with(instance, success: false, broadcast: false)
        expect(BroadcastService).to have_received(:to_room).with(
          room_id,
          hash_including(content: 'The activity has ended due to inactivity.'),
          type: :activity
        )
      end

      it 'does not clean up when round_started_at is recent' do
        p1 = build_participant(char_instance: online_character)
        instance = build_instance(
          created_at: Time.now - 3600,
          round_started_at: Time.now - 60,
          participants: [p1]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end

      it 'does not clean up inactive activities that are paused for combat' do
        p1 = build_participant(char_instance: online_character)
        instance = build_instance(
          created_at: Time.now - 3600,
          round_started_at: Time.now - GameConfig::Cleanup::ACTIVITY_INACTIVITY_SECONDS - 60,
          paused_for_fight_id: 99,
          participants: [p1]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!
        expect(result[:cleaned]).to eq(0)
      end

      it 'falls back to created_at when round_started_at is nil' do
        p1 = build_participant(char_instance: online_character)
        instance = build_instance(
          created_at: Time.now - GameConfig::Cleanup::ACTIVITY_INACTIVITY_SECONDS - 60,
          round_started_at: nil,
          participants: [p1]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(1)
        expect(result[:reasons][:inactive]).to eq(1)
      end
    end

    context 'priority ordering' do
      it 'returns :stuck_setup before :too_long for old setup activities' do
        p1 = build_participant(char_instance: online_character)
        instance = build_instance(
          setup_stage: 1,
          created_at: Time.now - GameConfig::Cleanup::ACTIVITY_MAX_DURATION_SECONDS - 60,
          participants: [p1]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!
        expect(result[:reasons][:stuck_setup]).to eq(1)
        expect(result[:reasons][:too_long]).to eq(0)
      end

      it 'returns :too_long before :all_offline for very old activities' do
        p1 = build_participant(char_instance: nil)
        instance = build_instance(
          created_at: Time.now - GameConfig::Cleanup::ACTIVITY_MAX_DURATION_SECONDS - 60,
          participants: [p1]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!
        expect(result[:reasons][:too_long]).to eq(1)
        expect(result[:reasons][:all_offline]).to eq(0)
      end
    end

    context 'multiple activities' do
      it 'cleans up multiple activities with different reasons' do
        p1 = build_participant(char_instance: nil)
        offline_instance = build_instance(
          id: 1,
          created_at: Time.now - 60,
          participants: [p1]
        )

        p2 = build_participant(char_instance: online_character)
        inactive_instance = build_instance(
          id: 2,
          created_at: Time.now - 3600,
          round_started_at: Time.now - GameConfig::Cleanup::ACTIVITY_INACTIVITY_SECONDS - 60,
          participants: [p2]
        )

        stub_running_instances(offline_instance, inactive_instance)

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(2)
        expect(result[:reasons][:all_offline]).to eq(1)
        expect(result[:reasons][:inactive]).to eq(1)
      end
    end

    context 'completion pathway' do
      it 'uses ActivityService.complete_activity with broadcast disabled when possible' do
        participant = build_participant(char_instance: nil)
        instance = build_instance(
          created_at: Time.now - 60,
          participants: [participant],
          activity: double('Activity')
        )
        stub_running_instances(instance)

        expect(ActivityService).to receive(:complete_activity).with(instance, success: false, broadcast: false)

        described_class.cleanup_all!
      end
    end

    context 'error handling' do
      it 'captures errors without stopping cleanup of other activities' do
        p1 = build_participant(char_instance: nil)
        failing_instance = build_instance(
          id: 1,
          created_at: Time.now - 60,
          participants: [p1]
        )
        allow(ActivityService).to receive(:complete_activity).with(failing_instance, anything).and_raise(StandardError.new('DB error'))

        p2 = build_participant(char_instance: online_character)
        good_instance = build_instance(
          id: 2,
          created_at: Time.now - 3600,
          round_started_at: Time.now - GameConfig::Cleanup::ACTIVITY_INACTIVITY_SECONDS - 60,
          participants: [p2]
        )

        stub_running_instances(failing_instance, good_instance)

        result = described_class.cleanup_all!

        expect(result[:errors]).to include(hash_including(instance_id: 1, error: 'DB error'))
        expect(result[:cleaned]).to eq(1)
        expect(ActivityService).to have_received(:complete_activity).with(good_instance, success: false, broadcast: false)
      end
    end

    context 'healthy activity - no cleanup needed' do
      it 'does not clean up a healthy active activity' do
        p1 = build_participant(char_instance: online_character)
        instance = build_instance(
          created_at: Time.now - 600,
          round_started_at: Time.now - 60,
          participants: [p1]
        )
        stub_running_instances(instance)

        result = described_class.cleanup_all!

        expect(result[:cleaned]).to eq(0)
        expect(ActivityService).not_to have_received(:complete_activity).with(instance, anything)
        expect(BroadcastService).not_to have_received(:to_room)
      end
    end
  end
end
