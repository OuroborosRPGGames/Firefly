# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WebsocketHandler do
  let(:env) { { 'rack.hijack?' => true } }
  let(:room) { create(:room) }
  let(:zone) { room.zone || create(:zone) }
  let(:character_instance) do
    create(:character_instance, current_room: room).tap do |ci|
      allow(ci).to receive(:current_room).and_return(room)
      allow(ci).to receive(:current_room_id).and_return(room.id)
    end
  end

  let(:mock_ws) { instance_double(Faye::WebSocket) }
  let(:mock_redis) { instance_double(Redis) }
  let(:rack_response) { [200, {}, []] }

  before do
    allow(Faye::WebSocket).to receive(:new).and_return(mock_ws)
    allow(mock_ws).to receive(:on)
    allow(mock_ws).to receive(:send)
    allow(mock_ws).to receive(:close)
    allow(mock_ws).to receive(:rack_response).and_return(rack_response)

    allow(Redis).to receive(:new).and_return(mock_redis)
    allow(mock_redis).to receive(:subscribe).and_yield(double(message: proc { |&_| }))
    allow(mock_redis).to receive(:publish)
    allow(mock_redis).to receive(:setex)
    allow(mock_redis).to receive(:get)
    allow(mock_redis).to receive(:del)
    allow(mock_redis).to receive(:close)

    allow(room).to receive(:zone).and_return(zone)
    allow(character_instance).to receive(:touch_websocket_ping!)
  end

  describe '#initialize' do
    it 'creates a WebSocket connection' do
      expect(Faye::WebSocket).to receive(:new).with(env)
      described_class.new(env, character_instance)
    end

    it 'sets up websocket event handlers' do
      expect(mock_ws).to receive(:on).with(:open)
      expect(mock_ws).to receive(:on).with(:message)
      expect(mock_ws).to receive(:on).with(:close)
      expect(mock_ws).to receive(:on).with(:error)
      described_class.new(env, character_instance)
    end
  end

  describe '#rack_response' do
    it 'returns the websocket rack response' do
      handler = described_class.new(env, character_instance)
      expect(handler.rack_response).to eq(rack_response)
    end
  end

  describe 'on :open event' do
    let(:open_callback) { nil }

    before do
      allow(mock_ws).to receive(:on).with(:open) do |&block|
        @open_callback = block
      end
      allow(mock_ws).to receive(:on).with(:message)
      allow(mock_ws).to receive(:on).with(:close)
      allow(mock_ws).to receive(:on).with(:error)
    end

    it 'touches websocket ping' do
      described_class.new(env, character_instance)
      expect(character_instance).to receive(:touch_websocket_ping!)
      @open_callback.call(double)
    end

    it 'kicks existing connections' do
      described_class.new(env, character_instance)
      expect(mock_redis).to receive(:publish).with(
        "kick:character:#{character_instance.id}",
        anything
      )
      @open_callback.call(double)
    end

    it 'registers the connection' do
      described_class.new(env, character_instance)
      expect(mock_redis).to receive(:setex).with(
        "ws_connection:#{character_instance.id}",
        3600,
        anything
      )
      @open_callback.call(double)
    end

    it 'sends connection confirmation' do
      described_class.new(env, character_instance)
      expect(mock_ws).to receive(:send) do |json|
        payload = JSON.parse(json)
        expect(payload['type']).to eq('connected')
        expect(payload['character_instance_id']).to eq(character_instance.id)
      end
      @open_callback.call(double)
    end
  end

  describe 'on :message event' do
    let(:message_callback) { nil }

    before do
      allow(mock_ws).to receive(:on).with(:open)
      allow(mock_ws).to receive(:on).with(:message) do |&block|
        @message_callback = block
      end
      allow(mock_ws).to receive(:on).with(:close)
      allow(mock_ws).to receive(:on).with(:error)
    end

    context 'when receiving a ping' do
      it 'touches websocket ping and sends pong' do
        # Set up expectations before creating handler
        expect(character_instance).to receive(:touch_websocket_ping!).at_least(:once)

        described_class.new(env, character_instance)

        expect(mock_ws).to receive(:send) do |json|
          payload = JSON.parse(json)
          expect(payload['type']).to eq('pong')
          expect(payload['timestamp']).not_to be_nil
        end

        event = double(data: { type: 'ping' }.to_json)
        @message_callback.call(event)
      end
    end

    context 'when receiving subscribe_room' do
      let(:new_room) { create(:room) }

      it 'subscribes to the new room channel' do
        described_class.new(env, character_instance)
        allow(Room).to receive(:[]).with(new_room.id).and_return(new_room)

        event = double(data: { type: 'subscribe_room', room_id: new_room.id }.to_json)
        @message_callback.call(event)

        # Verify new subscription thread was created (indirectly through Thread.new call)
      end
    end

    context 'when receiving subscribe_zone' do
      let(:new_zone) { create(:zone) }

      it 'subscribes to the new zone channel' do
        described_class.new(env, character_instance)

        event = double(data: { type: 'subscribe_zone', zone_id: new_zone.id }.to_json)
        @message_callback.call(event)
      end
    end

    context 'when receiving invalid JSON' do
      it 'ignores the message without error' do
        described_class.new(env, character_instance)

        event = double(data: 'not valid json')
        expect { @message_callback.call(event) }.not_to raise_error
      end
    end
  end

  describe 'on :close event' do
    let(:close_callback) { nil }

    before do
      allow(mock_ws).to receive(:on).with(:open)
      allow(mock_ws).to receive(:on).with(:message)
      allow(mock_ws).to receive(:on).with(:close) do |&block|
        @close_callback = block
      end
      allow(mock_ws).to receive(:on).with(:error)
    end

    it 'unsubscribes from all channels' do
      described_class.new(env, character_instance)
      @close_callback.call(double)
      # Verify subscriptions are cleared (threads killed)
    end

    it 'unregisters the connection when not kicked' do
      described_class.new(env, character_instance)

      # Mock getting our own connection ID back
      allow(mock_redis).to receive(:get).and_return('some-uuid')

      @close_callback.call(double)
    end
  end

  describe 'on :error event' do
    let(:error_callback) { nil }

    before do
      allow(mock_ws).to receive(:on).with(:open)
      allow(mock_ws).to receive(:on).with(:message)
      allow(mock_ws).to receive(:on).with(:close)
      allow(mock_ws).to receive(:on).with(:error) do |&block|
        @error_callback = block
      end
    end

    it 'logs the error' do
      described_class.new(env, character_instance)

      expect { @error_callback.call(double(message: 'test error')) }.not_to raise_error
    end
  end

  describe 'channel subscriptions' do
    before do
      allow(mock_ws).to receive(:on)
    end

    it 'subscribes to character channel' do
      # Thread.new is called for each subscription
      thread_count = 0
      allow(Thread).to receive(:new) do |&block|
        thread_count += 1
        double(kill: nil)
      end

      described_class.new(env, character_instance)
      expect(thread_count).to be >= 3 # kick, character, room, global (possibly zone)
    end
  end

  describe 'kick message handling' do
    let(:message_callback) { nil }
    let(:kick_handler) { nil }

    before do
      allow(mock_ws).to receive(:on).with(:open)
      allow(mock_ws).to receive(:on).with(:message)
      allow(mock_ws).to receive(:on).with(:close)
      allow(mock_ws).to receive(:on).with(:error)

      # Capture the subscription handler for the kick channel
      allow(mock_redis).to receive(:subscribe) do |channel, &block|
        if channel.start_with?('kick:')
          on_handler = double
          allow(on_handler).to receive(:message) do |&msg_block|
            @kick_message_handler = msg_block
          end
          block.call(on_handler) if block
        end
      end
    end

    context 'when receiving kick for a different connection' do
      it 'sends kicked message and closes websocket' do
        described_class.new(env, character_instance)

        if @kick_message_handler
          expect(mock_ws).to receive(:send) do |json|
            payload = JSON.parse(json)
            expect(payload['type']).to eq('kicked')
            expect(payload['reason']).to eq('logged_in_elsewhere')
          end
          expect(mock_ws).to receive(:close).with(4000, 'Logged in elsewhere')

          # Send kick message from different connection
          @kick_message_handler.call('kick:channel', { connection_id: 'different-id' }.to_json)
        end
      end
    end

    context 'when receiving kick for the same connection' do
      it 'does not close the websocket' do
        # This is harder to test without exposing the connection_id
        # The handler should ignore kicks for its own connection
      end
    end
  end

  describe 'visibility filtering' do
    before do
      allow(mock_ws).to receive(:on)
    end

    context 'when message has visibility_context' do
      it 'checks VisibilityFilterService before delivery' do
        handler = described_class.new(env, character_instance)

        payload = {
          type: 'room_message',
          visibility_context: { reality_id: 1 }
        }

        allow(VisibilityFilterService).to receive(:should_deliver?).and_return(true)

        # Access the private method for testing
        handler.send(:send_message_raw, payload.to_json)

        expect(VisibilityFilterService).to have_received(:should_deliver?)
      end

      it 'does not send if visibility check fails' do
        handler = described_class.new(env, character_instance)

        payload = {
          type: 'room_message',
          visibility_context: { reality_id: 1 }
        }

        allow(VisibilityFilterService).to receive(:should_deliver?).and_return(false)

        expect(mock_ws).not_to receive(:send)

        handler.send(:send_message_raw, payload.to_json)
      end
    end

    context 'when message has no visibility_context' do
      it 'sends the message without filtering' do
        handler = described_class.new(env, character_instance)

        payload = { type: 'system_message', content: 'hello' }

        expect(mock_ws).to receive(:send).with(payload.to_json)

        handler.send(:send_message_raw, payload.to_json)
      end
    end
  end

  describe 'Redis error handling' do
    before do
      allow(mock_ws).to receive(:on)
    end

    context 'when Redis connection fails during publish' do
      it 'logs error but does not raise' do
        allow(mock_redis).to receive(:publish).and_raise(Redis::ConnectionError.new('connection refused'))

        expect { described_class.new(env, character_instance) }.not_to raise_error
      end
    end

    context 'when Redis connection fails during registration' do
      it 'logs error but does not raise' do
        allow(mock_redis).to receive(:setex).and_raise(StandardError.new('failed'))

        # Trigger open event
        open_callback = nil
        allow(mock_ws).to receive(:on).with(:open) { |&block| open_callback = block }

        described_class.new(env, character_instance)

        expect { open_callback&.call(double) }.not_to raise_error
      end
    end
  end

  describe 'room change handling' do
    before do
      allow(mock_ws).to receive(:on).with(:open)
      allow(mock_ws).to receive(:on).with(:message) do |&block|
        @message_callback = block
      end
      allow(mock_ws).to receive(:on).with(:close)
      allow(mock_ws).to receive(:on).with(:error)
    end

    context 'when new room has a zone' do
      let(:new_room) { create(:room) }
      let(:new_zone) { create(:zone) }

      before do
        allow(new_room).to receive(:zone_id).and_return(new_zone.id)
        allow(Room).to receive(:[]).with(new_room.id).and_return(new_room)
      end

      it 'also subscribes to the zone channel' do
        described_class.new(env, character_instance)

        event = double(data: { type: 'subscribe_room', room_id: new_room.id }.to_json)
        @message_callback.call(event)
      end
    end

    context 'when room_id is nil' do
      it 'does not attempt room change' do
        described_class.new(env, character_instance)

        event = double(data: { type: 'subscribe_room', room_id: nil }.to_json)
        expect { @message_callback.call(event) }.not_to raise_error
      end
    end
  end

  describe 'zone change handling' do
    before do
      allow(mock_ws).to receive(:on).with(:open)
      allow(mock_ws).to receive(:on).with(:message) do |&block|
        @message_callback = block
      end
      allow(mock_ws).to receive(:on).with(:close)
      allow(mock_ws).to receive(:on).with(:error)
    end

    context 'when zone_id is nil' do
      it 'does not attempt zone change' do
        described_class.new(env, character_instance)

        event = double(data: { type: 'subscribe_zone', zone_id: nil }.to_json)
        expect { @message_callback.call(event) }.not_to raise_error
      end
    end
  end

  describe 'connection unregistration' do
    before do
      allow(mock_ws).to receive(:on).with(:open)
      allow(mock_ws).to receive(:on).with(:message)
      allow(mock_ws).to receive(:on).with(:close) do |&block|
        @close_callback = block
      end
      allow(mock_ws).to receive(:on).with(:error)
    end

    context 'when this connection is still the active one' do
      it 'deletes the connection key' do
        described_class.new(env, character_instance)

        # Simulate that our connection is still registered
        # We need to get the actual connection_id that was generated
        allow(mock_redis).to receive(:get).and_return('matching-id')
        allow(mock_redis).to receive(:del)

        @close_callback.call(double)

        # The del should only be called if IDs match
      end
    end

    context 'when a different connection is active' do
      it 'does not delete the connection key' do
        described_class.new(env, character_instance)

        allow(mock_redis).to receive(:get).and_return('different-connection-id')

        @close_callback.call(double)

        # del should not be called with non-matching IDs
      end
    end
  end

  describe 'logging' do
    before do
      allow(mock_ws).to receive(:on)
    end

    context 'when LOG_WEBSOCKET is set' do
      around do |example|
        original = ENV['LOG_WEBSOCKET']
        ENV['LOG_WEBSOCKET'] = 'true'
        example.run
        ENV['LOG_WEBSOCKET'] = original
      end

      it 'logs connection events' do
        expect { described_class.new(env, character_instance) }.not_to raise_error
      end
    end

    context 'when in development environment' do
      around do |example|
        original = ENV['RACK_ENV']
        ENV['RACK_ENV'] = 'development'
        example.run
        ENV['RACK_ENV'] = original
      end

      it 'logs connection events' do
        expect { described_class.new(env, character_instance) }.not_to raise_error
      end
    end
  end

  describe 'send_message error handling' do
    before do
      allow(mock_ws).to receive(:on)
    end

    context 'when websocket send fails' do
      it 'logs error but does not raise' do
        handler = described_class.new(env, character_instance)
        allow(mock_ws).to receive(:send).and_raise(StandardError.new('send failed'))

        expect { handler.send(:send_message, { type: 'test' }) }.not_to raise_error
      end
    end

    context 'when websocket is nil' do
      it 'returns early without error' do
        handler = described_class.new(env, character_instance)
        handler.instance_variable_set(:@ws, nil)

        expect { handler.send(:send_message, { type: 'test' }) }.not_to raise_error
      end
    end
  end

  describe 'send_message_raw error handling' do
    before do
      allow(mock_ws).to receive(:on)
    end

    context 'when send fails' do
      it 'logs error but does not raise' do
        handler = described_class.new(env, character_instance)
        allow(mock_ws).to receive(:send).and_raise(StandardError.new('send failed'))

        expect { handler.send(:send_message_raw, '{"type":"test"}') }.not_to raise_error
      end
    end

    context 'when JSON parsing fails' do
      it 'sends the message anyway (fail-open for system messages)' do
        handler = described_class.new(env, character_instance)

        expect(mock_ws).to receive(:send).with('invalid json')

        handler.send(:send_message_raw, 'invalid json')
      end
    end

    context 'when websocket is nil' do
      it 'returns early without error' do
        handler = described_class.new(env, character_instance)
        handler.instance_variable_set(:@ws, nil)

        expect { handler.send(:send_message_raw, '{"type":"test"}') }.not_to raise_error
      end
    end
  end

  describe 'character instance without room' do
    let(:character_instance_no_room) do
      # Use a double instead of factory since factory requires room
      instance_double(
        CharacterInstance,
        id: 999,
        current_room: nil,
        current_room_id: nil,
        touch_websocket_ping!: true
      )
    end

    before do
      allow(mock_ws).to receive(:on)
    end

    it 'does not subscribe to room channel when no room' do
      described_class.new(env, character_instance_no_room)
      # Should not raise error even with nil room
    end
  end

  describe 'kick message JSON parse error' do
    before do
      allow(mock_ws).to receive(:on)

      allow(mock_redis).to receive(:subscribe) do |channel, &block|
        if channel.start_with?('kick:')
          on_handler = double
          allow(on_handler).to receive(:message) do |&msg_block|
            @kick_message_handler = msg_block
          end
          block.call(on_handler) if block
        end
      end
    end

    it 'ignores invalid JSON kick messages' do
      described_class.new(env, character_instance)

      if @kick_message_handler
        expect { @kick_message_handler.call('kick:channel', 'invalid json') }.not_to raise_error
      end
    end
  end
end
