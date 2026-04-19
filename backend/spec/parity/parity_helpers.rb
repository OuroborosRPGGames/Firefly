# frozen_string_literal: true

require_relative '../../app/lib/deterministic_rng'

# Helpers for combat engine parity testing.
# Creates synthetic fight scenarios using FactoryBot, runs them through
# both Ruby CombatResolutionService and Rust combat-server, and compares.
module ParityHelpers
  COMBAT_SERVER_SOCKET = ENV.fetch('COMBAT_ENGINE_SOCKET', '/tmp/combat-engine.sock')

  # Create a Fight with FightParticipants from a scenario hash.
  # @param scenario [Hash] :participants array of participant configs
  # @return [Fight]
  def create_parity_fight(scenario)
    room = FactoryBot.create(:room)

    # Create hex map if scenario includes hex cells
    if scenario[:hexes]
      room.update(has_battle_map: true) if room.respond_to?(:has_battle_map)
      scenario[:hexes].each do |hcfg|
        # Create directly via model (factory has broken elevation alias)
        RoomHex.create(
          room_id: room.id,
          hex_x: hcfg[:x],
          hex_y: hcfg[:y],
          hex_type: hcfg[:type] || 'normal',
          traversable: hcfg.fetch(:traversable, true),
          danger_level: 0,
          elevation_level: hcfg[:elevation] || 0,
          blocks_line_of_sight: hcfg[:blocks_los] || false,
          difficult_terrain: hcfg[:difficult] || false,
          has_cover: hcfg[:cover] || false,
          destroyable: hcfg[:destroyable] || false,
          hazard_type: hcfg[:hazard_type],
          hazard_damage_per_round: hcfg[:hazard_damage] || 0
        )
      end
    end

    fight = FactoryBot.create(:fight,
      room: room,
      status: 'resolving',
      round_number: 1,
      mode: scenario[:mode] || 'normal',
      arena_width: scenario[:arena_width] || 20,
      arena_height: scenario[:arena_height] || 20
    )

    scenario[:participants].each do |pcfg|
      ci = FactoryBot.create(:character_instance,
        current_room: room,
        health: pcfg[:hp],
        max_health: pcfg[:hp]
      )

      # Force consistent stat values so both Ruby and Rust engines see
      # identical stat_modifier regardless of what initialize_stats_from_character
      # created from whatever StatBlock records exist in the test DB.
      normalize_character_stats!(ci, pcfg[:stat_modifier] || 0)

      fp = FactoryBot.create(:fight_participant,
        fight: fight,
        character_instance: ci,
        side: pcfg[:side],
        current_hp: pcfg[:hp],
        max_hp: pcfg[:hp],
        hex_x: pcfg[:hex_x] || 0,
        hex_y: pcfg[:hex_y] || 0,
        is_knocked_out: false,
        input_complete: true,
        main_action: pcfg[:main_action] || 'attack',
        movement_action: pcfg[:movement_action] || 'towards_person',
        willpower_attack: pcfg[:qi_attack] || 0,
        willpower_defense: pcfg[:qi_defense] || 0,
        willpower_ability: pcfg[:qi_ability] || 0,
        willpower_movement: pcfg[:qi_movement] || 0,
        willpower_dice: pcfg[:qi_dice] || 1.0,
        npc_damage_bonus: pcfg[:npc_damage_bonus] || 0
      )

      fp.update(flee_direction: pcfg[:flee_direction]) if pcfg[:flee_direction]
      fp.update(target_hex_x: pcfg[:target_hex_x], target_hex_y: pcfg[:target_hex_y]) if pcfg[:target_hex_x]

      # Set target to first enemy
      enemies = scenario[:participants].select { |p| p[:side] != pcfg[:side] }
      if enemies.any?
        # Target will be set after all participants exist
        fp.update(movement_target_participant_id: nil, target_participant_id: nil)
      end
    end

    # Apply status effects AFTER all participants exist so source_id can be resolved.
    apply_scenario_status_effects(fight, scenario[:participants]) if scenario[:participants].any? { |p| p[:status_effects] }

    # Now wire up targets: each participant targets the first enemy
    fight.fight_participants.each do |fp|
      enemy = fight.fight_participants_dataset.exclude(side: fp.side).first
      if enemy
        fp.update(
          target_participant_id: enemy.id,
          movement_target_participant_id: enemy.id
        )
      end
    end

    fight.reload
    fight
  end

  MAX_ROUNDS = 20

  # Run a full multi-round Ruby fight with deterministic RNG.
  # Uses CombatResolutionService per round, with AI defaults for each round.
  # @param fight [Fight] fight to resolve
  # @param seed [Integer] ChaCha8 seed
  # @param trace [Boolean] if true, record RNG trace log
  # @return [Hash] final state after fight ends or max rounds
  def run_ruby_fight(fight, seed, trace: false)
    rounds = 0
    total_events = 0
    all_events = []
    all_traces = []

    MAX_ROUNDS.times do
      fight.reload
      break if fight.should_end?

      rounds += 1
      fight.update(status: 'resolving')

      # Apply AI defaults with same per-round seed as Rust
      round_ai_seed = seed + rounds * 7919
      DeterministicRng.with_seed(round_ai_seed) do
        fight.active_participants.each do |p|
          unless p.input_complete
            CombatAIService.new(p).apply_decisions!
          end
        end
      end

      # Resolve round with same per-round seed as Rust
      round_resolve_seed = seed + rounds * 7919 + 3571

      round_events = nil
      round_trace = nil

      if trace
        DeterministicRng.with_seed_traced(round_resolve_seed) do |_rng, trace_log|
          service = CombatResolutionService.new(fight)
          result = service.resolve!
          result = { events: result } if result.is_a?(Array)
          round_events = result[:events] || []
          round_trace = trace_log.dup
        end
      else
        DeterministicRng.with_seed(round_resolve_seed) do
          service = CombatResolutionService.new(fight)
          result = service.resolve!
          result = { events: result } if result.is_a?(Array)
          round_events = result[:events] || []
        end
      end

      total_events += round_events.length
      all_events << { round: rounds, events: normalize_ruby_events(round_events) }
      all_traces << { round: rounds, trace: round_trace } if round_trace

      # Advance round
      fight.update(
        round_number: fight.round_number + 1,
        status: 'input'
      )

      # Reset participant inputs for next round
      fight.fight_participants_dataset.where(is_knocked_out: false).each do |p|
        p.update(input_complete: false, main_action: 'attack', movement_action: 'towards_person')
        # Re-target first living enemy
        enemy = fight.fight_participants_dataset.exclude(side: p.side).where(is_knocked_out: false).first
        p.update(target_participant_id: enemy&.id, movement_target_participant_id: enemy&.id) if enemy
      end
    end

    participant_states = {}
    fight.fight_participants_dataset.all.each do |fp|
      participant_states[fp.id] = {
        hp: fp.current_hp,
        knocked_out: fp.is_knocked_out,
        touch_count: fp.touch_count || 0
      }
    end

    {
      rounds: rounds, total_events: total_events, participants: participant_states,
      per_round_events: all_events, rng_traces: all_traces
    }
  rescue StandardError => e
    warn "[ParityHelpers] Ruby fight failed at round #{rounds}: #{e.class}: #{e.message}"
    warn e.backtrace.first(5).join("\n")
    { rounds: rounds, total_events: 0, participants: {}, error: e.message }
  end

  # Run a full multi-round Rust fight via combat-server.
  # Iterates resolve_round + generate_ai_actions until fight ends.
  # @param fight [Fight] fight to serialize initial state from
  # @param seed [Integer] ChaCha8 seed
  # @param trace [Boolean] if true, request RNG trace from Rust engine
  # @return [Hash] final state
  def run_rust_fight(fight, seed, trace: false)
    serializer = Combat::FightStateSerializer.new(fight)
    state = serializer.serialize
    # Use the serialized actions for round 1
    actions = serializer.serialize_actions

    client = CombatEngineClient.new
    rounds = 0
    total_events = 0
    all_events = []

    MAX_ROUNDS.times do
      rounds += 1

      # For round 2+, generate AI actions
      if rounds > 1
        active_ids = state['participants']
          .select { |p| !p['is_knocked_out'] }
          .map { |p| p['id'] }

        break if active_ids.length <= 1

        ai_result = client.generate_ai_actions(state, active_ids, seed: seed + rounds * 7919)
        actions = ai_result['actions'] || ai_result
      end

      result = client.resolve_round(state, actions,
        seed: seed + rounds * 7919 + 3571,
        trace_rng: trace)
      round_events = result['events'] || []
      total_events += round_events.length
      all_events << { round: rounds, events: normalize_rust_events(round_events) }
      state = result['next_state'] || result

      break if result['fight_ended']

      # Check if fight should end (one side eliminated)
      side0_alive = state['participants'].any? { |p| p['side'] == 0 && !p['is_knocked_out'] }
      side1_alive = state['participants'].any? { |p| p['side'] == 1 && !p['is_knocked_out'] }
      break unless side0_alive && side1_alive
    end

    participant_states = {}
    (state['participants'] || []).each do |rp|
      participant_states[rp['id']] = {
        hp: rp['current_hp'].to_i,
        knocked_out: rp['is_knocked_out'] || false,
        touch_count: (rp['touch_count'] || 0).to_i
      }
    end

    { rounds: rounds, total_events: total_events, participants: participant_states,
      per_round_events: all_events }
  rescue CombatEngineClient::ConnectionError, CombatEngineClient::ProtocolError => e
    warn "[ParityHelpers] Rust fight failed at round #{rounds}: #{e.message}"
    { rounds: rounds, total_events: 0, participants: {}, error: e.message }
  end

  # Normalize Ruby combat events to a comparable format.
  # Extracts key fields: segment, actor_id, target_id, event_type, damage, hp_lost
  def normalize_ruby_events(events)
    events.filter_map do |e|
      next if e.nil?
      type = e[:event_type]&.to_s
      next unless type

      normalized = {
        type: type,
        segment: e[:segment],
        actor_id: e[:actor_id],
        target_id: e[:target_id]
      }

      case type
      when 'hit'
        normalized[:damage] = e.dig(:details, :total)
        normalized[:hp_lost] = e.dig(:details, :hp_lost_this_attack)
        normalized[:roll] = e.dig(:details, :roll)
        normalized[:stat_mod] = e.dig(:details, :stat_mod)
        normalized[:wound_penalty] = e.dig(:details, :wound_penalty)
        normalized[:weapon_type] = e.dig(:details, :weapon_type)
        normalized[:willpower_attack_bonus] = e.dig(:details, :willpower_attack_bonus)
        normalized[:willpower_defense_roll] = e.dig(:details, :willpower_defense_roll)
      when 'miss'
        normalized[:damage] = e.dig(:details, :total)
        normalized[:roll] = e.dig(:details, :roll)
        normalized[:stat_mod] = e.dig(:details, :stat_mod)
        normalized[:wound_penalty] = e.dig(:details, :wound_penalty)
        normalized[:weapon_type] = e.dig(:details, :weapon_type)
      when 'knockout'
        normalized[:knocked_out_id] = e[:target_id]
      end

      normalized
    end
  end

  # Normalize Rust combat events to a comparable format.
  # Rust events come as externally-tagged hashes: {"AttackHit" => {...}}
  def normalize_rust_events(events)
    events.filter_map do |e|
      next if e.nil?

      # Rust events are externally tagged: {"AttackHit" => {...fields...}}
      # or internally tagged: {"type" => "AttackHit", ...fields...}
      if e.is_a?(Hash)
        if e.key?('AttackHit')
          data = e['AttackHit']
          {
            type: 'hit',
            segment: data['segment'],
            actor_id: data['attacker_id'],
            target_id: data['target_id'],
            raw_damage: data['raw_damage'],
            damage: data['damage'],
            hp_lost: data['hp_lost'],
            roll: data.dig('roll', 'base_roll'),
            stat_mod: data.dig('roll', 'stat_mod'),
            wound_penalty: data.dig('roll', 'wound_penalty'),
            weapon_type: data.dig('weapon', 'weapon_type'),
            willpower_attack_bonus: data.dig('roll', 'qi_attack_bonus'),
            defense_detail: data['defense']
          }
        elsif e.key?('AttackMiss')
          data = e['AttackMiss']
          {
            type: 'miss',
            segment: data['segment'],
            actor_id: data['attacker_id'],
            target_id: data['target_id'],
            raw_damage: data['raw_damage'],
            damage: data['damage'],
            roll: data.dig('roll', 'base_roll'),
            stat_mod: data.dig('roll', 'stat_mod'),
            wound_penalty: data.dig('roll', 'wound_penalty'),
            weapon_type: data.dig('weapon', 'weapon_type')
          }
        elsif e.key?('KnockedOut')
          data = e['KnockedOut']
          {
            type: 'knockout',
            segment: nil,
            actor_id: data['by_id'],
            target_id: data['participant_id'],
            knocked_out_id: data['participant_id']
          }
        elsif e.key?('Moved')
          data = e['Moved']
          {
            type: 'moved',
            segment: data['segment'],
            actor_id: data['participant_id'],
            target_id: nil
          }
        elsif e.key?('AttackOutOfRange')
          data = e['AttackOutOfRange']
          {
            type: 'out_of_range',
            segment: data['segment'],
            actor_id: data['attacker_id'],
            target_id: data['target_id'],
            distance: data['distance']
          }
        elsif e.key?('RngTrace')
          data = e['RngTrace']
          {
            type: 'rng_trace',
            participant_id: data['participant_id'],
            label: data['label'],
            value: data['value'],
            sequence: data['sequence']
          }
        elsif e.key?('HazardDamage')
          data = e['HazardDamage']
          {
            type: 'hazard_damage',
            segment: data['segment'],
            target_id: data['participant_id'],
            damage: data['damage'],
            hp_lost: data['hp_lost'],
            hazard_type: data['hazard_type']
          }
        elsif e.key?('DotTick')
          data = e['DotTick']
          {
            type: 'dot_tick',
            segment: data['segment'],
            target_id: data['participant_id'],
            damage: data['damage'],
            hp_lost: data['hp_lost'],
            effect_name: data['effect_name']
          }
        elsif e.key?('WallFlip')
          data = e['WallFlip']
          { type: 'wall_flip', segment: data['segment'], actor_id: data['participant_id'] }
        elsif e.key?('AbilityUsed')
          data = e['AbilityUsed']
          { type: 'abilityused', segment: data['segment'], actor_id: data['caster_id'],
            ability_id: data['ability_id'], targets: data['targets'] }
        elsif e.key?('AbilityHeal')
          data = e['AbilityHeal']
          { type: 'abilityheal', segment: data['segment'], actor_id: data['caster_id'],
            target_id: data['target_id'], amount: data['amount'] }
        elsif e.key?('AbilityExecute')
          data = e['AbilityExecute']
          { type: 'abilityexecute', segment: data['segment'], actor_id: data['caster_id'],
            target_id: data['target_id'] }
        elsif e.key?('MonsterTurn')
          data = e['MonsterTurn']
          { type: 'monster_turn', segment: data['segment'], actor_id: data['monster_id'] }
        elsif e.key?('MonsterMove')
          data = e['MonsterMove']
          { type: 'monster_move', segment: data['segment'], actor_id: data['monster_id'] }
        elsif e.key?('MonsterShakeOff')
          data = e['MonsterShakeOff']
          { type: 'monster_shake_off', segment: data['segment'], actor_id: data['monster_id'],
            thrown: data['thrown'] }
        elsif e.key?('FleeSuccess')
          data = e['FleeSuccess']
          { type: 'flee_success', actor_id: data['participant_id'],
            direction: data['direction'] }
        elsif e.key?('FleeFailed')
          data = e['FleeFailed']
          { type: 'flee_failed', actor_id: data['participant_id'],
            direction: data['direction'] }
        else
          # Other event types - just capture the key name
          key = e.keys.first
          { type: key.to_s.downcase, raw: e }
        end
      end
    end
  end

  # Compare events from a single round between Ruby and Rust.
  # Returns a diff report with the first divergence point.
  def compare_round_events(ruby_events, rust_events, round:)
    # Filter to combat events only (hit/miss/knockout), skip movement/qi/rng_trace
    combat_types = %w[hit miss knockout]
    ruby_combat = ruby_events.select { |e| combat_types.include?(e[:type]) }
    rust_combat = rust_events.select { |e| combat_types.include?(e[:type]) }

    diffs = []

    # Compare event counts
    if ruby_combat.length != rust_combat.length
      diffs << {
        round: round, issue: 'event_count_mismatch',
        ruby_count: ruby_combat.length, rust_count: rust_combat.length,
        ruby_types: ruby_combat.map { |e| e[:type] }.tally,
        rust_types: rust_combat.map { |e| e[:type] }.tally
      }
    end

    # Compare events in order
    max_len = [ruby_combat.length, rust_combat.length].max
    max_len.times do |i|
      re = ruby_combat[i]
      rs = rust_combat[i]

      if re.nil?
        diffs << { round: round, index: i, issue: 'extra_rust_event', rust: rs }
        next
      end
      if rs.nil?
        diffs << { round: round, index: i, issue: 'extra_ruby_event', ruby: re }
        next
      end

      # Compare key fields
      if re[:type] != rs[:type]
        diffs << { round: round, index: i, issue: 'type_mismatch', ruby: re, rust: rs }
      elsif re[:type] == 'hit' || re[:type] == 'miss'
        field_diffs = []
        field_diffs << "segment: ruby=#{re[:segment]} rust=#{rs[:segment]}" if re[:segment] != rs[:segment]
        field_diffs << "actor: ruby=#{re[:actor_id]} rust=#{rs[:actor_id]}" if re[:actor_id] != rs[:actor_id]
        field_diffs << "target: ruby=#{re[:target_id]} rust=#{rs[:target_id]}" if re[:target_id] != rs[:target_id]
        if re[:type] == 'hit'
          field_diffs << "hp_lost: ruby=#{re[:hp_lost]} rust=#{rs[:hp_lost]}" if re[:hp_lost] != rs[:hp_lost]
          field_diffs << "damage: ruby=#{re[:damage]} rust=#{rs[:damage]}" if re[:damage] != rs[:damage]
        end
        field_diffs << "roll: ruby=#{re[:roll]} rust=#{rs[:roll]}" if re[:roll] != rs[:roll]

        if field_diffs.any?
          diffs << {
            round: round, index: i, issue: 'field_mismatch',
            fields: field_diffs, ruby: re, rust: rs
          }
        end
      end
    end

    diffs
  end

  # Run a scenario N times with different seeds and collect aggregate statistics.
  # Resets fight state between runs by creating a fresh fight for each seed.
  # @param scenario [Hash] scenario definition
  # @param seeds [Array<Integer>] seeds to test
  # @param trace_failing [Boolean] if true, re-run failing seeds with RNG tracing
  # @return [Hash] aggregate comparison
  def run_statistical_comparison(scenario, seeds:, trace_failing: false)
    ruby_stats = { wins_side0: 0, wins_side1: 0, total_hp: Hash.new(0), ko_count: Hash.new(0) }
    rust_stats = { wins_side0: 0, wins_side1: 0, total_hp: Hash.new(0), ko_count: Hash.new(0) }
    errors = []
    per_seed_results = []
    event_diffs = []
    is_spar = scenario[:mode] == 'spar'

    seeds.each do |seed|
      # Create fresh fight for each seed (resolution mutates DB)
      fight = create_parity_fight(scenario)

      # Snapshot participant mapping: DB id -> scenario side
      id_to_side = {}
      fight.fight_participants.each { |fp| id_to_side[fp.id] = fp.side }

      # Run Rust first (stateless, doesn't mutate DB)
      rust_result = run_rust_fight(fight, seed)

      if rust_result[:error]
        errors << { seed: seed, engine: 'rust', error: rust_result[:error] }
        next
      end

      # Create a fresh fight for Ruby (since Rust didn't touch DB, but Ruby will)
      fight_ruby = create_parity_fight(scenario)
      id_to_side_ruby = {}
      fight_ruby.fight_participants.each { |fp| id_to_side_ruby[fp.id] = fp.side }

      # Run Ruby (mutates DB)
      ruby_result = run_ruby_fight(fight_ruby, seed)

      if ruby_result[:error]
        errors << { seed: seed, engine: 'ruby', error: ruby_result[:error] }
        next
      end

      # Compare per-round events
      min_rounds = [ruby_result[:per_round_events]&.length || 0, rust_result[:per_round_events]&.length || 0].min
      min_rounds.times do |i|
        ruby_round = ruby_result[:per_round_events][i]
        rust_round = rust_result[:per_round_events][i]
        next unless ruby_round && rust_round

        diffs = compare_round_events(
          ruby_round[:events] || [],
          rust_round[:events] || [],
          round: ruby_round[:round]
        )
        if diffs.any?
          event_diffs << { seed: seed, diffs: diffs }
          break # Only report first diverging round per seed
        end
      end

      # Aggregate Ruby stats (uses id_to_side_ruby since different fight object)
      ruby_result[:participants].each do |pid, state|
        side = id_to_side_ruby[pid]
        ruby_stats[:total_hp][side] = (ruby_stats[:total_hp][side] || 0) + state[:hp]
        ruby_stats[:ko_count][side] = (ruby_stats[:ko_count][side] || 0) + (participant_eliminated?(state, is_spar) ? 1 : 0)
      end

      # Determine Ruby winner
      side0_all_out = ruby_result[:participants].select { |pid, _| id_to_side_ruby[pid] == 1 }.all? { |_, s| participant_eliminated?(s, is_spar) }
      side1_all_out = ruby_result[:participants].select { |pid, _| id_to_side_ruby[pid] == 0 }.all? { |_, s| participant_eliminated?(s, is_spar) }
      ruby_stats[:wins_side0] += 1 if side0_all_out && !side1_all_out
      ruby_stats[:wins_side1] += 1 if side1_all_out && !side0_all_out

      # Aggregate Rust stats
      rust_result[:participants].each do |pid, state|
        side = id_to_side[pid]
        next unless side
        rust_stats[:total_hp][side] = (rust_stats[:total_hp][side] || 0) + state[:hp]
        rust_stats[:ko_count][side] = (rust_stats[:ko_count][side] || 0) + (participant_eliminated?(state, is_spar) ? 1 : 0)
      end

      side0_all_out_rust = rust_result[:participants].select { |pid, _| id_to_side[pid] == 1 }.all? { |_, s| participant_eliminated?(s, is_spar) }
      side1_all_out_rust = rust_result[:participants].select { |pid, _| id_to_side[pid] == 0 }.all? { |_, s| participant_eliminated?(s, is_spar) }
      rust_stats[:wins_side0] += 1 if side0_all_out_rust && !side1_all_out_rust
      rust_stats[:wins_side1] += 1 if side1_all_out_rust && !side0_all_out_rust

      per_seed_results << { seed: seed, ruby: ruby_result, rust: rust_result, id_to_side: id_to_side }
    end

    valid_count = seeds.length - errors.length
    return { valid: false, errors: errors } if valid_count == 0

    {
      valid: true,
      total_seeds: seeds.length,
      valid_seeds: valid_count,
      errors: errors,
      event_diffs: event_diffs,
      ruby: {
        win_rate_side0: ruby_stats[:wins_side0].to_f / valid_count,
        win_rate_side1: ruby_stats[:wins_side1].to_f / valid_count,
        mean_hp_side0: ruby_stats[:total_hp][0].to_f / valid_count,
        mean_hp_side1: ruby_stats[:total_hp][1].to_f / valid_count,
        ko_rate_side0: ruby_stats[:ko_count][0].to_f / valid_count,
        ko_rate_side1: ruby_stats[:ko_count][1].to_f / valid_count
      },
      rust: {
        win_rate_side0: rust_stats[:wins_side0].to_f / valid_count,
        win_rate_side1: rust_stats[:wins_side1].to_f / valid_count,
        mean_hp_side0: rust_stats[:total_hp][0].to_f / valid_count,
        mean_hp_side1: rust_stats[:total_hp][1].to_f / valid_count,
        ko_rate_side0: rust_stats[:ko_count][0].to_f / valid_count,
        ko_rate_side1: rust_stats[:ko_count][1].to_f / valid_count
      },
      per_seed: per_seed_results
    }
  end

  # Run a single seed with RNG tracing enabled on both sides.
  # Returns detailed trace comparison for debugging.
  def run_traced_comparison(scenario, seed)
    fight_rust = create_parity_fight(scenario)
    fight_ruby = create_parity_fight(scenario)

    rust_result = run_rust_fight(fight_rust, seed, trace: true)
    ruby_result = run_ruby_fight(fight_ruby, seed, trace: true)

    # Extract RNG traces
    rust_traces = []
    rust_result[:per_round_events]&.each do |round_data|
      traces = (round_data[:events] || []).select { |e| e[:type] == 'rng_trace' }
      rust_traces << { round: round_data[:round], traces: traces } if traces.any?
    end

    ruby_traces = ruby_result[:rng_traces] || []

    {
      seed: seed,
      ruby: ruby_result,
      rust: rust_result,
      ruby_traces: ruby_traces,
      rust_traces: rust_traces
    }
  end

  # Check if a participant is eliminated (KO'd or touched out in spar)
  def participant_eliminated?(state, is_spar)
    if is_spar
      (state[:touch_count] || 0) >= (state[:hp] || 6) || state[:knocked_out]
    else
      state[:knocked_out]
    end
  end

  # Run a single-round exact-parity comparison between Ruby and Rust for a
  # scenario + seed. Returns { mismatches:, ruby_len:, rust_len:, ruby_events:, rust_events: }.
  # Extracted from ranged_cover_spec.rb's boilerplate so new specs can stay small.
  #
  # `extra_event_keys` (Array<String>) adds Rust event variants to the compared set
  # beyond the default AttackHit/AttackMiss. Pass e.g. ['FleeSuccess', 'WallFlip']
  # to include them.
  def run_exact_parity_round(scenario, seed, extra_event_keys: [])
    fight = create_parity_fight(scenario)
    round_seed = seed + 1 * 7919 + 3571

    # Translate CamelCase Rust keys to Ruby snake_case: 'HazardDamage' -> 'hazard_damage'.
    ruby_extra_types = extra_event_keys.map { |k| k.gsub(/([a-z])([A-Z])/, '\1_\2').downcase }

    ruby_events = nil
    DeterministicRng.with_seed(round_seed) do
      service = CombatResolutionService.new(fight)
      result = service.resolve!
      result = { events: result } if result.is_a?(Array)
      ruby_events = (result[:events] || []).select do |e|
        t = e[:event_type].to_s
        %w[hit miss].include?(t) || ruby_extra_types.include?(t)
      end
    end

    fight.reload
    sorted_fps = fight.fight_participants.sort_by(&:id)
    scenario[:participants].each_with_index do |pcfg, idx|
      fp = sorted_fps[idx]
      next unless fp

      fp.update(current_hp: pcfg[:hp], max_hp: pcfg[:hp], is_knocked_out: false,
                touch_count: 0, hex_x: pcfg[:hex_x], hex_y: pcfg[:hex_y])
    end

    serializer = Combat::FightStateSerializer.new(fight)
    client = CombatEngineClient.new
    rust_result = client.resolve_round(serializer.serialize, serializer.serialize_actions,
                                       seed: round_seed)
    rust_events_raw = rust_result['events'] || []
    rust_events = rust_events_raw.select do |e|
      next false unless e.is_a?(Hash)
      next true if e.key?('AttackHit') || e.key?('AttackMiss')
      extra_event_keys.any? { |k| e.key?(k) }
    end.map do |e|
      if e.key?('AttackHit')
        { type: 'hit', segment: e['AttackHit']['segment'] }
      elsif e.key?('AttackMiss')
        { type: 'miss', segment: e['AttackMiss']['segment'] }
      else
        key = e.keys.first
        # Convert CamelCase to snake_case so it matches Ruby's event_type.
        snake = key.to_s.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
        { type: snake, segment: e[key]['segment'] }
      end
    end

    ruby_norm = ruby_events.map do |e|
      { type: e[:event_type].to_s, segment: e[:segment] }
    end

    mismatches = 0
    max = [ruby_norm.length, rust_events.length].max
    max.times do |i|
      r = ruby_norm[i]
      s = rust_events[i]
      next unless r.nil? || s.nil? || r[:type] != s[:type] || r[:segment] != s[:segment]

      mismatches += 1
      puts "    [#{i}] MISMATCH: ruby=#{r&.inspect} rust=#{s&.inspect}" if mismatches <= 3
    end

    { mismatches: mismatches, max: max, ruby_len: ruby_norm.length, rust_len: rust_events.length }
  end

  # Apply status effects from scenario config.
  # Each participant's `status_effects` is a list of hashes like:
  #   { name: 'dangling', duration_rounds: 2, source_participant_index: 1, stack_count: 1, effect_value: 0 }
  # source_participant_index is 1-based into scenario[:participants] (nil/absent = no source).
  # Requires StatusEffect records to exist in the test DB for the named effects.
  def apply_scenario_status_effects(fight, participants)
    sorted_fps = fight.fight_participants.sort_by(&:id)
    participants.each_with_index do |pcfg, idx|
      next unless pcfg[:status_effects]&.any?

      fp = sorted_fps[idx]
      next unless fp

      pcfg[:status_effects].each do |sec|
        se = StatusEffect.first(name: sec[:name])
        next unless se

        applied_by_id = nil
        if (src_idx = sec[:source_participant_index])
          src_fp = sorted_fps[src_idx - 1]
          applied_by_id = src_fp&.id
        end

        ParticipantStatusEffect.create(
          fight_participant_id: fp.id,
          status_effect_id: se.id,
          expires_at_round: fight.round_number + (sec[:duration_rounds] || 3),
          applied_at_round: fight.round_number,
          stack_count: sec[:stack_count] || 1,
          effect_value: sec[:effect_value],
          applied_by_participant_id: applied_by_id
        )
      end
    end
  end

  # Find-or-create a StatusEffect row for tests. Returns the StatusEffect record.
  def ensure_status_effect(name:, effect_type:, mechanics: {}, stacking_behavior: 'refresh', is_buff: false, max_stacks: 1)
    se = StatusEffect.first(name: name)
    return se if se

    StatusEffect.create(
      name: name,
      effect_type: effect_type,
      mechanics: Sequel.pg_jsonb_wrap(mechanics),
      stacking_behavior: stacking_behavior,
      is_buff: is_buff,
      max_stacks: max_stacks
    )
  end

  # Remove all CharacterStat records so both engines fall back to
  # DEFAULT_STAT (10). The after_create callback on CharacterInstance
  # creates stats from whatever StatBlock records exist in the test DB,
  # which can vary across test runs and cause non-deterministic stat values.
  # @param ci [CharacterInstance]
  # @param value [Integer, nil] explicit stat value, or nil to delete all (DEFAULT_STAT fallback)
  def normalize_character_stats!(ci, value = nil)
    if value.nil? || value == 0
      # Delete all stats -- both engines fall back to DEFAULT_STAT (10)
      CharacterStat.where(character_instance_id: ci.id).delete
    else
      # Set all stats to the explicit value
      ci.character_stats.each do |cs|
        cs.update(base_value: value, temp_modifier: 0)
      end
    end
  end

  # Check if the combat-server is running
  def rust_engine_available?
    CombatEngineClient.available?
  end

  # Count events of a given type in a per_round_events result.
  # @param per_round_events [Array<Hash>] from run_*_fight
  # @param types [Array<String>] event types to count (e.g., ['hit', 'dot_tick'])
  # @return [Integer]
  def count_events_by_type(per_round_events, types)
    types = Array(types)
    per_round_events.sum do |round_data|
      (round_data[:events] || []).count { |e| types.include?(e[:type]) }
    end
  end

  # Aggregate HP loss per side across all rounds from per_round_events.
  # @return [Hash{Integer => Integer}] side -> total hp_lost
  def aggregate_hp_loss_by_side(per_round_events, id_to_side)
    result = Hash.new(0)
    per_round_events.each do |round_data|
      (round_data[:events] || []).each do |e|
        next unless e[:type] == 'hit' && e[:hp_lost] && e[:target_id]

        side = id_to_side[e[:target_id]]
        result[side] += e[:hp_lost].to_i if side
      end
    end
    result
  end

  # Build a canonical ID map for cross-engine event comparison.
  # Ruby and Rust fights live in separate DB rows with different IDs, so event
  # comparison must remap actor_id/target_id to stable labels. Labels are
  # "s{side}i{index-within-side}" with participants ordered by DB id ascending.
  # @param fight [Fight]
  # @return [Hash{Integer => String}] { fp_id => "s0i0" }
  def build_canonical_id_map(fight)
    fps_sorted = fight.fight_participants.sort_by(&:id)
    fps_sorted.group_by(&:side).each_with_object({}) do |(side, fps), map|
      fps.each_with_index { |fp, i| map[fp.id] = "s#{side}i#{i}" }
    end
  end

  # Replace actor_id / target_id in event hashes with canonical labels.
  # Non-participant IDs (e.g. monsters, fight objects) pass through unchanged.
  # @param events [Array<Hash>]
  # @param id_map [Hash{Integer => String}]
  # @return [Array<Hash>]
  def canonicalize_event_ids(events, id_map)
    events.map do |e|
      next e unless e.is_a?(Hash)

      out = e.dup
      out[:actor_id] = id_map.fetch(e[:actor_id], e[:actor_id]) if e.key?(:actor_id)
      out[:target_id] = id_map.fetch(e[:target_id], e[:target_id]) if e.key?(:target_id)
      out[:knocked_out_id] = id_map.fetch(e[:knocked_out_id], e[:knocked_out_id]) if e.key?(:knocked_out_id)
      out
    end
  end

  # Return the first divergence between two event lists, or nil if identical.
  # Used by the multi-round parity spec to produce readable failure messages.
  def diff_event_lists(ruby_events, rust_events, round:)
    max = [ruby_events.length, rust_events.length].max
    max.times do |i|
      r = ruby_events[i]
      s = rust_events[i]
      next if r == s

      return {
        round: round,
        index: i,
        ruby: r,
        rust: s,
        ruby_total: ruby_events.length,
        rust_total: rust_events.length
      }
    end
    nil
  end

  # Map each participant to its final state keyed by canonical label.
  # @return [Hash{String => Hash}] { "s0i0" => { hp:, knocked_out:, touch_count: } }
  def canonicalize_participant_states(participant_states, id_map)
    participant_states.each_with_object({}) do |(pid, state), out|
      label = id_map.fetch(pid, pid.to_s)
      out[label] = state
    end
  end
end
