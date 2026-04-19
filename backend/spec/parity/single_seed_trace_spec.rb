# frozen_string_literal: true

# Single-seed event-by-event trace comparison.
# Run: COMBAT_ENGINE_FORMAT=json bundle exec rspec spec/parity/single_seed_trace_spec.rb --format documentation

require 'spec_helper'
require_relative 'parity_helpers'

RSpec.describe 'Single Seed Trace', :parity do
  include ParityHelpers

  before(:all) do
    unless rust_engine_available?
      skip 'Rust combat-server not running'
    end
  end

  let(:scenario) do
    {
      name: '1v1_stand_still',
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'stand_still', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 4, hex_y: 8, main_action: 'attack', movement_action: 'stand_still', qi_dice: 1.0 }
      ]
    }
  end

  it 'produces identical events for seed 0' do
    fight = create_parity_fight(scenario)
    seed = 0

    puts "\n  Fight #{fight.id} with #{fight.fight_participants.count} participants:"
    fight.fight_participants.sort_by(&:id).each do |fp|
      puts "    p#{fp.id} side=#{fp.side} hp=#{fp.current_hp}/#{fp.max_hp} pos=(#{fp.hex_x},#{fp.hex_y}) " \
           "action=#{fp.main_action} move=#{fp.movement_action} target=#{fp.target_participant_id}"
    end

    # --- Ruby ---
    round_seed = seed + 1 * 7919 + 3571
    ruby_events = nil
    ruby_trace = nil

    DeterministicRng.with_seed_traced(round_seed) do |_rng, trace_log|
      service = CombatResolutionService.new(fight)
      result = service.resolve!
      result = { events: result } if result.is_a?(Array)
      ruby_events = result[:events] || []
      ruby_trace = trace_log.dup
    end

    # Print Ruby RNG trace
    puts "\n  --- RUBY RNG trace (#{ruby_trace.length} calls) ---"
    ruby_trace.first(50).each do |t|
      puts "    [#{t[:seq]}] #{t[:label]} arg=#{t[:arg]} => #{t[:value]}"
    end

    # Print Ruby combat events
    ruby_combat = ruby_events.select { |e| %w[hit miss damage_applied knockout].include?(e[:event_type].to_s) }
    puts "\n  --- RUBY events (#{ruby_combat.length} combat / #{ruby_events.length} total) ---"
    ruby_combat.each do |e|
      d = e[:details] || {}
      case e[:event_type].to_s
      when 'hit'
        puts "    HIT  seg=#{e[:segment]} p#{e[:actor_id]}->p#{e[:target_id]} " \
             "total=#{d[:total]} hp_lost=#{d[:hp_lost_this_attack]} " \
             "roll=#{d[:roll]} stat=#{d[:stat_mod]} wound=#{d[:wound_penalty]} " \
             "qi_atk=#{d[:qi_attack_bonus]} atk_count=#{d[:attack_count]}"
      when 'miss'
        puts "    MISS seg=#{e[:segment]} p#{e[:actor_id]}->p#{e[:target_id]} " \
             "total=#{d[:total]} roll=#{d[:roll]} stat=#{d[:stat_mod]} wound=#{d[:wound_penalty]} " \
             "atk_count=#{d[:attack_count]}"
      when 'damage_applied'
        puts "    DMG  seg=#{e[:segment]} p#{e[:target_id]} " \
             "cumul=#{d[:cumulative_damage]} eff=#{d[:effective_cumulative]} " \
             "hp_lost=#{d[:hp_lost]} armor=#{d[:armor_reduced]} qi_def=#{d[:qi_defense_reduced]}"
      when 'knockout'
        puts "    KO   p#{e[:target_id]}"
      end
    end

    # --- Reset fight state for Rust ---
    fight.reload
    fight.fight_participants.each do |fp|
      pcfg = scenario[:participants].find { |p| p[:side] == fp.side }
      fp.update(current_hp: pcfg[:hp], is_knocked_out: false, touch_count: 0)
    end

    # --- Rust ---
    serializer = Combat::FightStateSerializer.new(fight)
    state = serializer.serialize
    actions = serializer.serialize_actions

    client = CombatEngineClient.new
    rust_result = client.resolve_round(state, actions, seed: round_seed, trace_rng: true)
    rust_events = rust_result['events'] || []

    rust_rng = rust_events.select { |e| e.is_a?(Hash) && e.key?('RngTrace') }
    rust_combat = rust_events.select { |e| e.is_a?(Hash) && (e.key?('AttackHit') || e.key?('AttackMiss') || e.key?('KnockedOut')) }

    # Print Rust RNG trace
    puts "\n  --- RUST RNG trace (#{rust_rng.length} calls) ---"
    rust_rng.first(50).each do |e|
      d = e['RngTrace']
      puts "    [#{d['sequence']}] p#{d['participant_id']} #{d['label']} => #{d['value']}"
    end

    # Print Rust combat events
    puts "\n  --- RUST events (#{rust_combat.length} combat / #{rust_events.length} total) ---"
    rust_combat.each do |e|
      if e.key?('AttackHit')
        d = e['AttackHit']
        r = d['roll'] || {}
        def_d = d['defense'] || {}
        puts "    HIT  seg=#{d['segment']} p#{d['attacker_id']}->p#{d['target_id']} " \
             "raw=#{d['raw_damage']} damage=#{d['damage']} hp_lost=#{d['hp_lost']} " \
             "roll=#{r['base_roll']} stat=#{r['stat_mod']} wound=#{r['wound_penalty']} " \
             "qi_atk=#{r['qi_attack_bonus']} per_atk=#{r['per_attack_roll']} atk_count=#{r['attack_count']} " \
             "shield=#{def_d['shield_absorbed']} armor=#{def_d['armor_reduced']} qi_def=#{def_d['qi_defense_reduced']}"
      elsif e.key?('AttackMiss')
        d = e['AttackMiss']
        r = d['roll'] || {}
        puts "    MISS seg=#{d['segment']} p#{d['attacker_id']}->p#{d['target_id']} " \
             "raw=#{d['raw_damage']} damage=#{d['damage']} " \
             "roll=#{r['base_roll']} stat=#{r['stat_mod']} wound=#{r['wound_penalty']} " \
             "per_atk=#{r['per_attack_roll']} atk_count=#{r['attack_count']}"
      elsif e.key?('KnockedOut')
        d = e['KnockedOut']
        puts "    KO   p#{d['participant_id']} by=p#{d['by_id']}"
      end
    end

    # --- Compare ---
    puts "\n  --- COMPARISON ---"
    ruby_norm = ruby_combat.select { |e| %w[hit miss].include?(e[:event_type].to_s) }
    rust_norm = rust_combat.map do |e|
      if e.key?('AttackHit')
        { type: 'hit', raw: e['AttackHit']['raw_damage'], damage: e['AttackHit']['damage'],
          hp_lost: e['AttackHit']['hp_lost'], segment: e['AttackHit']['segment'] }
      elsif e.key?('AttackMiss')
        { type: 'miss', raw: e['AttackMiss']['raw_damage'], damage: e['AttackMiss']['damage'],
          segment: e['AttackMiss']['segment'] }
      end
    end.compact

    puts "    Ruby: #{ruby_norm.length} events, Rust: #{rust_norm.length} events"

    max = [ruby_norm.length, rust_norm.length].max
    mismatches = 0
    max.times do |i|
      r = ruby_norm[i]
      s = rust_norm[i]
      if r.nil?
        puts "    [#{i}] EXTRA RUST: #{s[:type]} seg=#{s[:segment]} raw=#{s[:raw]} dmg=#{s[:damage]}"
        mismatches += 1
      elsif s.nil?
        puts "    [#{i}] EXTRA RUBY: #{r[:event_type]} seg=#{r[:segment]} total=#{r.dig(:details, :total)}"
        mismatches += 1
      elsif r[:event_type].to_s != s[:type]
        puts "    [#{i}] TYPE MISMATCH: ruby=#{r[:event_type]} rust=#{s[:type]}"
        mismatches += 1
      else
        puts "    [#{i}] MATCH: #{s[:type]} seg=#{s[:segment]}"
      end
    end

    puts "    #{mismatches} mismatches out of #{max} events"
    expect(mismatches).to eq(0), "#{mismatches} event mismatches found"
  end

  # Quick multi-seed exact parity check across scenarios
  # All hex coordinates use valid offset positions:
  # y=4 (half_y=2, even) → x must be even; y=8 (half_y=4, even) → x even
  QUICK_SCENARIOS = {
    'stand_still' => {
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'stand_still', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 4, hex_y: 8, main_action: 'attack', movement_action: 'stand_still', qi_dice: 1.0 }
      ]
    },
    'melee_basic' => {
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 6, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 1.0 }
      ]
    },
    'defend' => {
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 6, hex_y: 4, main_action: 'defend', movement_action: 'stand_still', qi_dice: 1.0 }
      ]
    },
    'with_qi' => {
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 2.0, qi_attack: 1 },
        { side: 1, hp: 6, hex_x: 6, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 2.0, qi_defense: 1 }
      ]
    },
    'high_damage' => {
      participants: [
        { side: 0, hp: 8, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 1.0 },
        { side: 1, hp: 3, hex_x: 6, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 1.0 }
      ]
    },
    'spar' => {
      mode: 'spar',
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'stand_still', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 4, hex_y: 8, main_action: 'attack', movement_action: 'stand_still', qi_dice: 1.0 }
      ]
    },
    '2v2_adjacent' => {
      participants: [
        { side: 0, hp: 6, hex_x: 2, hex_y: 4, main_action: 'attack', movement_action: 'stand_still', qi_dice: 1.0 },
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'stand_still', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 2, hex_y: 8, main_action: 'attack', movement_action: 'stand_still', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 4, hex_y: 8, main_action: 'attack', movement_action: 'stand_still', qi_dice: 1.0 }
      ]
    },
    '2v2_movement' => {
      participants: [
        { side: 0, hp: 6, hex_x: 2, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 1.0 },
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 6, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 8, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 1.0 }
      ]
    },
  }.freeze

  QUICK_SCENARIOS.each do |scenario_name, scenario_def|
    context scenario_name do
      (0..4).each do |seed|
        it "seed #{seed} matches exactly" do
          fight = create_parity_fight(scenario_def)
          round_seed = seed + 1 * 7919 + 3571

          # Run Ruby
          ruby_events = nil
          DeterministicRng.with_seed(round_seed) do
            service = CombatResolutionService.new(fight)
            result = service.resolve!
            result = { events: result } if result.is_a?(Array)
            ruby_events = (result[:events] || []).select { |e| %w[hit miss].include?(e[:event_type].to_s) }
          end

          # Reset fight state for Rust run
          fight.reload
          sorted_fps = fight.fight_participants.sort_by(&:id)
          scenario_def[:participants].each_with_index do |pcfg, idx|
            fp = sorted_fps[idx]
            next unless fp
            fp.update(
              current_hp: pcfg[:hp],
              max_hp: pcfg[:hp],
              is_knocked_out: false,
              touch_count: 0,
              hex_x: pcfg[:hex_x],
              hex_y: pcfg[:hex_y]
            )
          end

          # Run Rust — serializer reads current DB state (which Ruby may have repositioned)
          serializer = Combat::FightStateSerializer.new(fight)
          client = CombatEngineClient.new
          rust_result = client.resolve_round(serializer.serialize, serializer.serialize_actions, seed: round_seed)
          rust_events = (rust_result['events'] || []).select { |e|
            e.is_a?(Hash) && (e.key?('AttackHit') || e.key?('AttackMiss'))
          }.map { |e|
            key = e.key?('AttackHit') ? 'AttackHit' : 'AttackMiss'
            { type: key == 'AttackHit' ? 'hit' : 'miss', segment: e[key]['segment'] }
          }

          ruby_norm = ruby_events.map { |e| { type: e[:event_type].to_s, segment: e[:segment] } }

          mismatches = 0
          max = [ruby_norm.length, rust_events.length].max
          max.times do |i|
            r = ruby_norm[i]
            s = rust_events[i]
            if r.nil? || s.nil? || r[:type] != s[:type] || r[:segment] != s[:segment]
              mismatches += 1
              puts "    [#{i}] MISMATCH: ruby=#{r&.inspect} rust=#{s&.inspect}" if mismatches <= 3
            end
          end

          if ruby_norm.length != rust_events.length
            puts "    Event count: ruby=#{ruby_norm.length} rust=#{rust_events.length}"
          end

          expect(mismatches).to eq(0),
            "#{scenario_name} seed=#{seed}: #{mismatches}/#{max} mismatches (ruby=#{ruby_norm.length} rust=#{rust_events.length} events)"
        end
      end
    end
  end
end
