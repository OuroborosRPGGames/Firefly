# frozen_string_literal: true

#!/usr/bin/env ruby

# Script to create multiple test agent users for multi-agent MCP testing.
# Creates separate users/characters that can be controlled independently.
#
# Usage:
#   bundle exec ruby scripts/create_multi_test_agents.rb        # Create 5 agents
#   bundle exec ruby scripts/create_multi_test_agents.rb 3      # Create 3 agents
#   bundle exec ruby scripts/create_multi_test_agents.rb --force # Regenerate tokens
#
# Tokens are written to config/test_agent_tokens.json for the orchestrator.

require_relative '../config/room_type_config'
require_relative '../config/application'
require 'json'

TOKENS_FILE = File.join(__dir__, '../config/test_agent_tokens.json')
DEFAULT_AGENT_COUNT = 5

AGENT_NAMES = %w[Alpha Bravo Charlie Delta Echo Foxtrot Golf Hotel].freeze

TEST_ROOM_NAME = 'Command Test Chamber'
TEST_ROOM_DESC = 'A featureless white chamber used for automated command testing. The walls are smooth and unmarked.'

def find_or_create_test_room(_reality)
  # Find existing test room
  existing = Room.first(name: TEST_ROOM_NAME)
  return existing if existing

  # Use the first available zone/world, or create one
  zone = Zone.first(name: 'Test Environment')
  unless zone
    world = World.first
    raise "No world found - create world first" unless world

    zone = Zone.create(
      name: 'Test Environment',
      zone_type: 'city',
      danger_level: 0,
      active: true,
      world_id: world.id,
      polygon_points: [{ x: 0, y: 0 }, { x: 200, y: 0 }, { x: 200, y: 200 }, { x: 0, y: 200 }]
    )
  end

  # Need a location
  location = Location.first(name: 'Test Facility', zone_id: zone.id) || Location.create(
    name: 'Test Facility',
    zone_id: zone.id,
    location_type: 'building',
    active: true
  )

  # Create the test room — deterministic, no weather variability
  room = Room.create(
    location_id: location.id,
    name: TEST_ROOM_NAME,
    short_description: TEST_ROOM_DESC,
    long_description: TEST_ROOM_DESC,
    room_type: 'standard',
    active: true,
    indoors: true,
    weather_visible: false,
    min_x: 0.0, max_x: 100.0,
    min_y: 0.0, max_y: 100.0,
    min_z: 0.0, max_z: 10.0
  )

  # Add a known place (furniture) for deterministic 'places' output
  Place.create(
    room_id: room.id,
    name: 'a simple wooden chair',
    capacity: 1,
    invisible: false,
    is_furniture: true
  )

  puts "  Created test room: #{room.name} (id: #{room.id})"
  room
end

def create_multi_test_agents(agent_count: DEFAULT_AGENT_COUNT, force_new_tokens: false)
  agent_count = [agent_count, AGENT_NAMES.length].min

  puts "Creating #{agent_count} test agents for multi-agent testing..."
  puts "=" * 60

  # Check prerequisites
  reality = Reality.first(reality_type: 'primary') || Reality.first
  raise "No reality found - run seeds first" unless reality

  room = Room.tutorial_spawn_room
  raise "No rooms found - create world first" unless room

  # Create or find the dedicated test room
  test_room = find_or_create_test_room(reality)
  puts "Test room: #{test_room.name} (id: #{test_room.id})"

  # Load existing tokens if not forcing regeneration
  existing_tokens = {}
  if !force_new_tokens && File.exist?(TOKENS_FILE)
    begin
      data = JSON.parse(File.read(TOKENS_FILE))
      data.each { |agent| existing_tokens[agent['username']] = agent['token'] }
      puts "Loaded #{existing_tokens.size} existing tokens"
    rescue JSON::ParserError
      puts "Could not parse existing tokens file, will regenerate"
    end
  end

  agents = []

  DB.transaction do
    agent_count.times do |i|
      agent_name = AGENT_NAMES[i]
      username = "test_agent_#{agent_name.downcase}"
      email = "#{username}@firefly.local"

      puts "\n--- Agent #{i}: #{agent_name} ---"

      # Find or create user
      user = User.first(username: username) || User.first(email: email)
      if user
        puts "  User exists: #{user.username} (id: #{user.id})"
      else
        user = User.new(username: username, email: email)
        user.set_password(SecureRandom.hex(16))
        user.save
        puts "  Created user: #{username} (id: #{user.id})"
      end

      # Ensure admin for testing
      unless user.admin?
        user.update(is_admin: true)
        puts "  Granted admin privileges"
      end

      # Check for existing valid token
      token = nil
      if existing_tokens[username]
        existing_token = existing_tokens[username]
        if user.api_token_valid?(existing_token)
          puts "  Existing token still valid"
          token = existing_token
        else
          puts "  Existing token expired, generating new"
        end
      end

      # Generate new token if needed
      if token.nil?
        token = user.generate_api_token!
        puts "  Generated new API token"
      end

      # Find or create character
      character = Character.first(user_id: user.id)
      unless character
        # Check for duplicate name before creating
        existing = Character.first(forename: 'Agent', surname: agent_name)
        if existing && existing.user_id != user.id
          raise "Character 'Agent #{agent_name}' already exists (owned by user #{existing.user_id}). Cannot create duplicate."
        end

        character = Character.create(
          user_id: user.id,
          forename: "Agent",
          surname: agent_name,
          short_desc: "Test agent #{agent_name} for multi-agent testing",
          active: true,
          is_npc: false
        )
        puts "  Created character: #{character.full_name} (id: #{character.id})"
      end

      # Find or create instance - place agents in same room for combat testing
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
        puts "  Created instance in: #{room.name}"
      end

      # Assign abilities if they exist
      abilities = Ability.all
      if abilities.any?
        before_count = instance.ability_service.character_abilities.count
        instance.ability_service.assign_all(abilities)
        assigned = instance.ability_service.character_abilities.count - before_count
        puts "  Assigned #{assigned} new abilities (#{abilities.count} total)" if assigned > 0
      end

      agents << {
        agent_id: i,
        username: username,
        character_name: character.full_name,
        character_id: character.id,
        instance_id: instance.id,
        room_id: room.id,
        token: token
      }
    end
  end

  # Write tokens + test room config
  config = {
    test_room_id: test_room.id,
    test_room_name: test_room.name,
    agents: agents
  }
  FileUtils.mkdir_p(File.dirname(TOKENS_FILE))
  File.write(TOKENS_FILE, JSON.pretty_generate(config))
  puts "\n" + "=" * 60
  puts "MULTI-AGENT SETUP COMPLETE"
  puts "=" * 60
  puts "\nConfig written to: #{TOKENS_FILE}"
  puts "\nAgents created:"
  agents.each do |agent|
    puts "  #{agent[:agent_id]}: #{agent[:character_name]} (#{agent[:username]})"
  end
  puts "\nSpawn room: #{room.name}"
  puts "Test room: #{test_room.name} (id: #{test_room.id})"
  puts "\nThe MCP orchestrator will automatically load these tokens."
  puts "Run: mcp__firefly-test__test_feature with agent_count=#{agent_count}"
  puts "=" * 60

  agents
rescue StandardError => e
  puts "ERROR: #{e.message}"
  puts e.backtrace.first(5).join("\n")
  raise
end

if __FILE__ == $0
  force = ARGV.include?('--force') || ARGV.include?('-f')
  count = ARGV.find { |a| a.match?(/^\d+$/) }&.to_i || DEFAULT_AGENT_COUNT
  create_multi_test_agents(agent_count: count, force_new_tokens: force)
end
