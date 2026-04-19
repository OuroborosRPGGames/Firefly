#!/usr/bin/env ruby
# frozen_string_literal: true

# End-to-end smoke test: resolve a combat round through FightService with
# Rust combat engine enabled (auto mode + live combat-server socket).

require_relative '../config/application'

puts "=== Rust Combat Engine Smoke Test ==="
puts "Engine mode:    #{FightService.combat_engine_mode}"
puts "Socket ready:   #{CombatEngineClient.available?}"
puts "Rust active?:   #{FightService.rust_engine_active?}"

raise 'combat-server not reachable' unless CombatEngineClient.available?

# Build a throwaway fight with two PCs via factories (this uses the same
# wiring real gameplay uses; no Rust-specific helpers).
require 'factory_bot'
Dir[File.expand_path('../spec/factories/**/*.rb', __dir__)].each { |f| require f }
FactoryBot.reload

room = FactoryBot.create(:room)
fight = FactoryBot.create(:fight, room: room, status: 'input', round_number: 1,
                                    mode: 'normal', arena_width: 20, arena_height: 20)

[0, 1].each do |side|
  ci = FactoryBot.create(:character_instance, current_room: room, health: 6, max_health: 6)
  FactoryBot.create(:fight_participant,
    fight: fight,
    character_instance: ci,
    side: side,
    current_hp: 6, max_hp: 6,
    hex_x: side * 3, hex_y: 0,
    input_complete: true,
    main_action: 'attack',
    movement_action: side.zero? ? 'towards_person' : 'stand_still',
    target_hex_x: (1 - side) * 3, target_hex_y: 0,
    qi_dice: 1.0
  )
end

ENV['COMBAT_ENGINE'] = 'auto'
svc = FightService.new(fight)
started = Time.now
result = svc.resolve_round!
elapsed_ms = ((Time.now - started) * 1000).round

puts "\n=== Result ==="
puts "Elapsed:         #{elapsed_ms} ms"
puts "Fight status:    #{fight.reload.status}"
puts "Events:          #{(result[:events] || []).size}"
puts "Errors:          #{(result[:errors] || []).size}"
(result[:errors] || []).each { |e| puts "  - #{e[:step]}: #{e[:error_class]}: #{e[:message]}" }

fight.fight_participants.each do |p|
  puts "  p#{p.id} side=#{p.side} hp=#{p.current_hp} pos=(#{p.hex_x},#{p.hex_y}) ko=#{p.is_knocked_out}"
end

puts "\nPASS: Rust engine resolved round without errors" if (result[:errors] || []).empty?
