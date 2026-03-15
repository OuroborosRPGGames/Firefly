# frozen_string_literal: true

require 'spec_helper'

RSpec.describe TriggerCodeExecutor do
  describe 'constants' do
    it 'defines EXECUTION_TIMEOUT from GameConfig' do
      expect(described_class::EXECUTION_TIMEOUT).to eq(GameConfig::LLM::TIMEOUTS[:trigger_code])
    end
  end

  describe 'SandboxContext' do
    let(:context) { { room_id: 123 } }
    let(:activation) do
      double('TriggerActivation',
        source_character_id: 42,
        source_character: double('Character'),
        clue_recipient_id: 99,
        clue_id: 10
      )
    end

    let(:sandbox) { described_class::SandboxContext.new(context: context, activation: activation) }

    describe '#initialize' do
      it 'stores context' do
        expect(sandbox.context).to eq(context)
      end

      it 'stores activation' do
        expect(sandbox.activation).to eq(activation)
      end

      it 'initializes empty results' do
        expect(sandbox.results).to eq([])
      end
    end

    describe '#broadcast_to_room' do
      before do
        allow(BroadcastService).to receive(:to_room)
      end

      it 'calls BroadcastService' do
        expect(BroadcastService).to receive(:to_room).with(123, 'Hello', type: :system)

        sandbox.broadcast_to_room(123, 'Hello')
      end

      it 'records result' do
        sandbox.broadcast_to_room(456, 'Test message')

        expect(sandbox.results).to include('Broadcast to room 456')
      end
    end

    describe '#send_to_character' do
      let(:character_instance) { double('CharacterInstance', id: 42) }

      before do
        allow(BroadcastService).to receive(:to_character)
      end

      context 'when character is online' do
        before do
          allow(sandbox).to receive(:find_online_character).with(42).and_return(character_instance)
        end

        it 'sends message via BroadcastService' do
          expect(BroadcastService).to receive(:to_character).with(character_instance, 'Hello', type: :system)

          sandbox.send_to_character(42, 'Hello')
        end

        it 'records result' do
          sandbox.send_to_character(42, 'Hello')

          expect(sandbox.results).to include('Message sent to character 42')
        end
      end

      context 'when character is not online' do
        before do
          allow(sandbox).to receive(:find_online_character).with(99).and_return(nil)
        end

        it 'records not online' do
          sandbox.send_to_character(99, 'Hello')

          expect(sandbox.results).to include('Character 99 not online')
        end
      end
    end

    describe '#award_currency' do
      let(:wallet) { double('Wallet') }

      context 'when wallet exists' do
        before do
          allow(Wallet).to receive(:first).with(character_id: 42).and_return(wallet)
          allow(wallet).to receive(:add_currency)
        end

        it 'adds currency to wallet' do
          expect(wallet).to receive(:add_currency).with('credits', 100)

          sandbox.award_currency(42, 100)
        end

        it 'records result with custom currency' do
          sandbox.award_currency(42, 50, currency_name: 'gold')

          expect(sandbox.results).to include('Awarded 50 gold to character 42')
        end
      end

      context 'when no wallet exists' do
        before do
          allow(Wallet).to receive(:first).with(character_id: 99).and_return(nil)
        end

        it 'records no wallet message' do
          sandbox.award_currency(99, 100)

          expect(sandbox.results).to include('No wallet for character 99')
        end
      end
    end

    describe '#spawn_npc' do
      before do
        allow(NpcSpawnService).to receive(:spawn_at_room)
      end

      it 'calls NpcSpawnService' do
        expect(NpcSpawnService).to receive(:spawn_at_room).with(character_id: 5, room_id: 123)

        sandbox.spawn_npc(5, 123)
      end

      it 'records result' do
        sandbox.spawn_npc(5, 123)

        expect(sandbox.results).to include('Spawned NPC 5 at room 123')
      end
    end

    describe '#despawn_npc' do
      let(:npc_instance) { double('CharacterInstance') }

      context 'when NPC is online' do
        before do
          allow(sandbox).to receive(:find_online_character).with(5).and_return(npc_instance)
          allow(npc_instance).to receive(:update)
        end

        it 'sets online to false' do
          expect(npc_instance).to receive(:update).with(online: false)

          sandbox.despawn_npc(5)
        end

        it 'records result' do
          sandbox.despawn_npc(5)

          expect(sandbox.results).to include('Despawned NPC 5')
        end
      end

      context 'when NPC is not online' do
        before do
          allow(sandbox).to receive(:find_online_character).with(99).and_return(nil)
        end

        it 'records not online' do
          sandbox.despawn_npc(99)

          expect(sandbox.results).to include('NPC 99 not online')
        end
      end
    end

    describe '#set_game_setting' do
      before do
        allow(GameSetting).to receive(:set)
      end

      it 'sets game setting' do
        expect(GameSetting).to receive(:set).with('debug_mode', true)

        sandbox.set_game_setting('debug_mode', true)
      end

      it 'records result' do
        sandbox.set_game_setting('test_key', 'test_value')

        expect(sandbox.results).to include('Set game setting test_key = test_value')
      end
    end

    describe '#game_setting' do
      before do
        allow(GameSetting).to receive(:get).with('test_key').and_return('test_value')
      end

      it 'returns game setting value' do
        result = sandbox.game_setting('test_key')

        expect(result).to eq('test_value')
      end
    end

    describe '#start_activity' do
      let(:activity) { double('Activity', id: 1) }
      let(:room) { double('Room', id: 123) }
      let(:initiator) { double('CharacterInstance') }

      before do
        allow(Activity).to receive(:[]).with(1).and_return(activity)
        allow(Room).to receive(:[]).with(123).and_return(room)
        allow(sandbox).to receive(:find_online_character).with(42).and_return(initiator)
        allow(ActivityService).to receive(:start_activity)
      end

      it 'starts activity' do
        expect(ActivityService).to receive(:start_activity).with(activity, room: room, initiator: initiator)

        sandbox.start_activity(1, room_id: 123, initiator_id: 42)
      end

      it 'records result' do
        sandbox.start_activity(1, room_id: 123, initiator_id: 42)

        expect(sandbox.results).to include('Started activity 1 in room 123')
      end

      context 'when activity not found' do
        before do
          allow(Activity).to receive(:[]).with(99).and_return(nil)
        end

        it 'records not found' do
          sandbox.start_activity(99, room_id: 123, initiator_id: 42)

          expect(sandbox.results).to include('Activity 99 not found')
        end
      end

      context 'when room not found' do
        before do
          allow(Room).to receive(:[]).with(999).and_return(nil)
        end

        it 'records room not found' do
          sandbox.start_activity(1, room_id: 999, initiator_id: 42)

          expect(sandbox.results).to include('Room 999 not found')
        end
      end

      context 'when initiator not online' do
        before do
          allow(sandbox).to receive(:find_online_character).with(999).and_return(nil)
        end

        it 'records initiator not online' do
          sandbox.start_activity(1, room_id: 123, initiator_id: 999)

          expect(sandbox.results).to include('Initiator 999 not online')
        end
      end
    end

    describe '#alert_staff' do
      before do
        allow(StaffAlertService).to receive(:broadcast_to_staff)
      end

      it 'broadcasts to staff' do
        expect(StaffAlertService).to receive(:broadcast_to_staff).with('Important message')

        sandbox.alert_staff('Important message')
      end

      it 'records result' do
        sandbox.alert_staff('Test alert')

        expect(sandbox.results).to include('Alerted staff: Test alert')
      end
    end

    describe '#log' do
      it 'records logged message' do
        allow($stdout).to receive(:puts) # Suppress console output

        sandbox.log('Debug info')

        expect(sandbox.results).to include('Logged: Debug info')
      end
    end

    describe 'context accessors' do
      it 'returns trigger_context' do
        expect(sandbox.trigger_context).to eq(context)
      end

      it 'returns source_character_id' do
        expect(sandbox.source_character_id).to eq(42)
      end

      it 'returns source_room_id' do
        expect(sandbox.source_room_id).to eq(123)
      end

      it 'returns source_character' do
        expect(sandbox.source_character).to eq(activation.source_character)
      end

      it 'returns clue_recipient_id' do
        expect(sandbox.clue_recipient_id).to eq(99)
      end

      it 'returns clue_id' do
        expect(sandbox.clue_id).to eq(10)
      end
    end
  end

  describe '.execute' do
    let(:context) { { room_id: 123 } }
    let(:activation) do
      double('TriggerActivation',
        source_character_id: 42,
        source_character: double('Character'),
        clue_recipient_id: nil,
        clue_id: nil
      )
    end

    context 'with nil code' do
      it 'returns no code message' do
        result = described_class.execute(code: nil, context: context, activation: activation)

        expect(result).to eq('No code to execute')
      end
    end

    context 'with empty code' do
      it 'returns no code message' do
        result = described_class.execute(code: '   ', context: context, activation: activation)

        expect(result).to eq('No code to execute')
      end
    end

    context 'with valid code' do
      it 'executes code in sandbox' do
        code = "log('Test')"
        allow($stdout).to receive(:puts)

        result = described_class.execute(code: code, context: context, activation: activation)

        expect(result).to include('Logged: Test')
      end

      it 'joins multiple results' do
        code = "log('One'); log('Two')"
        allow($stdout).to receive(:puts)

        result = described_class.execute(code: code, context: context, activation: activation)

        expect(result).to eq('Logged: One; Logged: Two')
      end
    end

    context 'with timeout' do
      it 'raises timeout error' do
        code = 'while true; end'

        # Use a very short timeout for test
        stub_const("#{described_class}::EXECUTION_TIMEOUT", 0.01)

        expect {
          described_class.execute(code: code, context: context, activation: activation)
        }.to raise_error(/timed out/)
      end
    end

    context 'with syntax error' do
      it 'raises syntax error' do
        code = 'def broken('

        expect {
          described_class.execute(code: code, context: context, activation: activation)
        }.to raise_error(/Syntax error/)
      end
    end

    context 'with runtime error' do
      it 'raises execution error' do
        code = 'raise "Custom error"'

        expect {
          described_class.execute(code: code, context: context, activation: activation)
        }.to raise_error(/Execution error.*Custom error/)
      end
    end
  end

  describe '.validate_syntax' do
    context 'with nil code' do
      it 'returns valid' do
        result = described_class.validate_syntax(nil)

        expect(result[:valid]).to be true
        expect(result[:error]).to be_nil
      end
    end

    context 'with empty code' do
      it 'returns valid' do
        result = described_class.validate_syntax('   ')

        expect(result[:valid]).to be true
        expect(result[:error]).to be_nil
      end
    end

    context 'with valid code' do
      it 'returns valid' do
        result = described_class.validate_syntax('puts "hello"')

        expect(result[:valid]).to be true
        expect(result[:error]).to be_nil
      end

      it 'validates multiline code' do
        code = <<~RUBY
          def foo
            bar
          end
        RUBY

        result = described_class.validate_syntax(code)

        expect(result[:valid]).to be true
      end
    end

    context 'with invalid syntax' do
      it 'returns invalid with error' do
        result = described_class.validate_syntax('def broken(')

        expect(result[:valid]).to be false
        expect(result[:error]).to be_a(String)
      end

      it 'returns error message for unclosed string' do
        result = described_class.validate_syntax('"unclosed string')

        expect(result[:valid]).to be false
        expect(result[:error]).to be_a(String)
      end
    end
  end
end
