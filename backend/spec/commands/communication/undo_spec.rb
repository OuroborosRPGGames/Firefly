# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Commands::Communication::Undo, type: :command do
  let(:room) { create(:room) }
  let(:reality) { create(:reality) }
  let(:character) { create(:character) }
  let(:character_instance) { create(:character_instance, character: character, current_room: room, reality: reality, online: true) }

  describe '#execute' do
    subject(:command) { described_class.new(character_instance) }

    context 'with nothing to undo' do
      it 'returns error when no undo data exists' do
        result = command.execute('undo')

        expect(result[:success]).to be false
        expect(result[:error]).to include('Nothing to undo')
      end
    end

    context 'with a right-panel IC message to undo' do
      let(:message) { create(:message, character_instance: character_instance, reality: reality, content: 'Hello world') }
      let(:broadcast_id) { SecureRandom.uuid }

      before do
        undo_data = {
          'broadcast_id' => broadcast_id,
          'message_id' => message.id,
          'room_id' => room.id
        }.to_json

        REDIS_POOL.with do |redis|
          redis.set("undo:right:#{character_instance.id}", undo_data)
        end

        allow(BroadcastService).to receive(:to_room)
      end

      it 'succeeds' do
        result = command.execute('undo')
        expect(result[:success]).to be true
        expect(result[:message]).to include('Message undone')
      end

      it 'deletes the message from the database' do
        command.execute('undo')
        expect(Message[message.id]).to be_nil
      end

      it 'broadcasts delete event to the room' do
        command.execute('undo')

        expect(BroadcastService).to have_received(:to_room).with(
          room.id,
          { broadcast_id: broadcast_id },
          type: :delete_message
        )
      end

      it 'removes the undo key from Redis' do
        command.execute('undo')

        REDIS_POOL.with do |redis|
          expect(redis.get("undo:right:#{character_instance.id}")).to be_nil
        end
      end
    end

    context 'with a left-panel channel message to undo' do
      let(:universe) { create(:universe) }
      let(:channel) { create(:channel, universe: universe) }
      let(:broadcast_id) { SecureRandom.uuid }
      let(:other_character) { create(:character) }
      let(:other_instance) { create(:character_instance, character: other_character, current_room: room, reality: reality, online: true) }

      before do
        undo_data = {
          'broadcast_id' => broadcast_id,
          'channel_id' => channel.id,
          'recipient_instance_ids' => [other_instance.id]
        }.to_json

        REDIS_POOL.with do |redis|
          redis.set("undo:left:#{character_instance.id}", undo_data)
        end

        # Stub request_env for left panel
        allow_any_instance_of(described_class).to receive(:request_env).and_return({ 'firefly.source_panel' => 'left' })
        allow(ChannelBroadcastService).to receive(:online_members).and_return([other_instance])
        allow(BroadcastService).to receive(:to_character)
      end

      it 'succeeds' do
        result = command.execute('undo')
        expect(result[:success]).to be true
      end

      it 'sends delete events to channel members and recipients' do
        command.execute('undo')

        # other_instance gets notified (via channel members and/or recipient_instance_ids)
        expect(BroadcastService).to have_received(:to_character).with(
          other_instance,
          { broadcast_id: broadcast_id },
          type: :delete_message
        ).at_least(:once)
      end

      it 'sends delete event to the sender' do
        command.execute('undo')

        expect(BroadcastService).to have_received(:to_character).with(
          character_instance,
          { broadcast_id: broadcast_id },
          type: :delete_message
        ).at_least(:once)
      end
    end

    context 'with a left-panel DM to undo' do
      let(:other_character) { create(:character) }
      let(:other_instance) { create(:character_instance, character: other_character, current_room: room, reality: reality, online: true) }
      let(:broadcast_id) { SecureRandom.uuid }

      let(:dm) do
        DirectMessage.create(
          sender_id: character.id,
          recipient_id: other_character.id,
          content: 'Secret message'
        )
      end

      before do
        undo_data = {
          'broadcast_id' => broadcast_id,
          'dm_ids' => [dm.id],
          'recipient_instance_ids' => [other_instance.id]
        }.to_json

        REDIS_POOL.with do |redis|
          redis.set("undo:left:#{character_instance.id}", undo_data)
        end

        allow_any_instance_of(described_class).to receive(:request_env).and_return({ 'firefly.source_panel' => 'left' })
        allow(BroadcastService).to receive(:to_character)
      end

      it 'deletes the DM records' do
        command.execute('undo')
        expect(DirectMessage[dm.id]).to be_nil
      end

      it 'sends delete events to recipients' do
        command.execute('undo')

        expect(BroadcastService).to have_received(:to_character).with(
          other_instance,
          { broadcast_id: broadcast_id },
          type: :delete_message
        )
      end
    end
  end
end
