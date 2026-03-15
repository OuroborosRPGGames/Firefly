# frozen_string_literal: true

# Calculates balance scores from combat simulation results.
# Used by BattleBalancingService to determine if an encounter is balanced.
#
# Scoring Philosophy:
# - Winning is good, but winning too easily means the fight is too easy
# - Winning by a small margin (low HP, many rounds) = well-balanced
# - Taking casualties is bad but not catastrophic
# - Losing is always bad (score -1000)
#
# Target Score Range: 30-80 = "balanced" (PCs win but by narrow margin)
#
# @example
#   results = [sim1.simulate!, sim2.simulate!, ...]
#   aggregate = BalanceScoreCalculator.aggregate_scores(results)
#   aggregate[:is_balanced]  # => true if 100% win rate and score in range
#
class BalanceScoreCalculator
  # Weight configuration for score components
  WEIGHTS = {
    hp_remaining: 10,        # Per HP across surviving PCs
    rounds_taken: -2,        # Penalty per round (longer = harder)
    ko_penalty: -50,         # Per PC knocked out
    total_victory_bonus: 100 # All PCs survive bonus
  }.freeze

  # Target score range for "balanced" encounter
  # Score too high = fight too easy
  # Score too low = fight too hard
  IDEAL_MARGIN_RANGE = (30..80)

  # Minimum acceptable win rate for balanced encounter
  # 95% allows for occasional bad dice without over-nerfing encounters
  MINIMUM_WIN_RATE = 0.95

  # Score a single simulation result
  # @param sim_result [CombatSimulatorService::SimResult]
  # @return [Hash] Score breakdown with :score, :components
  def self.score_result(sim_result)
    return { score: -1000, components: { loss: true } } unless sim_result.pc_victory

    hp_score = sim_result.total_pc_hp_remaining * WEIGHTS[:hp_remaining]
    rounds_score = sim_result.rounds_taken * WEIGHTS[:rounds_taken]
    ko_score = sim_result.pc_ko_count * WEIGHTS[:ko_penalty]
    victory_bonus = sim_result.pc_ko_count.zero? ? WEIGHTS[:total_victory_bonus] : 0

    total = hp_score + rounds_score + ko_score + victory_bonus

    {
      score: total,
      components: {
        hp_score: hp_score,
        rounds_score: rounds_score,
        ko_score: ko_score,
        victory_bonus: victory_bonus
      }
    }
  end

  # Aggregate scores from multiple simulation results
  # @param results [Array<CombatSimulatorService::SimResult>]
  # @return [Hash] Aggregated statistics
  def self.aggregate_scores(results)
    return empty_aggregate if results.empty?

    wins = results.count(&:pc_victory)
    losses = results.count - wins
    win_rate = wins.to_f / results.count

    # Score only winning results
    win_results = results.select(&:pc_victory)
    scores = win_results.map { |r| score_result(r)[:score] }
    avg_score = scores.empty? ? -1000 : scores.sum.to_f / scores.count

    # Calculate variance for consistency check
    variance = calculate_variance(scores)
    std_dev = Math.sqrt(variance)

    # Other statistics
    avg_rounds = win_results.empty? ? 0 : win_results.sum(&:rounds_taken).to_f / win_results.count
    avg_pc_hp = win_results.empty? ? 0 : win_results.sum(&:total_pc_hp_remaining).to_f / win_results.count
    total_pc_kos = results.sum(&:pc_ko_count)
    avg_pc_kos = total_pc_kos.to_f / results.count

    # Determine balance status
    is_balanced = win_rate >= MINIMUM_WIN_RATE && IDEAL_MARGIN_RANGE.cover?(avg_score)

    # Determine direction of imbalance for adjustment hints
    adjustment_hint = if win_rate < MINIMUM_WIN_RATE
                        :make_easier
                      elsif avg_score > IDEAL_MARGIN_RANGE.max
                        :make_harder
                      elsif avg_score < IDEAL_MARGIN_RANGE.min
                        :make_easier
                      else
                        :balanced
                      end

    {
      win_rate: win_rate,
      loss_count: losses,
      avg_score: avg_score.round(2),
      score_std_dev: std_dev.round(2),
      min_score: scores.min || -1000,
      max_score: scores.max || -1000,
      avg_rounds: avg_rounds.round(1),
      avg_pc_hp_remaining: avg_pc_hp.round(1),
      avg_pc_kos: avg_pc_kos.round(2),
      is_balanced: is_balanced,
      adjustment_hint: adjustment_hint,
      in_ideal_range: IDEAL_MARGIN_RANGE.cover?(avg_score)
    }
  end

  # Determine how much to adjust difficulty based on current scores
  # @param aggregate [Hash] Result from aggregate_scores
  # @return [Float] Adjustment factor (-0.5 to 0.4, negative = easier, positive = harder)
  def self.calculate_adjustment_factor(aggregate)
    return -0.5 if aggregate[:win_rate] < 0.5 # Major adjustment if losing a lot

    # Small adjustment if winning less than minimum threshold
    return -0.2 if aggregate[:win_rate] < MINIMUM_WIN_RATE

    avg_score = aggregate[:avg_score]
    ideal_mid = (IDEAL_MARGIN_RANGE.min + IDEAL_MARGIN_RANGE.max) / 2.0

    # Calculate how far from ideal we are
    if avg_score > IDEAL_MARGIN_RANGE.max
      # Too easy - needs to be harder
      distance = avg_score - ideal_mid
      # Scale: score 100 above ideal = +0.3 adjustment
      [distance / 333.0, 0.4].min
    elsif avg_score < IDEAL_MARGIN_RANGE.min
      # Too hard - needs to be easier
      distance = ideal_mid - avg_score
      # Scale: score 50 below ideal = -0.2 adjustment
      [-distance / 250.0, -0.4].max
    else
      # Balanced!
      0.0
    end
  end

  # Format aggregate results for display
  # @param aggregate [Hash]
  # @return [String]
  def self.format_aggregate(aggregate)
    status = if aggregate[:is_balanced]
               "BALANCED"
             elsif aggregate[:adjustment_hint] == :make_easier
               "TOO HARD"
             else
               "TOO EASY"
             end

    lines = [
      "=== Balance Analysis ===",
      "Status: #{status}",
      "Win Rate: #{(aggregate[:win_rate] * 100).round(1)}%",
      "Avg Score: #{aggregate[:avg_score]} (target: #{IDEAL_MARGIN_RANGE})",
      "Score Std Dev: #{aggregate[:score_std_dev]}",
      "Avg Rounds: #{aggregate[:avg_rounds]}",
      "Avg PC HP Remaining: #{aggregate[:avg_pc_hp_remaining]}",
      "Avg PC KOs: #{aggregate[:avg_pc_kos]}"
    ]

    lines.join("\n")
  end

  private_class_method def self.empty_aggregate
    {
      win_rate: 0.0,
      loss_count: 0,
      avg_score: -1000,
      score_std_dev: 0.0,
      min_score: -1000,
      max_score: -1000,
      avg_rounds: 0.0,
      avg_pc_hp_remaining: 0.0,
      avg_pc_kos: 0.0,
      is_balanced: false,
      adjustment_hint: :make_easier,
      in_ideal_range: false
    }
  end

  private_class_method def self.calculate_variance(scores)
    return 0.0 if scores.empty?

    mean = scores.sum.to_f / scores.count
    sum_squares = scores.sum { |s| (s - mean)**2 }
    sum_squares / scores.count
  end
end
