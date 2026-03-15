# frozen_string_literal: true

# Stores pre-calculated balanced encounter configurations.
# Created by BattleBalancingService and used when spawning fights.
#
# @example
#   # Create and balance an encounter
#   encounter = BalancedEncounter.create(
#     name: 'Boss Fight',
#     universe_id: 1,
#     mandatory_npc_archetype_ids: [10],
#     optional_npc_archetype_ids: [20, 21],
#     pc_character_ids: [1, 2, 3, 4]
#   )
#   encounter.balance!
#
#   # Use the balanced configuration
#   encounter.spawn_fight(room: room, difficulty: 'hard')
#
# Skip loading if table doesn't exist
return unless DB.table_exists?(:balanced_encounters)

class BalancedEncounter < Sequel::Model(:balanced_encounters)
  unrestrict_primary_key
  set_primary_key :id
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :universe

  def validate
    super
    validates_presence [:name]
  end

  # Run balancing algorithm and store results
  # @return [Boolean] Whether balancing succeeded
  def balance!
    balancer = BattleBalancingService.new(
      pc_ids: pc_character_ids || [],
      mandatory_archetype_ids: mandatory_npc_archetype_ids || [],
      optional_archetype_ids: optional_npc_archetype_ids || []
    )

    result = balancer.balance!

    update(
      balanced_composition: result[:composition],
      stat_modifiers: result[:stat_modifiers],
      difficulty_variants: result[:difficulty_variants],
      pc_power: result[:pc_power],
      npc_power: calculate_npc_power(result[:composition]),
      avg_win_margin: result[:aggregate][:avg_score],
      avg_rounds: result[:aggregate][:avg_rounds],
      avg_pc_casualties: result[:aggregate][:avg_pc_kos],
      simulations_run: result[:simulation_count],
      iterations_used: result[:iterations_used],
      status: result[:status],
      balanced_at: Time.now
    )

    status == 'balanced' || status == 'approximate'
  rescue StandardError => e
    warn "[BalancedEncounter] balance! failed for encounter #{id || 'new'}: #{e.message}"
    begin
      update(status: 'failed', balanced_at: Time.now)
    rescue StandardError => update_error
      warn "[BalancedEncounter] Failed to persist failed status for encounter #{id || 'new'}: #{update_error.message}"
    end
    false
  end

  # Get configuration for a specific difficulty level
  # @param difficulty [String] 'easy', 'normal', 'hard', or 'nightmare'
  # @return [Hash] { composition:, stat_modifiers: } with symbolized keys
  def configuration_for(difficulty)
    variants = difficulty_variants || {}
    variant = variants[difficulty] || variants['normal']
    config = variant || {
      composition: balanced_composition,
      stat_modifiers: stat_modifiers
    }
    symbolize_config(config)
  end

  # Get NPC participants for simulation or spawning
  # @param difficulty [String] Difficulty level
  # @return [Array<CombatSimulatorService::SimParticipant>]
  def npc_participants(difficulty: 'normal')
    config = configuration_for(difficulty)
    PowerCalculatorService.composition_to_participants(
      config[:composition] || balanced_composition || {},
      stat_modifiers: config[:stat_modifiers] || stat_modifiers || {}
    )
  end

  # Get PC participants
  # @return [Array<CombatSimulatorService::SimParticipant>]
  def pc_participants
    PowerCalculatorService.pcs_to_participants(pc_character_ids || [])
  end

  # Run a quick simulation to verify balance still holds
  # @param difficulty [String] Difficulty to test
  # @return [Hash] Aggregate scores
  def verify_balance(difficulty: 'normal')
    config = configuration_for(difficulty)

    balancer = BattleBalancingService.new(
      pc_ids: pc_character_ids || [],
      mandatory_archetype_ids: mandatory_npc_archetype_ids || [],
      optional_archetype_ids: optional_npc_archetype_ids || []
    )

    balancer.quick_check(
      config[:composition] || balanced_composition || {},
      stat_modifiers: config[:stat_modifiers] || stat_modifiers || {}
    )
  rescue StandardError => e
    warn "[BalancedEncounter] verify_balance failed for encounter #{id || 'new'} (difficulty=#{difficulty}): #{e.message}"
    BalanceScoreCalculator.aggregate_scores([]).merge(error: e.message)
  end

  # Format for display
  # @return [String]
  def summary
    lines = [
      "=== #{name} ===",
      "Status: #{status}",
      "PC Power: #{pc_power&.round(1)}",
      "NPC Power: #{npc_power&.round(1)}",
      "Avg Win Margin: #{avg_win_margin&.round(1)}",
      "Avg Rounds: #{avg_rounds&.round(1)}",
      "Simulations: #{simulations_run}",
      "",
      "Composition:"
    ]

    (balanced_composition || {}).each do |archetype_id, config|
      archetype = NpcArchetype[archetype_id.to_i]
      arch_name = archetype&.name || "Archetype ##{archetype_id}"
      cfg = config.is_a?(Hash) ? config.transform_keys(&:to_sym) : {}
      count = cfg[:count] || 1
      lines << "  #{count}x #{arch_name}"
    end

    lines.join("\n")
  end

  # Check if balance is still valid (PCs haven't changed significantly)
  # @return [Boolean]
  def balance_valid?
    return false unless balanced_at
    return false if status != 'balanced' && status != 'approximate'

    # Check if PC power is still similar
    current_pc_power = PowerCalculatorService.calculate_pc_group_power(pc_character_ids || [])
    power_diff = (current_pc_power - (pc_power || 0)).abs / [pc_power || 1, 1].max

    # Allow 20% power drift before rebalancing
    power_diff < 0.2
  end

  private

  # Normalize config hash keys to symbols for consistent access
  def symbolize_config(config)
    return config unless config.is_a?(Hash)

    config.transform_keys(&:to_sym)
  end

  def calculate_npc_power(composition)
    return 0 unless composition

    composition.sum do |archetype_id, config|
      archetype = NpcArchetype[archetype_id.to_i]
      next 0 unless archetype

      cfg = config.is_a?(Hash) ? config.transform_keys(&:to_sym) : {}
      count = cfg[:count] || 1
      power = PowerCalculatorService.calculate_archetype_power(archetype)
      count * power
    end
  end
end
