# frozen_string_literal: true

# Interactive elements parity spec: verifies that battle-map element state
# transitions (ElementBroken, ElementDetonated, etc.) produced by Ruby
# CombatResolutionService match the Rust combat-engine event stream.
# 4 active element types × 5 seeds = 20 examples total.
# Run: COMBAT_ENGINE_FORMAT=json bundle exec rspec spec/parity/interactive_elements_parity_spec.rb --format documentation

require 'spec_helper'
require_relative 'parity_helpers'

RSpec.describe 'Interactive elements parity', :parity do
  include ParityHelpers

  before(:all) do
    unless rust_engine_available?
      skip 'Rust combat-server not running'
    end
  end

  # Place a BattleMapElement in the fight at the specified hex position.
  # Called after create_parity_fight so fight.id is available.
  # @param fight [Fight]
  # @param element_type [String] one of BattleMapElement::ELEMENT_TYPES
  # @param hex_x [Integer]
  # @param hex_y [Integer]
  # @return [BattleMapElement]
  def place_element(fight, element_type:, hex_x:, hex_y:)
    BattleMapElement.create(
      fight_id: fight.id,
      element_type: element_type,
      hex_x: hex_x,
      hex_y: hex_y,
      state: 'intact'
    )
  end

  # Reset a BattleMapElement back to intact so the Rust run sees a pristine state.
  # @param element [BattleMapElement]
  def reset_element(element)
    element.update(state: 'intact')
  end

  # Normalize Ruby element-transition events to { type, hex_x, hex_y }.
  # Ruby emits events with :event_type symbols; element transitions use types
  # like 'element_broken', 'element_detonated', 'element_ignited'.
  RUBY_ELEMENT_TYPES = %w[element_broken element_detonated element_ignited element_state_changed].freeze

  # Normalize Rust element-transition events.
  # Rust emits externally-tagged hashes: { 'ElementBroken' => {...} }, etc.
  RUST_ELEMENT_KEYS = %w[ElementBroken ElementDetonated ElementIgnited ElementStateChanged].freeze

  # Map Rust CamelCase key to Ruby snake_case event type for comparison.
  RUST_TO_RUBY_ELEMENT_TYPE = {
    'ElementBroken'       => 'element_broken',
    'ElementDetonated'    => 'element_detonated',
    'ElementIgnited'      => 'element_ignited',
    'ElementStateChanged' => 'element_state_changed'
  }.freeze

  # Scenarios: one per element type. Each places the element at (5, 4) and
  # positions two participants adjacent so attacks reach the element or each
  # other. Hex coordinates use valid offset positions (y=4, even → x even).
  ELEMENT_SCENARIOS = {
    'water_barrel' => {
      element_type: 'water_barrel',
      element_hex_x: 5,
      element_hex_y: 4,
      hexes: [
        { x: 4, y: 4, type: 'floor' },
        { x: 5, y: 4, type: 'floor' },
        { x: 6, y: 4, type: 'floor' }
      ],
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack',
          movement_action: 'towards_person', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 6, hex_y: 4, main_action: 'attack',
          movement_action: 'towards_person', qi_dice: 1.0 }
      ]
    },
    'oil_barrel' => {
      element_type: 'oil_barrel',
      element_hex_x: 5,
      element_hex_y: 4,
      hexes: [
        { x: 4, y: 4, type: 'floor' },
        { x: 5, y: 4, type: 'floor' },
        { x: 6, y: 4, type: 'floor' }
      ],
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack',
          movement_action: 'towards_person', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 6, hex_y: 4, main_action: 'attack',
          movement_action: 'towards_person', qi_dice: 1.0 }
      ]
    },
    'munitions_crate' => {
      element_type: 'munitions_crate',
      element_hex_x: 5,
      element_hex_y: 4,
      hexes: [
        { x: 4, y: 4, type: 'floor' },
        { x: 5, y: 4, type: 'floor' },
        { x: 6, y: 4, type: 'floor' }
      ],
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack',
          movement_action: 'towards_person', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 6, hex_y: 4, main_action: 'attack',
          movement_action: 'towards_person', qi_dice: 1.0 }
      ]
    },
    'vase' => {
      element_type: 'vase',
      element_hex_x: 5,
      element_hex_y: 4,
      hexes: [
        { x: 4, y: 4, type: 'floor' },
        { x: 5, y: 4, type: 'floor' },
        { x: 6, y: 4, type: 'floor' }
      ],
      participants: [
        { side: 0, hp: 6, hex_x: 4, hex_y: 4, main_action: 'attack',
          movement_action: 'towards_person', qi_dice: 1.0 },
        { side: 1, hp: 6, hex_x: 6, hex_y: 4, main_action: 'attack',
          movement_action: 'towards_person', qi_dice: 1.0 }
      ]
    }
  }.freeze

  ELEMENT_SCENARIOS.each do |scenario_name, scenario_def|
    context scenario_name do
      (0..4).each do |seed|
        it "seed #{seed} attack and element events match exactly" do
          fight = create_parity_fight(scenario_def)
          element = place_element(
            fight,
            element_type: scenario_def[:element_type],
            hex_x:        scenario_def[:element_hex_x],
            hex_y:        scenario_def[:element_hex_y]
          )

          round_seed = seed + 1 * 7919 + 3571

          # --- Ruby run ---
          ruby_events = nil
          DeterministicRng.with_seed(round_seed) do
            service = CombatResolutionService.new(fight)
            result = service.resolve!
            result = { events: result } if result.is_a?(Array)
            ruby_events = (result[:events] || []).select do |e|
              t = e[:event_type].to_s
              %w[hit miss].include?(t) || RUBY_ELEMENT_TYPES.include?(t)
            end
          end

          ruby_norm = ruby_events.map do |e|
            { type: e[:event_type].to_s, segment: e[:segment] }
          end

          # --- Reset fight state for Rust run ---
          fight.reload
          sorted_fps = fight.fight_participants.sort_by(&:id)
          scenario_def[:participants].each_with_index do |pcfg, idx|
            fp = sorted_fps[idx]
            next unless fp

            fp.update(
              current_hp:     pcfg[:hp],
              max_hp:         pcfg[:hp],
              is_knocked_out: false,
              touch_count:    0,
              hex_x:          pcfg[:hex_x],
              hex_y:          pcfg[:hex_y]
            )
          end

          # Reset element state so Rust sees it as intact
          reset_element(element)

          # --- Rust run ---
          serializer = Combat::FightStateSerializer.new(fight)
          client = CombatEngineClient.new
          rust_result = client.resolve_round(
            serializer.serialize,
            serializer.serialize_actions,
            seed: round_seed
          )
          rust_events_raw = rust_result['events'] || []

          rust_norm = rust_events_raw.select do |e|
            next false unless e.is_a?(Hash)
            next true if e.key?('AttackHit') || e.key?('AttackMiss')

            RUST_ELEMENT_KEYS.any? { |k| e.key?(k) }
          end.map do |e|
            if e.key?('AttackHit')
              { type: 'hit',  segment: e['AttackHit']['segment'] }
            elsif e.key?('AttackMiss')
              { type: 'miss', segment: e['AttackMiss']['segment'] }
            else
              rust_key = RUST_ELEMENT_KEYS.find { |k| e.key?(k) }
              ruby_type = RUST_TO_RUBY_ELEMENT_TYPE.fetch(rust_key, rust_key.to_s.gsub(/([a-z])([A-Z])/, '\1_\2').downcase)
              { type: ruby_type, segment: e[rust_key]['segment'] }
            end
          end

          # --- Compare ---
          mismatches = 0
          max = [ruby_norm.length, rust_norm.length].max
          max.times do |i|
            r = ruby_norm[i]
            s = rust_norm[i]
            if r.nil? || s.nil? || r[:type] != s[:type] || r[:segment] != s[:segment]
              mismatches += 1
              puts "    [#{i}] MISMATCH: ruby=#{r&.inspect} rust=#{s&.inspect}" if mismatches <= 3
            end
          end

          if ruby_norm.length != rust_norm.length
            puts "    Event count: ruby=#{ruby_norm.length} rust=#{rust_norm.length}"
          end

          expect(mismatches).to eq(0),
            "#{scenario_name} seed=#{seed}: #{mismatches}/#{max} mismatches " \
            "(ruby=#{ruby_norm.length} rust=#{rust_norm.length} events)"
        end
      end
    end
  end
end
