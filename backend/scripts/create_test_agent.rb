# frozen_string_literal: true

#!/usr/bin/env ruby

# Script to create a dedicated test agent user and character for MCP testing.
# Uses API token authentication (no password needed for MCP access).
#
# Token is written to mcp_servers/.api_token for auto-reload without MCP restart.
# Use --force to regenerate an existing token.

require_relative '../config/room_type_config'
Dir[File.join(__dir__, '../app/lib/*.rb')].each { |f| require f }
require_relative '../config/application'

TOKEN_FILE = File.join(__dir__, '../mcp_servers/.api_token')

def create_test_agent(force_new_token: false)
  DB.transaction do
    # Check prerequisites
    reality = Reality.first(reality_type: 'primary') || Reality.first
    raise "No reality found - run seeds first" unless reality

    room = Room.tutorial_spawn_room
    raise "No rooms found - create world first" unless room

    # Find or create user (check both username and email)
    user = User.first(username: 'test_agent') || User.first(email: 'test_agent@firefly.local')
    if user
      puts "Test agent user already exists (id: #{user.id})"
    else
      user = User.new(username: 'test_agent', email: 'test_agent@firefly.local')
      user.set_password(SecureRandom.hex(16)) # Random password, won't be used
      user.save
      puts "Created user: test_agent (id: #{user.id})"
    end

    # Ensure user is admin for full testing capabilities
    unless user.admin?
      user.update(is_admin: true)
      puts "Granted admin privileges to test_agent"
    end

    # Check if we already have a valid token
    token = nil
    if !force_new_token && File.exist?(TOKEN_FILE)
      existing_token = File.read(TOKEN_FILE).strip
      if user.api_token_valid?(existing_token)
        puts "Existing token is still valid"
        token = existing_token
      else
        puts "Existing token expired or invalid, generating new one"
      end
    end

    # Generate new token if needed
    if token.nil?
      token = user.generate_api_token!
      puts "Generated new API token"
    end

    # Write token to file for MCP server auto-reload
    File.write(TOKEN_FILE, token)
    puts "Token written to: #{TOKEN_FILE}"

    # Find or create character
    character = Character.first(user_id: user.id, forename: 'TestBot')
    unless character
      # Check for duplicate name before creating
      existing = Character.first(forename: 'TestBot', surname: 'Agent')
      if existing && existing.user_id != user.id
        raise "Character 'TestBot Agent' already exists (owned by user #{existing.user_id}). Cannot create duplicate."
      end

      character = Character.create(
        user_id: user.id,
        forename: 'TestBot',
        surname: 'Agent',
        short_desc: 'An automated testing agent',
        active: true,
        is_npc: false
      )
      puts "Created character: #{character.full_name} (id: #{character.id})"
    end

    # Find or create instance
    instance = CharacterInstance.first(character_id: character.id, reality_id: reality.id)
    unless instance
      instance = CharacterInstance.create(
        character_id: character.id,
        reality_id: reality.id,
        current_room_id: room.id,
        status: 'alive',
        level: 1,
        experience: 0,
        health: 100,
        max_health: 100,
        mana: 50,
        max_mana: 50
      )
      puts "Created instance: #{instance.id} in #{room.name}"
    end

    puts "\n" + "=" * 50
    puts "TEST AGENT READY"
    puts "=" * 50
    puts "\nToken stored in: #{TOKEN_FILE}"
    puts "MCP server will auto-reload on next request (no restart needed)"
    puts "\nCharacter: #{character.full_name}"
    puts "Room: #{room.name}"
    puts "=" * 50

    { user: user, token: token, character: character, instance: instance }
  end
rescue => e
  puts "ERROR: #{e.message}"
  raise
end

if __FILE__ == $0
  force = ARGV.include?('--force') || ARGV.include?('-f')
  create_test_agent(force_new_token: force)
end
