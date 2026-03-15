# frozen_string_literal: true

#!/usr/bin/env ruby

# Script to create multiple test agents for multi-agent MCP testing.
# Each agent gets its own user, character, and API token.
# Tokens are saved to config/test_agent_tokens.json for MCP server use.

require_relative '../config/application'
require 'json'

AGENT_NAMES = [
  { forename: 'Alpha', surname: 'Agent', short_desc: 'Test agent Alpha - the leader' },
  { forename: 'Beta', surname: 'Agent', short_desc: 'Test agent Beta - the explorer' },
  { forename: 'Gamma', surname: 'Agent', short_desc: 'Test agent Gamma - the observer' },
  { forename: 'Delta', surname: 'Agent', short_desc: 'Test agent Delta - the tester' },
  { forename: 'Epsilon', surname: 'Agent', short_desc: 'Test agent Epsilon - the backup' }
].freeze

def create_test_agents(count: 3)
  tokens = []

  DB.transaction do
    # Check prerequisites
    reality = Reality.first(reality_type: 'primary') || Reality.first
    raise "No reality found - run seeds first" unless reality

    room = Room.first(room_type: 'spawn') || Room.first(safe_room: true) || Room.first
    raise "No rooms found - create world first" unless room

    count.times do |i|
      agent_config = AGENT_NAMES[i] || {
        forename: "Agent#{i}",
        surname: 'Test',
        short_desc: "Test agent #{i}"
      }

      # Use 0-based indexing to match orchestrator's agent_id
      username = "test_agent_#{i}"

      # Find or create user
      user = User.first(username: username)
      if user
        puts "Agent #{i}: User '#{username}' already exists (id: #{user.id})"
      else
        user = User.new(username: username, email: "#{username}@firefly.local")
        user.set_password(SecureRandom.hex(16))
        user.save
        puts "Agent #{i}: Created user '#{username}' (id: #{user.id})"
      end

      # Generate API token
      token = user.generate_api_token!

      # Find or create character
      character = Character.first(user_id: user.id)
      unless character
        # Check for duplicate name before creating
        existing = Character.first(forename: agent_config[:forename], surname: agent_config[:surname])
        if existing && existing.user_id != user.id
          raise "Character '#{agent_config[:forename]} #{agent_config[:surname]}' already exists (owned by user #{existing.user_id}). Cannot create duplicate."
        end

        character = Character.create(
          user_id: user.id,
          forename: agent_config[:forename],
          surname: agent_config[:surname],
          short_desc: agent_config[:short_desc],
          active: true,
          is_npc: false
        )
        puts "Agent #{i}: Created character '#{character.full_name}' (id: #{character.id})"
      end

      # Find or create instance
      instance = CharacterInstance.first(character_id: character.id, reality_id: reality.id)
      unless instance
        # Spread agents across different starting rooms
        start_room = Room.order(:id).offset(i * 3).first || room

        instance = CharacterInstance.create(
          character_id: character.id,
          reality_id: reality.id,
          current_room_id: start_room.id,
          status: 'alive',
          online: true,
          level: 1,
          experience: 0,
          health: 100,
          max_health: 100,
          mana: 50,
          max_mana: 50
        )
        puts "Agent #{i}: Created instance in '#{start_room.name}' (id: #{instance.id})"
      else
        # Ensure existing instances are online
        instance.update(online: true)
      end

      tokens << {
        agent_id: i,  # 0-based to match orchestrator
        username: username,
        character_name: character.full_name,
        character_id: character.id,
        instance_id: instance.id,
        room: instance.current_room.name,
        token: token
      }
    end
  end

  # Save tokens to config file
  tokens_file = File.join(__dir__, '..', 'config', 'test_agent_tokens.json')
  File.write(tokens_file, JSON.pretty_generate(tokens))
  puts "\nTokens saved to: #{tokens_file}"

  # Print summary
  puts "\n" + "=" * 60
  puts "MULTI-AGENT TEST SETUP COMPLETE"
  puts "=" * 60
  puts "\nCreated #{tokens.length} test agents:"
  tokens.each do |t|
    puts "  Agent #{t[:agent_id]}: #{t[:character_name]} @ #{t[:room]}"
  end
  puts "\nTokens saved to config/test_agent_tokens.json"
  puts "MCP server will automatically load these tokens."
  puts "=" * 60

  tokens
end

# Also update existing TestBot Agent to be online
def ensure_existing_agents_online
  CharacterInstance.where(status: 'alive').update(online: true)
  puts "Set all alive character instances to online"
end

if __FILE__ == $0
  count = ARGV[0]&.to_i || 3
  count = [[count, 1].max, 5].min  # Clamp between 1 and 5

  ensure_existing_agents_online
  create_test_agents(count: count)
end
