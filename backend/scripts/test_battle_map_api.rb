# frozen_string_literal: true

require_relative '../app'
require 'json'
require 'net/http'
require 'uri'

# Get the first user with an API token
user = User.order(:id).first
puts "User: #{user&.username || 'none'}"
puts "Has token: #{user&.api_token ? 'yes' : 'no'}"

exit unless user&.api_token

# Test /api/fight/status
uri = URI('http://localhost:3000/api/fight/status')
http = Net::HTTP.new(uri.host, uri.port)
request = Net::HTTP::Get.new(uri)
request['Authorization'] = "Bearer #{user.api_token}"

response = http.request(request)
data = JSON.parse(response.body)

puts "\n=== Fight Status ==="
puts "HTTP: #{response.code}"
puts "Success: #{data['success']}"
puts "In Combat: #{data['in_combat']}"
puts "Fight ID: #{data['fight_id']}" if data['fight_id']

# Test /api/fight/battle_map if in combat
if data['in_combat']
  uri = URI('http://localhost:3000/api/fight/battle_map')
  request = Net::HTTP::Get.new(uri)
  request['Authorization'] = "Bearer #{user.api_token}"

  response = http.request(request)
  map_data = JSON.parse(response.body)

  puts "\n=== Battle Map ==="
  puts "HTTP: #{response.code}"
  puts "Success: #{map_data['success']}"

  if map_data['success']
    puts "Fight ID: #{map_data['fight_id']}"
    puts "Arena: #{map_data['arena_width']}x#{map_data['arena_height']}"
    puts "Hex Scale: #{map_data['hex_scale']}px"
    puts "Hexes: #{map_data['hexes']&.length}"
    puts "Participants: #{map_data['participants']&.length}"

    map_data['participants']&.each do |p|
      puts "  - #{p['name']} at (#{p['hex_x']},#{p['hex_y']}) [#{p['relationship']}]"
    end
  else
    puts "Error: #{map_data['error']}"
  end
else
  puts "Not in combat - battle map not available"
end
