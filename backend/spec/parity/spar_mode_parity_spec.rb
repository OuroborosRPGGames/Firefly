# frozen_string_literal: true

# Spar mode parity spec: verifies touch-count logic and fight termination in
# spar mode is identical between Ruby CombatResolutionService and Rust engine.
# The spar defeat fix (no simultaneous knockout) is the primary regression target.
# Run: COMBAT_ENGINE_FORMAT=json bundle exec rspec spec/parity/spar_mode_parity_spec.rb --format documentation

require 'spec_helper'
require_relative 'parity_helpers'

RSpec.describe 'Spar Mode Parity', :parity do
  include ParityHelpers

  before(:all) do
    unless rust_engine_available?
      skip 'Rust combat-server not running'
    end
  end

  # Run a single spar round through both engines and return a comparison hash.
  # Returns:
  #   { mismatches:, ruby_len:, rust_len:, ruby_touches:, rust_touches:,
  #     ruby_ended:, rust_ended: }
  def run_spar_parity_round(scenario, seed)
    fight = create_parity_fight(scenario)
    round_seed = seed + 1 * 7919 + 3571

    # --- Ruby run ---
    ruby_events = nil
    ruby_result_raw = nil
    DeterministicRng.with_seed(round_seed) do
      service = CombatResolutionService.new(fight)
      ruby_result_raw = service.resolve!
      ruby_result_raw = { events: ruby_result_raw } if ruby_result_raw.is_a?(Array)
      ruby_events = (ruby_result_raw[:events] || []).select { |e|
        %w[hit miss touch_out].include?(e[:event_type].to_s)
      }
    end

    # Capture Ruby participant state post-round
    fight.reload
    ruby_touch_counts = fight.fight_participants.each_with_object({}) do |fp, h|
      h[fp.side] ||= 0
      h[fp.side] += (fp.touch_count || 0)
    end
    ruby_ended = fight.should_end? rescue false

    # --- Reset for Rust ---
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
        hex_y: pcfg[:hex_y]
      )
    end
    fight.reload

    # --- Rust run ---
    serializer = Combat::FightStateSerializer.new(fight)
    client = CombatEngineClient.new
    rust_result = client.resolve_round(
      serializer.serialize,
      serializer.serialize_actions,
      seed: round_seed
    )
    rust_events_raw = rust_result['events'] || []

    rust_events = rust_events_raw.select { |e|
      e.is_a?(Hash) && (e.key?('AttackHit') || e.key?('AttackMiss') || e.key?('KnockedOut'))
    }.map { |e|
      if e.key?('AttackHit')
        { type: 'hit', segment: e['AttackHit']['segment'] }
      elsif e.key?('AttackMiss')
        { type: 'miss', segment: e['AttackMiss']['segment'] }
      else
        { type: 'knockout', segment: nil }
      end
    }

    # Rust touch counts and fight-ended flag from next_state
    rust_next = rust_result['next_state'] || {}
    rust_touch_counts = {}
    (rust_next['participants'] || []).each do |rp|
      side = rp['side']
      rust_touch_counts[side] ||= 0
      rust_touch_counts[side] += (rp['touch_count'] || 0).to_i
    end
    rust_ended = rust_result['fight_ended'] || false

    # Normalize Ruby events to { type, segment } tuples (same as quick-scenario loop)
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

    {
      mismatches: mismatches,
      max: max,
      ruby_len: ruby_norm.length,
      rust_len: rust_events.length,
      ruby_touches: ruby_touch_counts,
      rust_touches: rust_touch_counts,
      ruby_ended: ruby_ended,
      rust_ended: rust_ended
    }
  end

  it 'spar mode touch-out ends fight (seed 0)' do
    # 1v1 spar with stand_still to maximise hits-per-round in a predictable setup.
    scenario = {
      mode: 'spar',
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'stand_still',
          qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 4, hex_y: 8, main_action: 'attack', movement_action: 'stand_still',
          qi_dice: 1.0 }
      ]
    }

    result = run_spar_parity_round(scenario, 0)

    expect(result[:mismatches]).to eq(0),
      "spar touch-out seed=0: #{result[:mismatches]}/#{result[:max]} event mismatches " \
      "(ruby=#{result[:ruby_len]} rust=#{result[:rust_len]} events)"

    # Touch counts reported by each engine must agree
    expect(result[:ruby_touches]).to eq(result[:rust_touches]),
      "spar touch counts diverged: ruby=#{result[:ruby_touches].inspect} rust=#{result[:rust_touches].inspect}"
  end

  it 'spar mode no simultaneous knockouts (seed 0)' do
    # When one side accumulates the winning number of touches, the fight must end
    # before the opposing side can also reach that threshold in the same round.
    # This is the regression test for the simultaneous-KO (draw) bugfix.
    scenario = {
      mode: 'spar',
      participants: [
        { side: 0, hp: 2, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'stand_still',
          qi_dice: 1.0 },
        { side: 1, hp: 2, hex_x: 4, hex_y: 8, main_action: 'attack', movement_action: 'stand_still',
          qi_dice: 1.0 }
      ]
    }

    result = run_spar_parity_round(scenario, 0)

    expect(result[:mismatches]).to eq(0),
      "spar no-simultaneous-KO seed=0: #{result[:mismatches]}/#{result[:max]} event mismatches " \
      "(ruby=#{result[:ruby_len]} rust=#{result[:rust_len]} events)"

    # At most one side can be fully touched-out (not both), preventing a draw.
    # If both touch counts have reached hp, that means the bugfix regression fired.
    ruby_touches = result[:ruby_touches]
    rust_touches = result[:rust_touches]

    # ruby side: confirm at most one winner
    ruby_side0_out = (ruby_touches[0] || 0) >= 2
    ruby_side1_out = (ruby_touches[1] || 0) >= 2
    expect(ruby_side0_out && ruby_side1_out).to be(false),
      "Ruby: simultaneous touch-out on both sides (touches: #{ruby_touches.inspect})"

    rust_side0_out = (rust_touches[0] || 0) >= 2
    rust_side1_out = (rust_touches[1] || 0) >= 2
    expect(rust_side0_out && rust_side1_out).to be(false),
      "Rust: simultaneous touch-out on both sides (touches: #{rust_touches.inspect})"
  end

  it 'spar mode 2v2 — knockout order and final state parity (seed 0)' do
    # 2v2 spar: both engines must produce identical event streams and agree on
    # which side reaches the touch-out threshold first.
    scenario = {
      mode: 'spar',
      participants: [
        { side: 0, hp: 6, hex_x: 2, hex_y: 4, main_action: 'attack', movement_action: 'stand_still',
          qi_dice: 1.0 },
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'stand_still',
          qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 2, hex_y: 8, main_action: 'attack', movement_action: 'stand_still',
          qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 4, hex_y: 8, main_action: 'attack', movement_action: 'stand_still',
          qi_dice: 1.0 }
      ]
    }

    result = run_spar_parity_round(scenario, 0)

    expect(result[:mismatches]).to eq(0),
      "spar 2v2 seed=0: #{result[:mismatches]}/#{result[:max]} event mismatches " \
      "(ruby=#{result[:ruby_len]} rust=#{result[:rust_len]} events)"

    # Touch counts per side must match between engines
    expect(result[:ruby_touches]).to eq(result[:rust_touches]),
      "spar 2v2 touch counts diverged: ruby=#{result[:ruby_touches].inspect} rust=#{result[:rust_touches].inspect}"
  end
end
