# frozen_string_literal: true

# Service to run ability balance simulations from the web admin interface.
# Wraps the CLI script's FormulaAutoTuner for web-callable execution.
#
# @example Run simulation with defaults
#   service = AbilitySimulatorRunnerService.new
#   results = service.run!
#
# @example Run fresh simulation with more iterations
#   service = AbilitySimulatorRunnerService.new(mode: :fresh, iterations: 500)
#   results = service.run!
#
class AbilitySimulatorRunnerService
  SCRIPT_PATH = File.join(__dir__, '../../../scripts/ability_balance_simulator.rb')

  # Grid search points for finding balance
  GRID_SEARCH_POINTS = [0.1, 0.2, 0.3, 0.4, 0.5, 0.7, 1.0, 1.5, 2.0, 3.0].freeze

  # Final balance threshold - how far from 50% win rate is acceptable
  FINAL_THRESHOLD = 5.0

  attr_reader :results, :mode, :iterations

  # @param mode [Symbol] :fresh (start from defaults) or :refine (use current values)
  # @param iterations [Integer] number of iterations for final validation (10-1000)
  def initialize(mode: :refine, iterations: 200)
    @mode = mode
    @iterations = iterations.to_i.clamp(10, 1000)
    @results = {}
  end

  # Run the ability balance simulation
  # @return [Hash] results keyed by coefficient name
  def run!
    load_script_classes!

    # Load coefficients in the appropriate mode
    BalanceCoefficients.load!(mode: @mode)

    # Get all generated abilities
    abilities = AbilityGenerator.generate_all

    abilities.each do |config|
      coef_key = config[:coef_key]
      next unless coef_key

      # Skip locked coefficients
      if AbilityPowerWeights.locked?(coef_key.to_s)
        @results[coef_key.to_s] = {
          'win_rate' => nil,
          'original' => BalanceCoefficients.get(coef_key),
          'final' => BalanceCoefficients.get(coef_key),
          'balanced' => nil,
          'locked' => true
        }
        next
      end

      tune_coefficient(config)
    end

    # Save the tuned coefficients
    BalanceCoefficients.save!

    # Store results in AbilityPowerWeights for persistence
    AbilityPowerWeights.set_last_run(
      timestamp: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
      mode: @mode,
      iterations: @iterations,
      results: @results
    )
    AbilityPowerWeights.save!

    @results
  end

  private

  def load_script_classes!
    # Load the script if not already loaded
    # This brings in BalanceCoefficients, AbilityGenerator, BalanceSimulator, etc.
    load SCRIPT_PATH unless defined?(BalanceCoefficients) && defined?(AbilityGenerator) && defined?(BalanceSimulator)
  end

  def tune_coefficient(config)
    ability = config[:ability]
    coef_key = config[:coef_key]
    original = BalanceCoefficients.get(coef_key)

    # Phase 1: Grid search to find approximate balance point
    grid_results = []
    GRID_SEARCH_POINTS.each do |coef|
      clamped = clamp_coefficient(coef_key, coef)
      BalanceCoefficients.set(coef_key, clamped)

      sim = BalanceSimulator.new(config)
      sim.run(iterations: [100, @iterations / 2].min)
      rate = sim.win_rate
      grid_results << { coef: clamped, rate: rate, deviation: (rate - 50).abs }
    end

    # Find the coefficient closest to 50%
    best = grid_results.min_by { |r| r[:deviation] }
    current = best[:coef]

    # Phase 2: Local refinement around the best point
    refinement_range = [
      current * 0.5, current * 0.7, current * 0.85,
      current,
      current * 1.15, current * 1.3, current * 1.5
    ]
    refinement_results = []

    refinement_range.each do |coef|
      clamped = clamp_coefficient(coef_key, coef)
      BalanceCoefficients.set(coef_key, clamped)

      sim = BalanceSimulator.new(config)
      sim.run(iterations: [100, @iterations / 2].min)
      rate = sim.win_rate
      refinement_results << { coef: clamped, rate: rate, deviation: (rate - 50).abs }
    end

    best_refined = refinement_results.min_by { |r| r[:deviation] }
    current = best_refined[:coef]

    # Final validation with full iterations
    BalanceCoefficients.set(coef_key, current)
    sim = BalanceSimulator.new(config)
    sim.run(iterations: @iterations)
    final_rate = sim.win_rate

    balanced = (final_rate - 50).abs <= GameConfig::AbilityPower::FINAL_THRESHOLD

    @results[coef_key.to_s] = {
      'win_rate' => final_rate.round(1),
      'original' => original,
      'final' => current,
      'balanced' => balanced,
      'locked' => false
    }
  end

  def clamp_coefficient(key, value)
    key_str = key.to_s
    case key
    when :heal_mult
      value.clamp(0.1, 10.0)
    else
      case key_str
      when /^cc_/       then value.clamp(0.1, 20.0)
      when /^dot_/      then value.clamp(0.01, 15.0)
      when /^vuln_/     then value.clamp(0.1, 15.0)
      when /^debuff_/   then value.clamp(0.1, 15.0)
      when /^buff_/     then value.clamp(0.1, 15.0)
      when /^armor_/    then value.clamp(0.1, 20.0)
      when /^protect_/  then value.clamp(0.1, 20.0)
      when /^shield_/   then value.clamp(0.1, 20.0)
      when /^aoe_circle_r/ then value.clamp(0.5, 15.0)
      else value.clamp(0.1, 20.0)
      end
    end
  end
end
