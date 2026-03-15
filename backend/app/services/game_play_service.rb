# frozen_string_literal: true

class GamePlayService
  DEFAULT_STAT_BASELINE = 5

  class << self
    # Play a game and get a result
    # @param game_instance [GameInstance]
    # @param branch [GamePatternBranch]
    # @param character_instance [CharacterInstance]
    # @return [Hash] result with :success, :result, :message, :points, :total_score
    def play(game_instance, branch, character_instance)
      results = branch.results
      return { success: false, error: 'No results configured for this game' } if results.empty?

      # Calculate weights and stat modifier
      weights = calculate_weights(results)
      modifier = calculate_stat_modifier(branch, character_instance, character_instance.current_room)

      # Select result
      selected = select_result(results, weights, modifier)

      # Update score if scoring enabled
      points = selected.point_value
      total_score = nil

      if game_instance.scoring?
        score_record = GameScore.for_player(game_instance, character_instance)
        score_record.add_points(points)
        total_score = score_record.score
      end

      {
        success: true,
        result: selected,
        message: selected.message,
        points: points,
        total_score: total_score,
        game_name: game_instance.display_name,
        branch_name: branch.display_name
      }
    end

    # Calculate probability weights for results (best = rare, worst = common)
    # @param results [Array<GamePatternResult>] ordered by position
    # @return [Array<Float>] weights summing to ~100
    def calculate_weights(results)
      count = results.count
      return [100.0] if count == 1

      # Exponential distribution: each position gets increasingly more weight
      # Position 1 (best): base weight
      # Position n (worst): highest weight
      base = 5.0
      growth = 2.0

      raw_weights = results.map.with_index do |_, idx|
        base * (growth ** idx)
      end

      # Normalize to sum to 100
      total = raw_weights.sum
      raw_weights.map { |w| (w / total) * 100.0 }
    end

    # Calculate stat modifier by comparing to room and world averages
    # @param branch [GamePatternBranch]
    # @param character_instance [CharacterInstance]
    # @param room [Room]
    # @return [Float] modifier between -GameConfig::Combat::MODIFIER_CAP and +GameConfig::Combat::MODIFIER_CAP
    def calculate_stat_modifier(branch, character_instance, room)
      return 0.0 unless branch.uses_stat?

      stat = branch.stat
      return 0.0 unless stat

      player_value = stat_value(character_instance, stat)
      return 0.0 unless player_value

      room_avg = calculate_room_average(room, stat, character_instance)
      world_avg = calculate_world_average(stat)

      # Calculate differences as percentages
      room_diff = room_avg > 0 ? (player_value - room_avg) / room_avg.to_f : 0.0
      world_diff = world_avg > 0 ? (player_value - world_avg) / world_avg.to_f : 0.0

      # Average the two comparisons
      combined = (room_diff + world_diff) / 2.0

      # Cap the modifier
      combined.clamp(-GameConfig::Combat::MODIFIER_CAP, GameConfig::Combat::MODIFIER_CAP)
    end

    private

    # Select a result based on weights and stat modifier
    def select_result(results, weights, modifier)
      # Roll a random number 0-100
      roll = rand * 100.0

      # Apply modifier as chance to bump up/down
      bump_direction = 0
      if modifier.abs > 0
        bump_roll = rand
        if bump_roll < modifier.abs
          bump_direction = modifier > 0 ? -1 : 1 # Negative position = better result
        end
      end

      # Find which result the roll lands on
      cumulative = 0.0
      selected_idx = results.length - 1

      weights.each_with_index do |weight, idx|
        cumulative += weight
        if roll <= cumulative
          selected_idx = idx
          break
        end
      end

      # Apply bump
      selected_idx = (selected_idx + bump_direction).clamp(0, results.length - 1)

      results[selected_idx]
    end

    def stat_value(character_instance, stat)
      cs = character_instance.character_stats.find { |s| s.stat_id == stat.id }
      cs&.current_value || DEFAULT_STAT_BASELINE
    end

    def calculate_room_average(room, stat, exclude_character)
      return DEFAULT_STAT_BASELINE unless room

      others = room.character_instances.reject { |ci| ci.id == exclude_character.id }
      return DEFAULT_STAT_BASELINE if others.empty?

      values = others.map { |ci| stat_value(ci, stat) }.compact
      return DEFAULT_STAT_BASELINE if values.empty?

      values.sum / values.count.to_f
    end

    def calculate_world_average(stat)
      # Get average from all online characters
      online_instances = CharacterInstance.where(online: true).all
      return DEFAULT_STAT_BASELINE if online_instances.empty?

      values = online_instances.map { |ci| stat_value(ci, stat) }.compact
      return DEFAULT_STAT_BASELINE if values.empty?

      values.sum / values.count.to_f
    end
  end
end
