# frozen_string_literal: true

# Multi-seed parity spec: loops four representative scenarios over seeds 0-9
# to catch seed-dependent divergence between Ruby and Rust combat engines.
# 40 examples total (4 scenarios × 10 seeds).
# Run: COMBAT_ENGINE_FORMAT=json bundle exec rspec spec/parity/multi_seed_parity_spec.rb --format documentation

require 'spec_helper'
require_relative 'parity_helpers'

RSpec.describe 'Multi-Seed Parity', :parity do
  include ParityHelpers

  before(:all) do
    unless rust_engine_available?
      skip 'Rust combat-server not running'
    end
  end

  # Four scenarios from QUICK_SCENARIOS most likely to reveal seed-dependent drift.
  # Hex coordinates use valid offset positions:
  #   y=4 (half_y=2, even) → x must be even
  #   y=8 (half_y=4, even) → x must be even
  MULTI_SEED_SCENARIOS = {
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
    'with_qi' => {
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'towards_person',
          qi_dice: 2.0, qi_attack: 1 },
        { side: 1, hp: 6, hex_x: 6, hex_y: 4, main_action: 'attack', movement_action: 'towards_person',
          qi_dice: 2.0, qi_defense: 1 }
      ]
    },
    '2v2_movement' => {
      participants: [
        { side: 0, hp: 6, hex_x: 2, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 1.0 },
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 6, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 8, hex_y: 4, main_action: 'attack', movement_action: 'towards_person', qi_dice: 1.0 }
      ]
    }
  }.freeze

  MULTI_SEED_SCENARIOS.each do |scenario_name, scenario_def|
    context scenario_name do
      (0..9).each do |seed|
        it "#{scenario_name} seed #{seed} matches exactly" do
          fight = create_parity_fight(scenario_def)
          round_seed = seed + 1 * 7919 + 3571

          # --- Ruby run ---
          ruby_events = nil
          DeterministicRng.with_seed(round_seed) do
            service = CombatResolutionService.new(fight)
            result = service.resolve!
            result = { events: result } if result.is_a?(Array)
            ruby_events = (result[:events] || []).select { |e| %w[hit miss].include?(e[:event_type].to_s) }
          end

          # --- Reset fight state for Rust run ---
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

          if ruby_norm.length != rust_events.length
            puts "    Event count: ruby=#{ruby_norm.length} rust=#{rust_events.length}"
          end

          expect(mismatches).to eq(0),
            "#{scenario_name} seed=#{seed}: #{mismatches}/#{max} mismatches " \
            "(ruby=#{ruby_norm.length} rust=#{rust_events.length} events)"
        end
      end
    end
  end
end
