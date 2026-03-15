#!/usr/bin/env ruby
# frozen_string_literal: true

# Quick script to test BattleMapTestGalleryService.generate_image
# Usage: cd backend && bundle exec ruby scripts/test_gallery_generate.rb [config_index]

$stdout.sync = true
$stderr.sync = true

puts "Loading bundler..."
require 'bundler/setup'
require 'dotenv/load'
require 'sequel'
require 'json'

puts "Connecting to database..."
DB = Sequel.connect(ENV['DATABASE_URL'])
DB.extension :pg_json

puts "Loading game config..."
require_relative '../config/game_config'
require_relative '../config/game_prompts'

puts "Loading helpers..."
Dir[File.join(__dir__, '../app/helpers/*.rb')].each { |f| require f }

puts "Loading models..."
Dir[File.join(__dir__, '../app/models/concerns/*.rb')].each { |f| require f }
Dir[File.join(__dir__, '../app/models/*.rb')].each { |f| require f }

puts "Loading services..."
Dir[File.join(__dir__, '../app/services/concerns/*.rb')].each { |f| require f }
Dir[File.join(__dir__, '../app/services/**/*.rb')].each { |f| require f }

puts "Boot complete."

index = (ARGV[0] || 8).to_i
puts "Generating test image for config index #{index}..."
config = BattleMapTestGalleryService::TEST_CONFIGS[index]
puts "Config: #{config}"

if config.nil?
  puts "ERROR: Invalid config index #{index}"
  exit 1
end

service = BattleMapTestGalleryService.new
puts "Calling generate_image(#{index})..."
result = service.generate_image(index)

puts "\nResult:"
result.each { |k, v| puts "  #{k}: #{v.to_s[0..200]}" }
