#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require_relative '../config/room_type_config'
Dir[File.join(__dir__, '../app/lib/*.rb')].each { |f| require f }
require_relative '../config/application'

# Read token from environment first, then local MCP config.
def read_mcp_token
  env_token = ENV['FIREFLY_API_TOKEN']
  return env_token unless env_token.nil? || env_token.strip.empty?

  mcp_config_path = File.join(__dir__, '../../.mcp.json')
  return nil unless File.exist?(mcp_config_path)

  config = JSON.parse(File.read(mcp_config_path))
  config.dig('mcpServers', 'firefly-test', 'env', 'FIREFLY_API_TOKEN')
rescue JSON::ParserError => e
  warn "[regen_token] Failed to parse .mcp.json: #{e.message}"
  nil
end

def update_test_agent_token!(token)
  user = User.first(email: 'test_agent@firefly.local')
  unless user
    warn '[regen_token] test_agent@firefly.local not found'
    return
  end

  user[:api_token_digest] = BCrypt::Password.create(token)
  user[:api_token_created_at] = Time.now
  user[:api_token_expires_at] = nil
  user.save(validate: false)
  puts '[regen_token] Updated API token digest to match MCP token'

  found = User.find_by_api_token(token)
  puts "[regen_token] VERIFIED=#{found ? 'true' : 'false'}"

  character = user.characters.first
  return unless character

  instance = CharacterInstance.first(character_id: character.id)
  return unless instance

  instance.update(online: true)
  puts "[regen_token] INSTANCE=#{instance.id}"
end

token = read_mcp_token
abort '[regen_token] FIREFLY_API_TOKEN not set in env or .mcp.json' if token.nil? || token.strip.empty?

update_test_agent_token!(token)
