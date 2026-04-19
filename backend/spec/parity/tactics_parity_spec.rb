# frozen_string_literal: true

# Tactic parity spec: verifies that aggressive/defensive/quick tactic_choice
# produces identical Ruby and Rust event streams.
# Run: COMBAT_ENGINE_FORMAT=json bundle exec rspec spec/parity/tactics_parity_spec.rb --format documentation

require 'spec_helper'
require_relative 'parity_helpers'

RSpec.describe 'Tactics Parity', :parity do
  include ParityHelpers

  before(:all) do
    unless rust_engine_available?
      skip 'Rust combat-server not running'
    end
  end

  # Apply tactic_choice values from scenario[:participants] to the already-created
  # fight participants (parity_helpers doesn't pass tactic_choice through FactoryBot).
  def apply_tactics(fight, scenario)
    sorted_fps = fight.fight_participants.sort_by(&:id)
    scenario[:participants].each_with_index do |pcfg, idx|
      fp = sorted_fps[idx]
      next unless fp && pcfg[:tactic_choice]

      fp.update(tactic_choice: pcfg[:tactic_choice])
    end
    fight.reload
  end

  # Reset participant state and re-apply tactics so the Rust run sees the same setup.
  def reset_for_rust(fight, scenario)
    fight.reload
    sorted_fps = fight.fight_participants.sort_by(&:id)
    scenario[:participants].each_with_index do |pcfg, idx|
      fp = sorted_fps[idx]
      next unless fp

      fp.update(
        current_hp: pcfg[:hp],
        max_hp: pcfg[:hp],
        is_knocked_out: false,
        touch_count: 0,
        hex_x: pcfg[:hex_x],
        hex_y: pcfg[:hex_y],
        tactic_choice: pcfg[:tactic_choice]
      )
    end
    fight.reload
  end

  # Run one single-round parity comparison for a scenario with tactics applied.
  # Returns { mismatches:, ruby_len:, rust_len: }.
  def run_tactics_parity(scenario, seed)
    fight = create_parity_fight(scenario)
    apply_tactics(fight, scenario)

    round_seed = seed + 1 * 7919 + 3571

    # --- Ruby run ---
    ruby_events = nil
    DeterministicRng.with_seed(round_seed) do
      service = CombatResolutionService.new(fight)
      result = service.resolve!
      result = { events: result } if result.is_a?(Array)
      ruby_events = (result[:events] || []).select { |e| %w[hit miss].include?(e[:event_type].to_s) }
    end

    # --- Reset for Rust ---
    reset_for_rust(fight, scenario)

    # --- Rust run ---
    serializer = Combat::FightStateSerializer.new(fight)
    client = CombatEngineClient.new
    rust_result = client.resolve_round(
      serializer.serialize,
      serializer.serialize_actions,
      seed: round_seed
    )
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

    puts "    Event count: ruby=#{ruby_norm.length} rust=#{rust_events.length}" if ruby_norm.length != rust_events.length

    { mismatches: mismatches, max: max, ruby_len: ruby_norm.length, rust_len: rust_events.length }
  end

  it 'aggressive attacker vs defensive target (seed 0)' do
    scenario = {
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'towards_person',
          qi_dice: 1.0, tactic_choice: 'aggressive' },
        { side: 1, hp: 6, hex_x: 6, hex_y: 4, main_action: 'attack', movement_action: 'towards_person',
          qi_dice: 1.0, tactic_choice: 'defensive' }
      ]
    }

    result = run_tactics_parity(scenario, 0)
    expect(result[:mismatches]).to eq(0),
      "aggressive vs defensive seed=0: #{result[:mismatches]}/#{result[:max]} mismatches " \
      "(ruby=#{result[:ruby_len]} rust=#{result[:rust_len]} events)"
  end

  it 'quick tactic gets +2 movement budget (seed 0)' do
    # Participants are far apart so movement matters; quick tactic (+2 movement) should allow closer approach.
    # Both engines must produce identical movement + combat event sequences.
    scenario = {
      participants: [
        { side: 0, hp: 6, hex_x: 2, hex_y: 4, main_action: 'attack', movement_action: 'towards_person',
          qi_dice: 1.0, tactic_choice: 'quick' },
        { side: 1, hp: 6, hex_x: 10, hex_y: 4, main_action: 'attack', movement_action: 'towards_person',
          qi_dice: 1.0, tactic_choice: 'aggressive' }
      ]
    }

    fight = create_parity_fight(scenario)
    apply_tactics(fight, scenario)

    round_seed = 0 + 1 * 7919 + 3571

    ruby_events = nil
    DeterministicRng.with_seed(round_seed) do
      service = CombatResolutionService.new(fight)
      result = service.resolve!
      result = { events: result } if result.is_a?(Array)
      # Include movement events to verify quick tactic movement parity
      ruby_events = (result[:events] || []).select { |e|
        %w[hit miss moved].include?(e[:event_type].to_s)
      }
    end

    reset_for_rust(fight, scenario)

    serializer = Combat::FightStateSerializer.new(fight)
    client = CombatEngineClient.new
    rust_result = client.resolve_round(
      serializer.serialize,
      serializer.serialize_actions,
      seed: round_seed
    )
    rust_events = (rust_result['events'] || []).select { |e|
      e.is_a?(Hash) && (e.key?('AttackHit') || e.key?('AttackMiss') || e.key?('Moved'))
    }.map { |e|
      if e.key?('AttackHit')
        { type: 'hit', segment: e['AttackHit']['segment'] }
      elsif e.key?('AttackMiss')
        { type: 'miss', segment: e['AttackMiss']['segment'] }
      else
        { type: 'moved', segment: e['Moved']['segment'] }
      end
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

    expect(mismatches).to eq(0),
      "quick vs aggressive seed=0: #{mismatches}/#{max} mismatches (ruby=#{ruby_norm.length} rust=#{rust_events.length} events)"
  end

  it 'defensive on both sides produces matching miss-heavy event stream (seed 0)' do
    # Both defensive means -2 outgoing and -2 incoming, so raw totals are suppressed.
    # The event sequence (hit/miss types and segments) must match between engines.
    scenario = {
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'stand_still',
          qi_dice: 1.0, tactic_choice: 'defensive' },
        { side: 1, hp: 6, hex_x: 4, hex_y: 8, main_action: 'attack', movement_action: 'stand_still',
          qi_dice: 1.0, tactic_choice: 'defensive' }
      ]
    }

    result = run_tactics_parity(scenario, 0)
    expect(result[:mismatches]).to eq(0),
      "defensive vs defensive seed=0: #{result[:mismatches]}/#{result[:max]} mismatches " \
      "(ruby=#{result[:ruby_len]} rust=#{result[:rust_len]} events)"
  end

  it 'mixed tactics 2v2 (seed 0)' do
    # Each participant on a 2v2 uses a different tactic, exercising all four tactic paths.
    # (quick is assigned to a second side-1 participant so all three non-default tactics appear.)
    scenario = {
      participants: [
        { side: 0, hp: 6, hex_x: 2, hex_y: 4, main_action: 'attack', movement_action: 'towards_person',
          qi_dice: 1.0, tactic_choice: 'aggressive' },
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'towards_person',
          qi_dice: 1.0, tactic_choice: 'defensive' },
        { side: 1, hp: 6, hex_x: 6, hex_y: 4, main_action: 'attack', movement_action: 'towards_person',
          qi_dice: 1.0, tactic_choice: 'quick' },
        { side: 1, hp: 6, hex_x: 8, hex_y: 4, main_action: 'attack', movement_action: 'towards_person',
          qi_dice: 1.0, tactic_choice: 'defensive' }
      ]
    }

    result = run_tactics_parity(scenario, 0)
    expect(result[:mismatches]).to eq(0),
      "mixed tactics 2v2 seed=0: #{result[:mismatches]}/#{result[:max]} mismatches " \
      "(ruby=#{result[:ruby_len]} rust=#{result[:rust_len]} events)"
  end

  it 'aggressive vs quick combo (seed 1)' do
    # Seed 1 variant: aggressive attacker vs quick defender.
    # quick takes +1 incoming damage but gets the movement bonus.
    scenario = {
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'towards_person',
          qi_dice: 1.0, tactic_choice: 'aggressive' },
        { side: 1, hp: 6, hex_x: 8, hex_y: 4, main_action: 'attack', movement_action: 'towards_person',
          qi_dice: 1.0, tactic_choice: 'quick' }
      ]
    }

    result = run_tactics_parity(scenario, 1)
    expect(result[:mismatches]).to eq(0),
      "aggressive vs quick seed=1: #{result[:mismatches]}/#{result[:max]} mismatches " \
      "(ruby=#{result[:ruby_len]} rust=#{result[:rust_len]} events)"
  end
end
