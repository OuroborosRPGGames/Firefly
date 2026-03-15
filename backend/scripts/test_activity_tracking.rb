#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../app'

puts "=== Testing Activity Tracking System ==="
puts

# Create a test profile
char = Character.first
puts "Testing with character: #{char.full_name}"

profile = ActivityProfile.for_character(char)
puts "Profile created: #{profile.id}"

# Record some samples
5.times do |i|
  profile.record_sample!(weight: 0.8)
  puts "Sample #{i + 1} recorded"
end

# Check profile data
puts
puts "Total samples: #{profile.reload.total_samples || 0}"
puts "Buckets: #{profile.parsed_buckets.keys.first(3).inspect}"

# Test service methods
puts
puts "Service format_hour test:"
puts "  14:00 -> #{ActivityTrackingService.format_hour(14)}"
puts "  00:00 -> #{ActivityTrackingService.format_hour(0)}"
puts "  12:00 -> #{ActivityTrackingService.format_hour(12)}"

# Test with a second character for overlap
char2 = Character.offset(1).first
if char2
  puts
  puts "Testing overlap with: #{char2.full_name}"

  profile2 = ActivityProfile.for_character(char2)
  5.times { profile2.record_sample!(weight: 0.9) }

  result = ActivityTrackingService.calculate_overlap(char, char2)
  puts "Overlap result: #{result.inspect}"
end

puts
puts "=== Activity Tracking System Test Complete ==="
