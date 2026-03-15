# frozen_string_literal: true

# Test script for combat narrative generation
# Tests name alternation, weapon descriptions, and varied prose output
# Simulates combat events directly to avoid complex service dependencies

require_relative '../config/application'

# Explicitly require narrative services
require_relative '../app/services/combat_narrative_service'
require_relative '../app/services/combat_name_alternation_service'
require_relative '../app/services/combat_wound_description_service'

# Helper module for building events
module EventBuilder
  def self.hit(segment, actor, target, damage)
    {
      segment: segment,
      actor_id: actor.id,
      actor_name: actor.character_instance.character.full_name,
      target_id: target.id,
      target_name: target.character_instance.character.full_name,
      event_type: 'hit',
      round: 1,
      details: {
        weapon_type: 'unarmed',
        effective_damage: damage,
        total: 15
      }
    }
  end

  def self.miss(segment, actor, target)
    {
      segment: segment,
      actor_id: actor.id,
      actor_name: actor.character_instance.character.full_name,
      target_id: target.id,
      target_name: target.character_instance.character.full_name,
      event_type: 'miss',
      round: 1,
      details: { weapon_type: 'unarmed', total: 5 }
    }
  end

  def self.move(segment, actor, direction, target = nil)
    {
      segment: segment,
      actor_id: actor.id,
      actor_name: actor.character_instance.character.full_name,
      target_id: nil,
      target_name: nil,
      event_type: 'move',
      round: 1,
      details: {
        direction: direction,
        target_name: target&.character_instance&.character&.full_name
      }
    }
  end
end

def run_combat_test
  # Use existing data
  reality = Reality.first(reality_type: 'primary')
  room = Room.first(safe_room: false) || Room.first

  # Find existing agent characters
  alpha = Character.first(forename: 'Alpha')
  beta = Character.first(forename: 'Beta')
  gamma = Character.first(forename: 'Gamma')

  user = User.first(is_admin: true) || User.first

  unless alpha && beta && gamma
    puts 'Missing test characters. Creating them...'

    alpha ||= Character.create(
      user_id: user.id,
      forename: 'Alpha',
      surname: 'Fighter',
      gender: 'male',
      height_cm: 190,
      body_type: 'muscular',
      eye_color: 'blue',
      hair_color: 'black',
      active: true
    )

    beta ||= Character.create(
      user_id: user.id,
      forename: 'Beta',
      surname: 'Assassin',
      gender: 'female',
      height_cm: 160,
      body_type: 'slim',
      eye_color: 'green',
      hair_color: 'red',
      active: true
    )

    gamma ||= Character.create(
      user_id: user.id,
      forename: 'Gamma',
      surname: 'Tank',
      gender: 'male',
      height_cm: 200,
      body_type: 'heavy',
      eye_color: 'brown',
      hair_color: 'blonde',
      active: true
    )
  end

  # Ensure characters have appearance data for name alternation
  [
    [alpha, { gender: 'male', height_cm: 190, body_type: 'muscular', eye_color: 'blue', hair_color: 'black' }],
    [beta, { gender: 'female', height_cm: 160, body_type: 'slim', eye_color: 'green', hair_color: 'red' }],
    [gamma, { gender: 'male', height_cm: 200, body_type: 'heavy', eye_color: 'brown', hair_color: 'blonde' }]
  ].each do |char, attrs|
    attrs.each do |key, value|
      char.update(key => value) if char.respond_to?(key) && char.send(key).nil?
    end
  end

  puts 'Characters:'
  [alpha, beta, gamma].each do |c|
    puts "  #{c.full_name} - #{c.gender || '?'}, #{c.height_cm || '?'}cm, #{c.eye_color || '?'} eyes"
  end

  # Get or create instances
  instances = [alpha, beta, gamma].map do |char|
    inst = CharacterInstance.first(character_id: char.id, reality_id: reality.id)
    unless inst
      inst = CharacterInstance.create(
        character_id: char.id,
        reality_id: reality.id,
        current_room_id: room.id,
        status: 'alive',
        health: 100,
        max_health: 100,
        online: true
      )
    else
      inst.update(health: 100, max_health: 100, online: true, current_room_id: room.id)
    end
    inst
  end

  puts "\nInstances ready in room: #{room.name}"

  # Clean up old fights
  Fight.exclude(status: 'complete').update(status: 'complete')

  puts "\n#{'=' * 70}"
  puts 'THREE-WAY COMBAT NARRATIVE TEST'
  puts '=' * 70
  puts 'Testing name alternation, weapon descriptions, and varied prose'
  puts '=' * 70

  # Create fight
  fight = Fight.create(
    room_id: room.id,
    status: 'input',
    round_number: 0,
    round_events: Sequel.pg_json([])
  )

  # Create participants
  participants = instances.map do |inst|
    FightParticipant.create(
      fight_id: fight.id,
      character_instance_id: inst.id,
      current_hp: 100,
      max_hp: 100,
      input_stage: 'main_menu',
      input_complete: false,
      hex_x: rand(0..10),
      hex_y: rand(0..10)
    )
  end

  puts "\nFight #{fight.id}:"
  participants.each do |p|
    char_name = p.character_instance&.character&.full_name || "Participant #{p.id}"
    puts "  #{char_name} (unarmed)"
  end

  # Define test scenarios with simulated combat events
  scenarios = [
    {
      name: 'Round 1: Three-way Melee',
      events: lambda do |parts|
        [
          # Alpha attacks Beta - hits twice, misses once
          EventBuilder.hit(1, parts[0], parts[1], 4),
          EventBuilder.hit(2, parts[0], parts[1], 4),
          EventBuilder.miss(3, parts[0], parts[1]),
          # Beta attacks Gamma - hits once, misses twice
          EventBuilder.hit(4, parts[1], parts[2], 5),
          EventBuilder.miss(5, parts[1], parts[2]),
          EventBuilder.miss(6, parts[1], parts[2]),
          # Gamma attacks Alpha - hits three times
          EventBuilder.hit(7, parts[2], parts[0], 5),
          EventBuilder.hit(8, parts[2], parts[0], 5),
          EventBuilder.hit(9, parts[2], parts[0], 5),
          # Movement
          EventBuilder.move(10, parts[0], 'towards', parts[1]),
          EventBuilder.move(11, parts[1], 'towards', parts[2])
        ]
      end
    },
    {
      name: 'Round 2: Defense and Retreat',
      events: lambda do |parts|
        [
          # Alpha attacks Beta - four hits, one miss
          EventBuilder.hit(1, parts[0], parts[1], 3),
          EventBuilder.hit(2, parts[0], parts[1], 3),
          EventBuilder.hit(3, parts[0], parts[1], 3),
          EventBuilder.hit(4, parts[0], parts[1], 3),
          EventBuilder.miss(5, parts[0], parts[1]),
          # Gamma attacks Alpha - five hits
          EventBuilder.hit(6, parts[2], parts[0], 4),
          EventBuilder.hit(7, parts[2], parts[0], 4),
          EventBuilder.hit(8, parts[2], parts[0], 4),
          EventBuilder.hit(9, parts[2], parts[0], 4),
          EventBuilder.hit(10, parts[2], parts[0], 4),
          # Beta retreats
          EventBuilder.move(11, parts[1], 'away', parts[0])
        ]
      end
    },
    {
      name: 'Round 3: Final Exchange',
      events: lambda do |parts|
        [
          # Alpha attacks Gamma - three hits, two misses
          EventBuilder.hit(1, parts[0], parts[2], 4),
          EventBuilder.hit(2, parts[0], parts[2], 3),
          EventBuilder.hit(3, parts[0], parts[2], 3),
          EventBuilder.miss(4, parts[0], parts[2]),
          EventBuilder.miss(5, parts[0], parts[2]),
          # Beta attacks Alpha - one precise hit
          EventBuilder.hit(6, parts[1], parts[0], 6),
          # Gamma attacks Beta - all misses
          EventBuilder.miss(7, parts[2], parts[1]),
          EventBuilder.miss(8, parts[2], parts[1]),
          EventBuilder.miss(9, parts[2], parts[1]),
          # All advance
          EventBuilder.move(10, parts[0], 'towards', parts[2]),
          EventBuilder.move(11, parts[1], 'towards', parts[0]),
          EventBuilder.move(12, parts[2], 'stand_still')
        ]
      end
    }
  ]

  # Track cumulative damage for health display
  damage_tracker = Hash.new(0)

  scenarios.each do |scenario|
    fight.update(round_number: fight.round_number + 1)

    puts "\n#{'-' * 70}"
    puts scenario[:name]
    puts '-' * 70

    # Generate events for this round
    events = scenario[:events].call(participants)

    # Store events in fight
    fight.update(round_events: Sequel.pg_json(events))
    fight.reload

    begin
      # Generate narrative (service reads from fight.round_events)
      narrative = CombatNarrativeService.new(fight).generate

      puts "\n#{narrative}"

      # Update damage tracker (events use :event_type and :details[:effective_damage])
      events.select { |e| e[:event_type] == 'hit' }.each do |event|
        damage_tracker[event[:target_id]] += (event.dig(:details, :effective_damage) || 0)
      end

      # Health bars
      puts "\nHealth:"
      participants.each do |p|
        p.reload
        max = p.max_hp || 100
        hp = [max - damage_tracker[p.id], 0].max
        pct = (hp.to_f / max * 20).round
        bar = ('▓' * pct) + ('░' * (20 - pct))
        name = p.character_instance&.character&.full_name || "Participant #{p.id}"
        puts "  #{name.ljust(18)} [#{bar}] #{hp.to_s.rjust(3)}/#{max}"
      end
    rescue StandardError => e
      puts "\nERROR: #{e.class}: #{e.message}"
      puts e.backtrace.first(8).join("\n")
      break
    end
  end

  # Cleanup
  puts "\n#{'=' * 70}"
  puts 'TEST COMPLETE'
  puts '=' * 70
  fight.update(status: 'complete')
end

run_combat_test if __FILE__ == $PROGRAM_NAME
