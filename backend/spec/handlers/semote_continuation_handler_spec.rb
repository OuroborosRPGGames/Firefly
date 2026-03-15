# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SemoteContinuationHandler do
  let(:character) { create(:character) }
  let(:room) { create(:room) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room) }
  let(:couch) { create(:place, room: room, name: 'leather couch', capacity: 3) }

  describe '.call' do
    let(:timed_action) do
      TimedAction.create(
        character_instance_id: character_instance.id,
        action_type: 'delayed',
        action_name: 'walk',
        duration_ms: 1000,
        started_at: Time.now - 2,
        completes_at: Time.now - 1,
        status: 'active',
        action_data: {
          semote_pending_actions: [{ command: 'sit', target: 'leather couch' }],
          semote_emote_text: 'walks to the couch and sits'
        }.to_json
      )
    end

    before { couch }

    it 'executes pending semote actions after timed action completes' do
      described_class.call(timed_action)

      character_instance.refresh
      expect(character_instance.stance).to eq('sitting')
    end

    it 'does nothing if no pending actions' do
      timed_action.update(action_data: {}.to_json)

      expect { described_class.call(timed_action) }.not_to raise_error
    end

    context 'with string keys from JSON parsing' do
      let(:timed_action) do
        TimedAction.create(
          character_instance_id: character_instance.id,
          action_type: 'delayed',
          action_name: 'walk',
          duration_ms: 1000,
          started_at: Time.now - 2,
          completes_at: Time.now - 1,
          status: 'active',
          action_data: {
            'semote_pending_actions' => [{ 'command' => 'sit', 'target' => 'leather couch' }],
            'semote_emote_text' => 'walks to the couch and sits'
          }.to_json
        )
      end

      it 'handles string keys from JSON parsing' do
        described_class.call(timed_action)

        character_instance.refresh
        expect(character_instance.stance).to eq('sitting')
      end
    end

    context 'when semote_log_id is present' do
      let(:semote_log) do
        SemoteLog.create(
          character_instance_id: character_instance.id,
          emote_text: 'walks to the couch and sits',
          interpreted_actions: [{ command: 'walk', target: 'north' }, { command: 'sit', target: 'leather couch' }].to_json
        )
      end

      let(:timed_action) do
        TimedAction.create(
          character_instance_id: character_instance.id,
          action_type: 'delayed',
          action_name: 'walk',
          duration_ms: 1000,
          started_at: Time.now - 2,
          completes_at: Time.now - 1,
          status: 'active',
          action_data: {
            semote_pending_actions: [{ command: 'sit', target: 'leather couch' }],
            semote_emote_text: 'walks to the couch and sits',
            semote_log_id: semote_log.id
          }.to_json
        )
      end

      it 'passes the semote log to the executor service' do
        expect(SemoteExecutorService).to receive(:execute_actions_sequentially).with(
          character_instance: character_instance,
          actions: [{ command: 'sit', target: 'leather couch' }],
          emote_text: 'walks to the couch and sits',
          semote_log: semote_log
        )

        described_class.call(timed_action)
      end
    end

    context 'when character_instance is nil' do
      let(:mock_timed_action) do
        instance_double(
          TimedAction,
          parsed_action_data: {
            semote_pending_actions: [{ command: 'sit', target: 'leather couch' }],
            semote_emote_text: 'walks to the couch and sits'
          },
          character_instance: nil
        )
      end

      it 'does nothing and does not raise' do
        expect { described_class.call(mock_timed_action) }.not_to raise_error
      end
    end

    context 'when executor service raises an error' do
      before do
        allow(SemoteExecutorService).to receive(:execute_actions_sequentially).and_raise(StandardError, 'Test error')
      end

      it 'logs error and does not raise' do
        expect { described_class.call(timed_action) }.not_to raise_error
      end
    end
  end
end
