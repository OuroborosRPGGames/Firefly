# frozen_string_literal: true

# Main orchestrator for battle balancing.
# Uses PowerCalculatorService for initial estimation, then CombatSimulatorService
# for simulation-based refinement until achieving target balance.
#
# Balance Target: PCs win 100% of simulations with score in 30-80 range
# This means they win, but by a narrow margin (not too easy, not too hard).
#
# @example
#   balancer = BattleBalancingService.new(
#     pc_ids: [1, 2, 3, 4],
#     mandatory_archetype_ids: [10],      # Boss that must be included
#     optional_archetype_ids: [20, 21]    # Minions to fill out
#   )
#   result = balancer.balance!
#   result[:composition]       # => { 10 => { count: 1 }, 20 => { count: 3 } }
#   result[:difficulty_variants] # => { 'easy' => {...}, 'hard' => {...} }
#
class BattleBalancingService
  # Number of simulations per balance check
  SIMULATIONS = 100

  # Maximum balancing iterations before giving up
  MAX_ITERATIONS = 10

  # Arena size for simulations
  DEFAULT_ARENA_WIDTH = 10
  DEFAULT_ARENA_HEIGHT = 10

  attr_reader :pc_ids, :mandatory_archetype_ids, :optional_archetype_ids,
              :pc_power, :mandatory_archetypes, :optional_archetypes,
              :pc_participants, :iterations_used, :simulation_count

  # @param pc_ids [Array<Integer>] Character IDs for PCs
  # @param mandatory_archetype_ids [Array<Integer>] Archetype IDs that must be included
  # @param optional_archetype_ids [Array<Integer>] Archetype IDs that can be added for balance
  def initialize(pc_ids:, mandatory_archetype_ids:, optional_archetype_ids: [])
    @pc_ids = pc_ids
    @mandatory_archetype_ids = mandatory_archetype_ids
    @optional_archetype_ids = optional_archetype_ids
    @iterations_used = 0
    @simulation_count = 0

    load_data
  end

  # Run the balancing algorithm
  # @return [Hash] Balanced configuration with composition and variants
  def balance!
    # Get initial estimate from power calculator
    composition = PowerCalculatorService.estimate_balanced_composition(
      pc_power: @pc_power,
      mandatory_archetypes: @mandatory_archetypes,
      optional_archetypes: @optional_archetypes
    )

    stat_modifiers = {} # { archetype_id => modifier }
    best_composition = composition.dup
    best_stat_modifiers = deep_copy(stat_modifiers)
    best_aggregate = nil

    MAX_ITERATIONS.times do |iteration|
      @iterations_used = iteration + 1

      # Run simulations
      results = run_simulations(composition, stat_modifiers)
      aggregate = BalanceScoreCalculator.aggregate_scores(results)

      # Check if balanced
      if aggregate[:is_balanced]
        return build_result(composition, stat_modifiers, aggregate, status: 'balanced')
      end

      # Track best result so far
      if best_aggregate.nil? || is_better_aggregate?(aggregate, best_aggregate)
        best_composition = deep_copy(composition)
        best_stat_modifiers = deep_copy(stat_modifiers)
        best_aggregate = aggregate
      end

      # Adjust based on results
      composition, stat_modifiers = adjust_composition(
        composition, stat_modifiers, aggregate
      )
    end

    # Return best result if we couldn't achieve perfect balance
    build_result(best_composition, best_stat_modifiers, best_aggregate, status: 'approximate')
  end

  # Run a quick balance check without full iteration
  # @param composition [Hash] NPC composition to test
  # @return [Hash] Aggregate scores
  def quick_check(composition, stat_modifiers: {})
    results = run_simulations(composition, stat_modifiers)
    BalanceScoreCalculator.aggregate_scores(results)
  end

  private

  def load_data
    @pc_power = PowerCalculatorService.calculate_pc_group_power(@pc_ids)
    @pc_participants = PowerCalculatorService.pcs_to_participants(@pc_ids)

    @mandatory_archetypes = NpcArchetype.where(id: @mandatory_archetype_ids).all
    @optional_archetypes = NpcArchetype.where(id: @optional_archetype_ids).all
  end

  def run_simulations(composition, stat_modifiers)
    npcs = PowerCalculatorService.composition_to_participants(
      composition,
      stat_modifiers: stat_modifiers
    )

    SIMULATIONS.times.map do |i|
      # Deep copy participants for fresh state
      fresh_pcs = deep_copy_participants(@pc_participants)
      fresh_npcs = deep_copy_participants(npcs)

      sim = CombatSimulatorService.new(
        pcs: fresh_pcs,
        npcs: fresh_npcs,
        arena_width: DEFAULT_ARENA_WIDTH,
        arena_height: DEFAULT_ARENA_HEIGHT,
        seed: i * 100_003 + @iterations_used * 7919
      )

      @simulation_count += 1
      sim.simulate!
    end
  end

  def deep_copy_participants(participants)
    participants.map do |p|
      CombatSimulatorService::SimParticipant.new(
        id: p.id,
        name: p.name,
        is_pc: p.is_pc,
        team: p.team,
        current_hp: p.max_hp, # Reset HP
        max_hp: p.max_hp,
        hex_x: p.hex_x,
        hex_y: p.hex_y,
        damage_bonus: p.damage_bonus,
        defense_bonus: p.defense_bonus,
        speed_modifier: p.speed_modifier,
        damage_dice_count: p.damage_dice_count,
        damage_dice_sides: p.damage_dice_sides,
        stat_modifier: p.stat_modifier,
        ai_profile: p.ai_profile,
        abilities: p.abilities,
        ability_chance: p.ability_chance
      )
    end
  end

  def deep_copy(obj)
    case obj
    when Hash
      obj.transform_values { |v| deep_copy(v) }
    when Array
      obj.map { |v| deep_copy(v) }
    else
      obj
    end
  end

  def is_better_aggregate?(new_agg, old_agg)
    # Prefer higher win rate
    return true if new_agg[:win_rate] > old_agg[:win_rate]
    return false if new_agg[:win_rate] < old_agg[:win_rate]

    # If same win rate, prefer score closer to ideal range
    ideal_mid = (BalanceScoreCalculator::IDEAL_MARGIN_RANGE.min +
                 BalanceScoreCalculator::IDEAL_MARGIN_RANGE.max) / 2.0

    new_distance = (new_agg[:avg_score] - ideal_mid).abs
    old_distance = (old_agg[:avg_score] - ideal_mid).abs

    new_distance < old_distance
  end

  def adjust_composition(composition, stat_modifiers, aggregate)
    adjustment = BalanceScoreCalculator.calculate_adjustment_factor(aggregate)

    if aggregate[:win_rate] < 1.0
      # PCs losing - make fight easier
      make_easier(composition, stat_modifiers, adjustment.abs)
    elsif aggregate[:avg_score] > BalanceScoreCalculator::IDEAL_MARGIN_RANGE.max
      # PCs winning too easily - make fight harder
      make_harder(composition, stat_modifiers, adjustment)
    elsif aggregate[:avg_score] < BalanceScoreCalculator::IDEAL_MARGIN_RANGE.min
      # PCs winning by too little - make slightly easier
      make_easier(composition, stat_modifiers, adjustment.abs * 0.5)
    else
      # Close but not quite - fine tune
      fine_tune(composition, stat_modifiers, aggregate)
    end

    [composition, stat_modifiers]
  end

  def make_easier(composition, stat_modifiers, magnitude)
    # Strategy: reduce mandatory NPC stats first.
    # Only remove optional NPCs if mandatory stats are already at minimum.

    balancing = GameConfig::Combat::BALANCING
    reduced_any = false
    @mandatory_archetype_ids.each do |id|
      current = stat_modifiers[id] || 0.0
      next if current <= balancing[:stat_adjustment_min]

      updated = [current - magnitude, balancing[:stat_adjustment_min]].max
      reduced_any ||= updated < current
      stat_modifiers[id] = updated
    end

    return if reduced_any

    # Mandatory stats are clamped out; now remove one optional NPC if available.
    @optional_archetype_ids.reverse.each do |id|
      next unless composition[id] && composition[id][:count] > 0

      composition[id][:count] -= 1
      composition.delete(id) if composition[id][:count] <= 0
      break # Only remove one at a time
    end
  end

  def make_harder(composition, stat_modifiers, magnitude)
    # Strategy: add optional NPCs first, then boost stats

    # First try: add optional NPCs, preferring the least-represented option
    # to avoid repeatedly stacking the first archetype.
    added = false
    candidates = @optional_archetype_ids.filter_map do |id|
      archetype = NpcArchetype[id]
      next unless archetype

      current_count = composition.dig(id, :count) || 0
      power = composition.dig(id, :power) || PowerCalculatorService.calculate_archetype_power(archetype)
      { id: id, count: current_count, power: power }
    end

    candidate = candidates.min_by { |c| [c[:count], -c[:power], c[:id]] }
    if candidate
      id = candidate[:id]
      composition[id] ||= { count: 0, power: candidate[:power] }
      composition[id][:count] += 1
      added = true
    end

    # If no optionals available, boost mandatory NPC stats
    unless added
      balancing = GameConfig::Combat::BALANCING
      @mandatory_archetype_ids.each do |id|
        current = stat_modifiers[id] || 0.0
        stat_modifiers[id] = [current + magnitude, balancing[:stat_adjustment_max]].min
      end
    end
  end

  def fine_tune(composition, stat_modifiers, aggregate)
    # Make small adjustments based on score position
    ideal_mid = (BalanceScoreCalculator::IDEAL_MARGIN_RANGE.min +
                 BalanceScoreCalculator::IDEAL_MARGIN_RANGE.max) / 2.0

    balancing = GameConfig::Combat::BALANCING
    if aggregate[:avg_score] < ideal_mid
      # Slightly too hard
      @mandatory_archetype_ids.each do |id|
        current = stat_modifiers[id] || 0.0
        stat_modifiers[id] = [current - balancing[:fine_tune_adjustment], -balancing[:fine_tune_limit]].max
      end
    else
      # Slightly too easy
      @mandatory_archetype_ids.each do |id|
        current = stat_modifiers[id] || 0.0
        stat_modifiers[id] = [current + balancing[:fine_tune_adjustment], balancing[:fine_tune_limit]].min
      end
    end
  end

  def build_result(composition, stat_modifiers, aggregate, status:)
    safe_composition = deep_copy(composition)
    safe_modifiers = deep_copy(stat_modifiers)

    {
      composition: safe_composition,
      stat_modifiers: safe_modifiers,
      aggregate: aggregate,
      difficulty_variants: generate_difficulty_variants(safe_composition, safe_modifiers),
      pc_power: @pc_power,
      iterations_used: @iterations_used,
      simulation_count: @simulation_count,
      status: status
    }
  end

  def generate_difficulty_variants(base_composition, base_modifiers)
    balancing = GameConfig::Combat::BALANCING
    {
      'easy' => apply_difficulty_variant(base_composition, base_modifiers, balancing[:difficulty_easy_modifier]),
      'normal' => { composition: deep_copy(base_composition), stat_modifiers: deep_copy(base_modifiers) },
      'hard' => apply_difficulty_variant(base_composition, base_modifiers, balancing[:difficulty_hard_modifier]),
      'nightmare' => apply_difficulty_variant(base_composition, base_modifiers, balancing[:difficulty_nightmare_modifier])
    }
  end

  def apply_difficulty_variant(composition, base_modifiers, modifier)
    balancing = GameConfig::Combat::BALANCING
    new_modifiers = deep_copy(base_modifiers)

    composition.each_key do |id|
      current = new_modifiers[id] || 0.0
      new_modifiers[id] = (current + modifier).clamp(balancing[:difficulty_clamp_min], balancing[:difficulty_clamp_max])
    end

    { composition: deep_copy(composition), stat_modifiers: new_modifiers }
  end
end
