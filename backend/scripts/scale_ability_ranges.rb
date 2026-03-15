# frozen_string_literal: true

require 'sequel'
require_relative '../config/database'

# Connect to database
DB = FireflyDatabase.connect

# Define Ability model inline to avoid loading full app
class Ability < Sequel::Model
end

puts "Scaling ability ranges by 1.5x..."
puts "Note: This script scales aoe_radius and aoe_length fields."
puts "      Abilities calculate range dynamically from these fields.\n\n"

# Scale line/cone AoE lengths (these represent range for line/cone abilities)
line_cone_count = 0
Ability.where(aoe_shape: %w[line cone]).exclude(aoe_length: nil).exclude(aoe_length: 0).each do |ability|
  old_length = ability.aoe_length
  new_length = (old_length * 1.5).ceil
  ability.update(aoe_length: new_length)
  line_cone_count += 1
  puts "  #{ability.name} (#{ability.aoe_shape}): length #{old_length} → #{new_length}"
end

# Scale circle AoE radii (these represent range for circle AoE abilities)
circle_count = 0
Ability.where(aoe_shape: 'circle').exclude(aoe_radius: nil).exclude(aoe_radius: 0).each do |ability|
  old_radius = ability.aoe_radius
  new_radius = (old_radius * 1.5).ceil
  ability.update(aoe_radius: new_radius)
  circle_count += 1
  puts "  #{ability.name} (circle): radius #{old_radius} → #{new_radius}"
end

# Note: Single-target abilities use DEFAULT_RANGE_HEXES from GameConfig,
# which has already been updated to 8 hexes in Phase 1.
# Self-targeted abilities always return 0 range, which is correct.

puts "\nScaling complete:"
puts "  Line/cone abilities updated: #{line_cone_count}"
puts "  Circle AoE abilities updated: #{circle_count}"
puts "  (Single-target abilities use DEFAULT_RANGE_HEXES=8 from GameConfig)"
