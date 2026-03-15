#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../app'

# Process all ready timed actions in a loop until done
ci = CharacterInstance.first
max_iterations = 20
iterations = 0

puts "Starting position: #{ci.current_room.name}"
puts "Destination: #{ci.final_destination_id ? Room[ci.final_destination_id].name : 'none'}"
puts ""

while ci.movement_state == 'moving' && iterations < max_iterations
  iterations += 1

  # Wait for action to be ready
  sleep(0.1)

  ready = TimedAction.ready_to_complete
  if ready.empty?
    puts "Waiting for actions... (iteration #{iterations})"
    sleep(0.5)
    next
  end

  ready.each do |action|
    puts "Processing action: #{action.id} - #{action.action_name}"
    result = action.finish!
    puts "  Result: #{result ? 'completed' : 'failed'}"
  end

  ci.refresh
  puts "  Now at: #{ci.current_room.name}"
end

puts ""
ci.refresh
puts "Final position: #{ci.current_room.name}"
puts "Movement state: #{ci.movement_state}"
puts "Iterations: #{iterations}"
