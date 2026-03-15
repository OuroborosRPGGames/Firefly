#!/usr/bin/env ruby
# frozen_string_literal: true

# Full Game Setup Script
# Runs all setup scripts in the correct order to initialize the game.
# This script is idempotent - safe to run multiple times.

require 'bundler/setup'
require 'dotenv/load'

# Load full app (includes all models and helpers)
require_relative '../app'

puts '=' * 60
puts 'FIREFLY GAME SETUP'
puts '=' * 60
puts ''
puts 'This script will set up:'
puts '  1. Tutorial Universe (newbie school + mall)'
puts '  2. Tutorial Shops (with pattern inventory)'
puts '  3. Test Universe (navigation testing grid)'
puts ''
puts 'All scripts are idempotent - safe to run multiple times.'
puts ''

start_time = Time.now

# Run setup scripts in order
scripts = [
  'setup/import_patterns.rb',
  'setup/tutorial_universe.rb',
  'setup/tutorial_shops.rb',
  'setup/test_universe.rb'
]

scripts.each_with_index do |script, index|
  puts '-' * 60
  puts "Running #{index + 1}/#{scripts.length}: #{script}"
  puts '-' * 60
  puts ''

  script_path = File.join(__dir__, script)
  if File.exist?(script_path)
    load script_path
  else
    puts "WARNING: Script not found: #{script_path}"
  end

  puts ''
end

# Final summary
puts '=' * 60
puts 'SETUP COMPLETE'
puts '=' * 60
puts ''

# Count entities
universes = DB[:universes].where(name: %w[Tutorial Test]).count
worlds = DB[:worlds].count
areas = DB[:areas].count
locations = DB[:locations].count
rooms = DB[:rooms].count
exits = DB[:room_exits].count
shops = DB[:shops].where(free_items: true).count
shop_items = DB[:shop_items].count
tutorial_spawn_id = GameSetting.integer('tutorial_spawn_room_id')

puts 'Summary:'
puts "  Universes: #{universes} (Tutorial + Test)"
puts "  Worlds: #{worlds}"
puts "  Areas: #{areas}"
puts "  Locations: #{locations}"
puts "  Rooms: #{rooms}"
puts "  Exits: #{exits}"
puts "  Free Shops: #{shops}"
puts "  Shop Items: #{shop_items}"
puts "  Tutorial Spawn Room ID: #{tutorial_spawn_id || 'Not set'}"
puts ''

# Verify spawn room
if tutorial_spawn_id
  spawn_room = DB[:rooms].first(id: tutorial_spawn_id)
  if spawn_room
    puts "Tutorial Spawn Point: #{spawn_room[:name]} (ID: #{spawn_room[:id]})"
  else
    puts "WARNING: tutorial_spawn_room_id is #{tutorial_spawn_id} but room not found!"
  end
else
  puts 'WARNING: No tutorial spawn room configured!'
  puts '  New characters may not spawn correctly.'
end

elapsed = Time.now - start_time
puts ''
puts "Completed in #{elapsed.round(2)} seconds."
