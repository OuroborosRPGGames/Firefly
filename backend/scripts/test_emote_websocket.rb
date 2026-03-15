#!/usr/bin/env ruby
# frozen_string_literal: true

# Simple websocket smoke-test for the emote command.
# Usage:
#   cd backend
#   bundle exec ruby scripts/test_emote_websocket.rb <CHAR_ID> ".waves hello"
# Environment variables:
#   WS_URL        - override websocket endpoint (default: ws://localhost:3000/websocket)
#   CHARACTER_ID  - optional alternative to first CLI argument
#
# This script requires the websocket-client-simple gem:
#   gem install websocket-client-simple

require 'json'
require 'websocket-client-simple'

ws_url = ENV.fetch('WS_URL', 'ws://localhost:3000/websocket')
character_id = (ENV['CHARACTER_ID'] || ARGV.shift)&.strip
command_text = (ARGV.shift || '.waves hello').strip

unless character_id&.match?(/\A\d+\z/)
  warn 'Usage: bundle exec ruby scripts/test_emote_websocket.rb <CHARACTER_ID> ".waves hello"'
  exit 1
end

puts "[setup] Connecting to #{ws_url} as character ##{character_id}"

ws = WebSocket::Client::Simple.connect(ws_url)

trap('INT') do
  puts "\n[signal] Closing connection"
  ws.close
  exit
end

identified = false

ws.on(:open) do
  puts '[ws] Connected'

  identify_payload = { type: 'identify', data: { id: character_id.to_i } }
  puts "[ws] >> #{identify_payload}"
  ws.send(identify_payload.to_json)

  payload = { type: 'input', message: command_text }
  puts "[ws] >> #{payload}"
  ws.send(payload.to_json)
end

ws.on(:message) do |event|
  identified ||= true
  puts "[ws] << #{event.data}"
end

ws.on(:error) do |event|
  warn "[ws:error] #{event}"
end

ws.on(:close) do
  puts '[ws] Connection closed'
  exit identified ? 0 : 1
end

sleep
