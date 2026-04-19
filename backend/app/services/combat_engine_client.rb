# frozen_string_literal: true

require 'socket'
require 'json'
require 'msgpack'

# Client for the Rust combat-engine server.
# Communicates over a Unix socket using length-prefixed frames
# (4-byte big-endian length + payload). Payload is JSON by default,
# or MessagePack when COMBAT_ENGINE_FORMAT=msgpack (requires the server to
# be started with the same value).
class CombatEngineClient
  SOCKET_PATH = ENV.fetch('COMBAT_ENGINE_SOCKET', '/tmp/combat-engine.sock')
  CONNECT_TIMEOUT = 5
  READ_TIMEOUT = 30
  MAX_RESPONSE_SIZE = 64 * 1024 * 1024 # 64 MB

  class ConnectionError < StandardError; end
  class ProtocolError < StandardError; end

  # Resolve a combat round through the Rust engine.
  # @param engine_state [Hash] serialized FightState
  # @param actions [Array<Hash>] serialized PlayerAction list
  # @param seed [Integer, nil] optional RNG seed for deterministic results
  # @return [Hash] RoundResult from the engine
  def resolve_round(engine_state, actions, seed: nil, trace_rng: false)
    request = { 'type' => 'resolve_round', 'state' => engine_state, 'actions' => actions }
    request['seed'] = seed if seed
    request['trace_rng'] = true if trace_rng
    send_request(request)
  end

  # Ask the engine to generate AI actions for the given NPC participants.
  # @param engine_state [Hash] serialized FightState
  # @param participant_ids [Array<Integer>] IDs of NPC participants
  # @param seed [Integer, nil] optional RNG seed
  # @return [Array<Hash>] generated PlayerAction list
  def generate_ai_actions(engine_state, participant_ids, seed: nil)
    request = { 'type' => 'generate_ai_actions', 'state' => engine_state, 'participant_ids' => participant_ids }
    request['seed'] = seed if seed
    send_request(request)
  end

  # Health-check ping.
  # @return [Hash] pong response
  def ping
    send_request({ 'type' => 'ping' })
  end

  # Check whether the Unix socket file exists (engine likely running).
  # @return [Boolean]
  def self.available?
    File.socket?(SOCKET_PATH)
  end

  private

  def send_request(payload)
    socket = connect!
    data = encode(payload)

    # Write length-prefixed frame
    socket.write([data.bytesize].pack('N'))
    socket.write(data)

    # Read response frame
    len_bytes = read_exact(socket, 4)
    len = len_bytes.unpack1('N')
    raise ProtocolError, "Response too large: #{len} bytes" if len > MAX_RESPONSE_SIZE

    response_data = read_exact(socket, len)
    result = decode(response_data)

    if result.is_a?(Hash) && result['type'] == 'error'
      raise ProtocolError, "Engine error [#{result['code']}]: #{result['message']}"
    end

    result
  rescue Errno::ECONNREFUSED, Errno::ENOENT => e
    raise ConnectionError, "Combat engine not available: #{e.message}"
  rescue IOError, Errno::EPIPE => e
    raise ConnectionError, "Combat engine connection lost: #{e.message}"
  ensure
    socket&.close
  end

  def connect!
    UNIXSocket.new(SOCKET_PATH)
  rescue Errno::ENOENT, Errno::ECONNREFUSED => e
    raise ConnectionError, "Cannot connect to combat engine at #{SOCKET_PATH}: #{e.message}"
  end

  def read_exact(socket, n)
    buf = ''.b
    while buf.bytesize < n
      chunk = socket.read(n - buf.bytesize)
      raise ConnectionError, 'Unexpected EOF from combat engine' if chunk.nil? || chunk.empty?
      buf << chunk
    end
    buf
  end

  # Default wire format is JSON. Set COMBAT_ENGINE_FORMAT=msgpack to use
  # MessagePack (must also match the server's COMBAT_ENGINE_FORMAT).
  def encode(payload)
    if ENV['COMBAT_ENGINE_FORMAT'] == 'msgpack'
      MessagePack.pack(payload)
    else
      JSON.generate(payload)
    end
  end

  def decode(data)
    if ENV['COMBAT_ENGINE_FORMAT'] == 'msgpack'
      MessagePack.unpack(data)
    else
      JSON.parse(data)
    end
  end
end
