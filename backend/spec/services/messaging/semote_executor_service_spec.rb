# frozen_string_literal: true

require 'spec_helper'

RSpec.describe SemoteExecutorService do
  let(:character) { create(:character, forename: 'Alice') }
  let(:room) { create(:room) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, stance: 'standing') }
  let(:couch) { create(:place, room: room, name: 'leather couch', capacity: 3) }

  describe '.execute_action' do
    context 'with sit command' do
      before { couch }

      it 'executes sit command on target' do
        result = described_class.execute_action(
          character_instance: character_instance,
          command: 'sit',
          target: 'leather couch',
          emote_text: 'sits on the couch',
          semote_log: nil
        )

        expect(result[:success]).to be true
        character_instance.refresh
        expect(character_instance.stance).to eq('sitting')
      end

      it 'records execution to semote_log when provided' do
        semote_log = SemoteLog.create(
          character_instance_id: character_instance.id,
          emote_text: 'sits on the couch'
        )

        described_class.execute_action(
          character_instance: character_instance,
          command: 'sit',
          target: 'leather couch',
          emote_text: 'sits on the couch',
          semote_log: semote_log
        )

        semote_log.refresh
        executed = semote_log.parsed_executed_actions
        expect(executed.length).to eq(1)
        expect(executed.first[:command]).to eq('sit')
        expect(executed.first[:success]).to be true
      end
    end

    context 'with stand command' do
      before do
        character_instance.update(stance: 'sitting')
      end

      it 'executes stand command without target' do
        result = described_class.execute_action(
          character_instance: character_instance,
          command: 'stand',
          target: nil,
          emote_text: 'stands up',
          semote_log: nil
        )

        expect(result[:success]).to be true
        character_instance.refresh
        expect(character_instance.stance).to eq('standing')
      end
    end

    context 'with invalid target' do
      it 'returns failure but does not raise' do
        result = described_class.execute_action(
          character_instance: character_instance,
          command: 'sit',
          target: 'nonexistent chair',
          emote_text: 'sits on a chair',
          semote_log: nil
        )

        expect(result[:success]).to be false
        expect(result[:error]).not_to be_nil
      end

      it 'records failure to semote_log when provided' do
        semote_log = SemoteLog.create(
          character_instance_id: character_instance.id,
          emote_text: 'sits on a chair'
        )

        described_class.execute_action(
          character_instance: character_instance,
          command: 'sit',
          target: 'nonexistent chair',
          emote_text: 'sits on a chair',
          semote_log: semote_log
        )

        semote_log.refresh
        executed = semote_log.parsed_executed_actions
        expect(executed.length).to eq(1)
        expect(executed.first[:success]).to be false
        expect(executed.first[:error]).not_to be_nil
      end
    end

    context 'with blocklisted command' do
      it 'returns failure for blocklisted commands' do
        result = described_class.execute_action(
          character_instance: character_instance,
          command: 'teleport',
          target: 'somewhere',
          emote_text: 'teleports away',
          semote_log: nil
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('blocklisted')
      end
    end

    context 'with unknown command' do
      it 'returns failure for unknown commands' do
        result = described_class.execute_action(
          character_instance: character_instance,
          command: 'xyzzycommand',
          target: nil,
          emote_text: 'does something weird',
          semote_log: nil
        )

        expect(result[:success]).to be false
        expect(result[:error]).to include('not found')
      end
    end
  end

  describe '.execute_actions_sequentially' do
    before { couch }

    it 'executes multiple non-timed actions in order' do
      # First stand the character up, then sit them down
      character_instance.update(stance: 'sitting')

      actions = [
        { command: 'stand', target: nil },
        { command: 'sit', target: 'leather couch' }
      ]

      results = described_class.execute_actions_sequentially(
        character_instance: character_instance,
        actions: actions,
        emote_text: 'stands up and sits on the couch',
        semote_log: nil
      )

      expect(results.length).to eq(2)
      character_instance.refresh
      expect(character_instance.stance).to eq('sitting')
      expect(character_instance.current_place_id).to eq(couch.id)
    end

    it 'continues past failed actions' do
      actions = [
        { command: 'sit', target: 'nonexistent' },
        { command: 'sit', target: 'leather couch' }
      ]

      results = described_class.execute_actions_sequentially(
        character_instance: character_instance,
        actions: actions,
        emote_text: 'sits down',
        semote_log: nil
      )

      expect(results.length).to eq(2)
      expect(results[0][:success]).to be false
      expect(results[1][:success]).to be true

      character_instance.refresh
      expect(character_instance.stance).to eq('sitting')
    end

    it 'records all executions to semote_log' do
      semote_log = SemoteLog.create(
        character_instance_id: character_instance.id,
        emote_text: 'sits on the couch'
      )

      actions = [
        { command: 'sit', target: 'leather couch' }
      ]

      described_class.execute_actions_sequentially(
        character_instance: character_instance,
        actions: actions,
        emote_text: 'sits on the couch',
        semote_log: semote_log
      )

      semote_log.refresh
      executed = semote_log.parsed_executed_actions
      expect(executed.length).to eq(1)
      expect(executed.first[:command]).to eq('sit')
      expect(executed.first[:success]).to be true
    end
  end

  describe '.command_class_for' do
    it 'finds sit command' do
      klass = described_class.command_class_for('sit')
      expect(klass).not_to be_nil
      expect(klass.command_name).to eq('sit')
    end

    it 'finds stand command' do
      klass = described_class.command_class_for('stand')
      expect(klass).not_to be_nil
      expect(klass.command_name).to eq('stand')
    end

    it 'finds walk command' do
      klass = described_class.command_class_for('walk')
      expect(klass).not_to be_nil
      expect(klass.command_name).to eq('walk')
    end

    it 'returns nil for unknown commands' do
      klass = described_class.command_class_for('xyzzynotreal')
      expect(klass).to be_nil
    end

    it 'returns nil for blocklisted commands' do
      klass = described_class.command_class_for('teleport')
      expect(klass).to be_nil
    end
  end

  describe '.timed_command?' do
    it 'returns true for walk' do
      expect(described_class.timed_command?('walk')).to be true
    end

    it 'returns true for run' do
      expect(described_class.timed_command?('run')).to be true
    end

    it 'returns false for sit' do
      expect(described_class.timed_command?('sit')).to be false
    end

    it 'returns false for stand' do
      expect(described_class.timed_command?('stand')).to be false
    end
  end

  describe 'queue_remaining_actions' do
    it 'stores pending actions in the active timed action' do
      # Create an active timed action
      timed_action = TimedAction.start_delayed(
        character_instance,
        'walk',
        2000,
        'MovementHandler',
        { target: 'north' }
      )

      remaining_actions = [
        { command: 'sit', target: 'couch' },
        { command: 'drink', target: 'coffee' }
      ]
      emote_text = 'walks to the couch and sits down'
      semote_log = SemoteLog.create(
        character_instance_id: character_instance.id,
        emote_text: emote_text
      )

      # Call the private method via send
      described_class.send(
        :queue_remaining_actions,
        character_instance,
        remaining_actions,
        emote_text,
        semote_log
      )

      # Verify the timed action was updated
      timed_action.refresh
      data = timed_action.parsed_action_data

      # Note: JSON serialization converts symbol keys to strings
      # The continuation handler normalizes these back to symbols
      pending = data[:semote_pending_actions]
      expect(pending.length).to eq(2)
      expect(pending[0]['command'] || pending[0][:command]).to eq('sit')
      expect(pending[0]['target'] || pending[0][:target]).to eq('couch')
      expect(pending[1]['command'] || pending[1][:command]).to eq('drink')
      expect(pending[1]['target'] || pending[1][:target]).to eq('coffee')

      expect(data[:semote_emote_text]).to eq(emote_text)
      expect(data[:semote_log_id]).to eq(semote_log.id)
      # Original data preserved
      expect(data[:target]).to eq('north')
    end

    it 'logs warning when no active timed action exists' do
      remaining_actions = [{ command: 'sit', target: 'couch' }]

      expect do
        described_class.send(
          :queue_remaining_actions,
          character_instance,
          remaining_actions,
          'some emote',
          nil
        )
      end.to output(/No active timed action found/).to_stderr
    end
  end
end
