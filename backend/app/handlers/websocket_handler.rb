# frozen_string_literal: true

require 'faye/websocket'
require 'json'
require 'securerandom'

# WebsocketHandler - Manages WebSocket connections for real-time game communication
#
# Uses faye-websocket with Redis pub/sub for message delivery.
# Each connection subscribes to:
#   - character:{instance_id} - Character-specific messages
#   - room:{room_id}          - Room broadcasts
#   - global                  - Server-wide broadcasts
#   - kick:character:{id}     - Connection takeover notifications
#
# Only one WebSocket connection per character instance is allowed.
# When a new tab connects, the old connection receives a 'kicked' message and closes.
#
# Usage:
#   Called from app.rb when /cable receives a WebSocket upgrade request
#
class WebsocketHandler
  def self.redis_url
    ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
  end

  def initialize(env, character_instance)
    @ws = Faye::WebSocket.new(env)
    @character_instance = character_instance
    @connection_id = SecureRandom.uuid
    @subscriptions = []
    @mutex = Mutex.new
    @kicked = false

    setup_websocket
    subscribe_to_channels
  end

  def rack_response
    @ws.rack_response
  end

  private

  def setup_websocket
    @ws.on :open do |_event|
      log_connection(:open)
      @character_instance.touch_websocket_ping!

      # Restore online status if character was marked offline
      # (e.g., after server restart or AutoAfk timeout during a network blip)
      restore_online_status

      # Kick any existing connections for this character instance
      kick_existing_connections

      # Register this connection as the active one
      register_connection

      # Send connection confirmation
      send_message({
        type: 'connected',
        character_instance_id: @character_instance.id,
        connection_id: @connection_id
      })
    end

    @ws.on :message do |event|
      handle_message(event.data)
    end

    @ws.on :close do |_event|
      log_connection(:close)
      unsubscribe_all
      unregister_connection unless @kicked
    end

    @ws.on :error do |event|
      log_error("WebSocket error: #{event.message}")
    end
  end

  def subscribe_to_channels
    # Subscribe to kick channel first (handles connection takeover)
    subscribe_to_kick_channel

    # Subscribe to character-specific channel
    subscribe("character:#{@character_instance.id}")

    # Subscribe to current room channel
    subscribe("room:#{@character_instance.current_room_id}") if @character_instance.current_room_id

    # Subscribe to global channel
    subscribe('global')

    # Subscribe to zone channel if character is in a zone
    zone = @character_instance.current_room&.zone
    subscribe("zone:#{zone.id}") if zone
  end

  def subscribe(channel)
    thread = Thread.new do
      begin
        redis = Redis.new(url: WebsocketHandler.redis_url)
        redis.subscribe(channel) do |on|
          on.message do |_ch, message|
            send_message_raw(message)
          end
        end
      rescue Redis::ConnectionError => e
        log_error("Redis connection error for #{channel}: #{e.message}")
      rescue StandardError => e
        log_error("Subscribe error for #{channel}: #{e.message}")
      ensure
        redis&.close
      end
    end

    @mutex.synchronize do
      @subscriptions << { channel: channel, thread: thread, redis: nil }
    end
  end

  def unsubscribe_all
    @mutex.synchronize do
      @subscriptions.each do |sub|
        sub[:thread]&.raise(Interrupt)
      end
      @subscriptions.clear
    end
  end

  def handle_message(data)
    msg = JSON.parse(data)

    case msg['type']
    when 'ping'
      handle_ping
    when 'subscribe_room'
      handle_room_change(msg['room_id'])
    when 'subscribe_zone'
      handle_zone_change(msg['zone_id'])
    when 'subscribe_fight'
      handle_fight_subscribe(msg['fight_id'])
    end
  rescue JSON::ParserError
    # Ignore invalid messages
  rescue StandardError => e
    log_error("Message handling error: #{e.message}")
  end

  def handle_ping
    @character_instance.touch_websocket_ping!
    send_message({ type: 'pong', timestamp: Time.now.iso8601 })
  end

  def handle_room_change(new_room_id)
    return unless new_room_id

    # Subscribe to new room BEFORE unsubscribing from old (avoid message gap)
    subscribe("room:#{new_room_id}")

    # Unsubscribe from old room subscriptions
    @mutex.synchronize do
      old_subs = @subscriptions.select { |s| s[:channel].start_with?('room:') && s[:channel] != "room:#{new_room_id}" }
      old_subs.each do |sub|
        sub[:thread]&.raise(Interrupt)
        @subscriptions.delete(sub)
      end
    end

    # Check if zone changed too
    new_room = Room[new_room_id]
    new_zone = new_room&.zone
    if new_zone
      handle_zone_change(new_zone.id)
    end
  end

  def handle_zone_change(new_zone_id)
    return unless new_zone_id

    # Unsubscribe from old zone
    @mutex.synchronize do
      old_sub = @subscriptions.find { |s| s[:channel].start_with?('zone:') }
      if old_sub
        old_sub[:thread]&.raise(Interrupt)
        @subscriptions.delete(old_sub)
      end
    end

    # Subscribe to new zone
    subscribe("zone:#{new_zone_id}")
  end

  def handle_fight_subscribe(fight_id)
    return unless fight_id

    # Unsubscribe from old fight generation channel
    @mutex.synchronize do
      old_sub = @subscriptions.find { |s| s[:channel].start_with?('fight:') && s[:channel].end_with?(':generation') }
      if old_sub
        old_sub[:thread]&.raise(Interrupt)
        @subscriptions.delete(old_sub)
      end
    end

    # Subscribe to fight generation channel with message translation
    channel = "fight:#{fight_id}:generation"
    thread = Thread.new do
      begin
        redis = Redis.new(url: WebsocketHandler.redis_url)
        redis.subscribe(channel) do |on|
          on.message do |_ch, message|
            # Translate backend format to frontend format
            data = JSON.parse(message)
            translated = {
              type: 'battle_map_progress',
              fight_id: fight_id,
              progress_type: data['type'],
              progress: data['progress'],
              step: data['step'],
              success: data['success'],
              fallback: data['fallback'],
              battle_map_ready: data['battle_map_ready'],
              timestamp: data['timestamp']
            }.compact
            send_message(translated)
          end
        end
      rescue Redis::ConnectionError => e
        log_error("Redis connection error for #{channel}: #{e.message}")
      rescue StandardError => e
        log_error("Subscribe error for #{channel}: #{e.message}")
      ensure
        redis&.close
      end
    end

    @mutex.synchronize do
      @subscriptions << { channel: channel, thread: thread, redis: nil }
    end
  end

  def send_message(payload)
    return unless @ws

    @ws.send(payload.to_json)
  rescue StandardError => e
    log_error("Send error: #{e.message}")
  end

  def send_message_raw(json_string)
    return unless @ws

    # Filter messages based on visibility context (reality, timeline, etc.)
    # Messages with visibility_context are only delivered to viewers who can see the sender
    begin
      payload = JSON.parse(json_string, symbolize_names: true)

      if payload[:visibility_context]
        return unless VisibilityFilterService.should_deliver?(payload, @character_instance)
      end

      # Skip messages where this character instance is in the exclude list
      # (e.g., the acting player excluded from their own room broadcast)
      if payload[:exclude]&.include?(@character_instance.id)
        return
      end
    rescue JSON::ParserError
      # If we can't parse, just send it through (shouldn't happen, but fail-open for system messages)
    end

    @ws.send(json_string)
  rescue StandardError => e
    log_error("Send raw error: #{e.message}")
  end

  # ========================================
  # Session Restoration
  # ========================================

  # Restore online status when WebSocket reconnects after the character was
  # marked offline (server restart cleanup, AutoAfk timeout, network failure).
  # This keeps the session alive without requiring a full page reload.
  def restore_online_status
    @character_instance.refresh
    return if @character_instance.online

    @character_instance.update(
      online: true,
      last_activity: Time.now,
      session_start_at: Time.now
    )

    warn "[WebSocket] Restored online status for character_instance=#{@character_instance.id}"
  rescue StandardError => e
    log_error("Failed to restore online status: #{e.message}")
  end

  # ========================================
  # Connection Takeover (Single Tab Enforcement)
  # ========================================

  # Subscribe to kick channel to receive takeover notifications
  def subscribe_to_kick_channel
    channel = "kick:character:#{@character_instance.id}"

    thread = Thread.new do
      begin
        redis = Redis.new(url: WebsocketHandler.redis_url)
        redis.subscribe(channel) do |on|
          on.message do |_ch, message|
            handle_kick_message(message)
          end
        end
      rescue Redis::ConnectionError => e
        log_error("Redis connection error for kick channel: #{e.message}")
      rescue StandardError => e
        log_error("Kick channel error: #{e.message}")
      ensure
        redis&.close
      end
    end

    @mutex.synchronize do
      @subscriptions << { channel: channel, thread: thread, redis: nil }
    end
  end

  # Handle incoming kick message - close if it's for a different connection
  def handle_kick_message(message)
    data = JSON.parse(message)
    new_connection_id = data['connection_id']

    # If this kick is from a DIFFERENT connection, we've been superseded
    if new_connection_id && new_connection_id != @connection_id
      @kicked = true
      send_message({
        type: 'kicked',
        reason: 'logged_in_elsewhere',
        message: 'This character logged in from another tab or browser.'
      })

      # Close the WebSocket after sending the message
      @ws&.close(4000, 'Logged in elsewhere')
    end
  rescue JSON::ParserError
    # Ignore invalid kick messages
  rescue StandardError => e
    log_error("Kick message handling error: #{e.message}")
  end

  # Publish kick message to notify other connections they're being replaced
  def kick_existing_connections
    channel = "kick:character:#{@character_instance.id}"

    redis = Redis.new(url: WebsocketHandler.redis_url)
    redis.publish(channel, { connection_id: @connection_id, timestamp: Time.now.iso8601 }.to_json)
  rescue StandardError => e
    log_error("Failed to publish kick message: #{e.message}")
  ensure
    redis&.close
  end

  # Register this connection as the active one in Redis
  def register_connection
    redis = Redis.new(url: WebsocketHandler.redis_url)
    key = "ws_connection:#{@character_instance.id}"
    redis.setex(key, 3600, @connection_id) # 1 hour TTL
  rescue StandardError => e
    log_error("Failed to register connection: #{e.message}")
  ensure
    redis&.close
  end

  # Remove this connection from Redis (only if we're still the active one)
  def unregister_connection
    redis = Redis.new(url: WebsocketHandler.redis_url)
    key = "ws_connection:#{@character_instance.id}"

    # Only delete if this is still our connection (avoid race condition)
    current = redis.get(key)
    redis.del(key) if current == @connection_id
  rescue StandardError => e
    log_error("Failed to unregister connection: #{e.message}")
  ensure
    redis&.close
  end

  # ========================================
  # Logging
  # ========================================

  def log_connection(event)
    return unless ENV['LOG_WEBSOCKET'] || ENV['RACK_ENV'] == 'development'

    warn "[WebSocket] #{event}: character_instance=#{@character_instance.id} " \
         "room=#{@character_instance.current_room_id}"
  end

  def log_error(message)
    warn "[WebSocket] ERROR: #{message}"
  end
end
