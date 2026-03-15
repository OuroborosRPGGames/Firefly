# frozen_string_literal: true

# Resolves activity rounds by processing participant choices, rolling dice,
# and determining success/failure based on the activity mechanics.
#
# Dice Mechanics:
# - Base roll: 2d8 + stats (exploding on 8) via DiceRollService
# - Willpower: up to 2 additional d8s (exploding), costs willpower
# - Risk dice: d4 with values [-4,-3,-2,-1,+1,+2,+3,+4]
# - Help: grants advantage (roll 2, take higher - unless either is 1, must take 1)
# - Success: highest_roll + avg(risk_rolls) >= DC
#
# Observer Effects (remote support/opposition):
# - reroll_ones: Reroll any dice that show 1
# - block_explosions: 8s don't explode (cap at 8)
# - damage_on_ones: If any die shows 1, take 1 damage
# - block_willpower: Prevent willpower dice from being added
# - stat_swap: Use observer's specified stat instead of action's stat
class ActivityResolutionService
  class ResolutionError < StandardError; end

  # Risk dice values (d4 variant)
  RISK_VALUES = [-4, -3, -2, -1, 1, 2, 3, 4].freeze

  # Result structure for individual participant rolls
  ParticipantRoll = Struct.new(
    :participant_id,
    :character_name,
    :action_type,      # 'option', 'help', 'recover'
    :action_name,
    :dice_results,     # Array of individual dice faces
    :stat_bonus,
    :willpower_spent,
    :risk_result,
    :total,
    :helped_by,        # Array of helper names
    :observer_effects, # Array of effect names applied
    :animation_data,   # String for webclient dice animation
    keyword_init: true
  )

  # Result structure for individual task outcomes
  TaskResult = Struct.new(
    :task_id,
    :task_description,
    :success,
    :dc,
    :highest_roll,
    :avg_risk,
    :final_total,
    keyword_init: true
  )

  # Result structure for round resolution
  RoundResult = Struct.new(
    :success,
    :highest_roll,
    :avg_risk,
    :final_total,
    :dc,
    :participant_rolls, # Array of ParticipantRoll
    :emit_text,
    :result_text,
    :task_results,      # Array of TaskResult (nil for non-task rounds)
    keyword_init: true
  )

  class << self
    # Resolve a round for an activity instance
    # @param instance [ActivityInstance] The running activity instance
    # @param round [ActivityRound] The round to resolve
    # @return [RoundResult]
    def resolve(instance, round)
      raise ResolutionError, 'No active participants' if instance.active_participants.empty?

      # Dispatch to task-based resolution when tasks exist
      return resolve_with_tasks(instance, round) if round.has_tasks?

      participants = instance.active_participants.all

      # Process recoveries first (they gain willpower, don't roll)
      process_recoveries(participants)

      # Calculate help bonuses
      help_map = calculate_help_bonuses(participants)

      # Roll for each participant doing an action
      participant_rolls = []
      roll_totals = []
      risk_totals = []

      participants.each do |p|
        next unless p.has_chosen?

        # Determine action type based on effort - check BEFORE getting action
        action_type = determine_action_type(p)

        if action_type == 'help'
          # Helpers don't roll themselves
          participant_rolls << build_help_roll(p)
          next
        end

        if action_type == 'recover'
          participant_rolls << build_recover_roll(p)
          next
        end

        # Regular action - need an action to roll against
        action = p.chosen_action

        # For mandatory roll rounds (reflex/group_check) without a chosen action,
        # roll using the round's stat configuration directly
        if action.nil? && round.mandatory_roll?
          roll_result = roll_for_mandatory(p, round, help_map[p.id])
        elsif action.nil?
          next
        else
          # Regular action - roll dice
          roll_result = roll_for_participant(p, action, help_map[p.id])
        end

        # Update participant with roll result
        p.update(
          roll_result: roll_result.total,
          expect_roll: round.difficulty_class || instance.current_difficulty
        )

        participant_rolls << roll_result
        roll_totals << roll_result.total
        risk_totals << roll_result.risk_result if roll_result.risk_result
      end

      # Calculate success
      highest_roll = roll_totals.max || 0
      avg_risk = risk_totals.empty? ? 0 : risk_totals.sum.to_f / risk_totals.size
      final_total = highest_roll + avg_risk

      dc = round.difficulty_class || instance.current_difficulty || 10
      success = final_total >= dc

      # Determine result text
      result_text = success ? (round.success_text || 'Success!') : (round.failure_text || 'Failed!')

      RoundResult.new(
        success: success,
        highest_roll: highest_roll,
        avg_risk: avg_risk.round(2),
        final_total: final_total.round(2),
        dc: dc,
        participant_rolls: participant_rolls,
        emit_text: round.emit_text,
        result_text: result_text,
        task_results: nil
      )
    end

    # Resolve a round that has tasks assigned
    # Each active task must be passed for overall success
    def resolve_with_tasks(instance, round)
      participants = instance.active_participants.all
      participant_count = participants.size

      # Process recoveries
      process_recoveries(participants)

      # Calculate help bonuses (only within same task)
      help_map = calculate_help_bonuses_with_tasks(participants)

      active_tasks = round.active_tasks(participant_count)
      multi_task = active_tasks.size > 1
      base_dc = round.difficulty_class || instance.current_difficulty || 10

      all_participant_rolls = []
      task_results = []

      active_tasks.each do |task|
        # DC reduction when multiple tasks are active
        task_dc = multi_task ? [base_dc - (task.dc_reduction || 3), 1].max : base_dc

        # Get participants assigned to this task
        task_participants = participants.select do |p|
          tc = p[:task_chosen]
          tc == task.id
        end

        roll_totals = []
        risk_totals = []

        task_participants.each do |p|
          next unless p.has_chosen?

          action_type = determine_action_type(p)

          if action_type == 'help'
            all_participant_rolls << build_help_roll(p)
            next
          end

          if action_type == 'recover'
            all_participant_rolls << build_recover_roll(p)
            next
          end

          action = p.chosen_action

          # For mandatory roll rounds without a specific action, use stat-only roll
          if action.nil? && round.mandatory_roll?
            roll_result = roll_for_mandatory(p, round, help_map[p.id])
          elsif action.nil?
            next
          else
            # Use task-aware stat bonus
            roll_result = roll_for_participant_with_task(p, action, help_map[p.id])
          end

          p.update(
            roll_result: roll_result.total,
            expect_roll: task_dc
          )

          all_participant_rolls << roll_result
          roll_totals << roll_result.total
          risk_totals << roll_result.risk_result if roll_result.risk_result
        end

        highest = roll_totals.max || 0
        avg_risk = risk_totals.empty? ? 0 : risk_totals.sum.to_f / risk_totals.size
        final = highest + avg_risk
        task_success = final >= task_dc

        task_results << TaskResult.new(
          task_id: task.id,
          task_description: task.description,
          success: task_success,
          dc: task_dc,
          highest_roll: highest,
          avg_risk: avg_risk.round(2),
          final_total: final.round(2)
        )
      end

      # Overall success = all active tasks passed
      overall_success = task_results.all?(&:success)

      # Aggregate numbers for backward-compatible fields
      best_roll = task_results.map(&:highest_roll).max || 0
      combined_risk = task_results.map(&:avg_risk).sum
      combined_final = task_results.map(&:final_total).max || 0

      result_text = overall_success ? (round.success_text || 'Success!') : (round.failure_text || 'Failed!')

      RoundResult.new(
        success: overall_success,
        highest_roll: best_roll,
        avg_risk: combined_risk.round(2),
        final_total: combined_final.round(2),
        dc: base_dc,
        participant_rolls: all_participant_rolls,
        emit_text: round.emit_text,
        result_text: result_text,
        task_results: task_results
      )
    end

    # ========================================
    # Dice Rolling (via DiceRollService)
    # ========================================

    # Roll base 2d8 with potential advantage from helpers.
    # @param helper_count [Integer] Number of helpers providing advantage
    # @param explode [Boolean] Whether 8s should explode
    # @return [DiceRollService::RollResult] with individual faces and explosion tracking
    def roll_base_dice(helper_count, explode: true)
      explode_on = explode ? 8 : nil

      case helper_count
      when 0
        DiceRollService.roll(2, 8, explode_on: explode_on)
      when 1
        # First die gets advantage, second is normal
        die1 = roll_single_with_advantage(explode: explode)
        die2 = DiceRollService.roll(1, 8, explode_on: explode_on)
        merge_roll_results(die1, die2, explode_on: explode_on)
      else
        # Both dice get advantage
        die1 = roll_single_with_advantage(explode: explode)
        die2 = roll_single_with_advantage(explode: explode)
        merge_roll_results(die1, die2, explode_on: explode_on)
      end
    end

    # Roll a single d8 with advantage (roll 2, take higher).
    # Critical failure: if either initial face is 1, must take 1.
    # @return [DiceRollService::RollResult]
    def roll_single_with_advantage(explode: true)
      explode_on = explode ? 8 : nil
      roll1 = DiceRollService.roll(1, 8, explode_on: explode_on)
      roll2 = DiceRollService.roll(1, 8, explode_on: explode_on)

      # Critical failure: if either initial face is 1, must take 1
      if roll1.base_dice[0] == 1 || roll2.base_dice[0] == 1
        return DiceRollService::RollResult.new(
          dice: [1], base_dice: [1], explosions: [],
          modifier: 0, total: 1, count: 1, sides: 8,
          explode_on: explode_on
        )
      end

      # Take higher total
      roll1.total >= roll2.total ? roll1 : roll2
    end

    # Merge two single-die RollResults into one combined 2-die result.
    def merge_roll_results(r1, r2, explode_on: 8)
      all_dice = r1.dice + r2.dice
      explosions = r1.explosions.dup
      r2.explosions.each { |idx| explosions << (r1.dice.length + idx) }

      DiceRollService::RollResult.new(
        dice: all_dice,
        base_dice: r1.base_dice + r2.base_dice,
        explosions: explosions,
        modifier: 0,
        total: all_dice.sum,
        count: 2,
        sides: 8,
        explode_on: explode_on
      )
    end

    # Append willpower dice results to a base roll result.
    def append_willpower(base_result, wp_result)
      all_dice = base_result.dice + wp_result.dice
      explosions = base_result.explosions.dup
      wp_result.explosions.each { |idx| explosions << (base_result.dice.length + idx) }

      DiceRollService::RollResult.new(
        dice: all_dice,
        base_dice: base_result.base_dice,
        explosions: explosions,
        modifier: base_result.modifier,
        total: all_dice.sum + base_result.modifier,
        count: base_result.count,
        sides: 8,
        explode_on: base_result.explode_on
      )
    end

    # Reroll any dice faces showing 1, returning new dice/explosion arrays.
    # @param dice [Array<Integer>] Individual die faces
    # @param explosions [Array<Integer>] Explosion source indices
    # @param explode [Boolean] Whether rerolls can explode
    # @return [Array<(Array<Integer>, Array<Integer>)>] [new_dice, new_explosions]
    def reroll_ones(dice, explosions, explode: true)
      explode_on = explode ? 8 : nil
      new_dice = []
      new_explosions = []

      dice.each_with_index do |face, idx|
        if face == 1
          reroll = DiceRollService.roll(1, 8, explode_on: explode_on)
          reroll.explosions.each { |exp_idx| new_explosions << (new_dice.length + exp_idx) }
          new_dice.concat(reroll.dice)
        else
          new_explosions << new_dice.length if explosions.include?(idx)
          new_dice << face
        end
      end

      [new_dice, new_explosions]
    end

    # Roll risk dice (d4 with ±1-4 values)
    # @return [Integer]
    def roll_risk_dice
      RISK_VALUES.sample
    end

    # Roll variable risk dice (d{sides} with ±1..sides values)
    # @param sides [Integer] Number of sides (e.g. 3 = d3)
    # @return [Integer, nil]
    def roll_variable_risk(sides)
      return nil unless sides && sides > 0

      value = rand(1..sides)
      rand < 0.5 ? -value : value
    end

    # ========================================
    # Main Rolling Methods
    # ========================================

    # Roll dice for a single participant with a chosen action.
    # @param participant [ActivityParticipant]
    # @param action [ActivityAction]
    # @param help_bonus [Hash, nil] Help bonus information
    # @return [ParticipantRoll]
    def roll_for_participant(participant, action, help_bonus = nil)
      roll_for_participant_internal(participant, action, help_bonus,
                                    stat_method: :stat_bonus_for,
                                    variable_risk: false)
    end

    # Roll for a participant using task-aware stat bonus and variable risk.
    # @param participant [ActivityParticipant]
    # @param action [ActivityAction]
    # @param help_bonus [Hash, nil] Help bonus information
    # @return [ParticipantRoll]
    def roll_for_participant_with_task(participant, action, help_bonus = nil)
      roll_for_participant_internal(participant, action, help_bonus,
                                    stat_method: :task_stat_bonus_for,
                                    variable_risk: true)
    end

    # Roll for a mandatory roll round (reflex/group_check) without a specific action.
    # Uses the round's stat configuration (reflex_stat_id or stat_set_a) for the stat bonus.
    def roll_for_mandatory(participant, round, help_bonus = nil)
      character = participant.character
      character_instance = participant.character_instance

      # Determine stat bonus from round configuration
      stat_bonus = 0
      stat_name = nil
      if round.reflex? && round.reflex_stat_id
        stat = Stat[round.reflex_stat_id]
        stat_name = stat&.name || 'Reflex'
        stat_bonus = StatAllocationService.get_stat_value(character_instance, stat.abbreviation) || 0 if stat && character_instance
      elsif round.stat_set_a.to_a.any?
        # Group check: use highest stat from stat_set_a
        stat_values = round.stat_set_a.to_a.map do |stat_id|
          s = Stat[stat_id]
          next 0 unless s && character_instance
          StatAllocationService.get_stat_value(character_instance, s.abbreviation) || 0
        end
        stat_bonus = stat_values.max || 0
        stat_name = 'Group Check'
      end

      helper_count = help_bonus&.dig(:helper_count) || 0
      helper_names = help_bonus&.dig(:helper_names) || []

      base_result = roll_base_dice(helper_count, explode: true)

      # Willpower dice
      willpower_spent = 0
      if participant.willpower_to_spend.to_i > 0
        wp_count = [participant.willpower_to_spend.to_i, 2].min
        wp_count = [wp_count, participant.available_willpower.to_i].min
        if wp_count > 0
          wp_result = DiceRollService.roll(wp_count, 8, explode_on: 8)
          base_result = append_willpower(base_result, wp_result)
          willpower_spent = wp_count
          wp_count.times { participant.use_willpower!(1) }
        end
      end

      total = base_result.dice.sum + stat_bonus

      # Build final RollResult for animation
      final_roll = DiceRollService::RollResult.new(
        dice: base_result.dice,
        base_dice: base_result.base_dice,
        explosions: base_result.explosions,
        modifier: stat_bonus,
        total: total,
        count: base_result.count,
        sides: 8,
        explode_on: 8
      )
      anim_data = DiceRollService.generate_animation_data(final_roll, character_name: character&.full_name || 'Unknown')

      ParticipantRoll.new(
        participant_id: participant.id,
        character_name: character&.full_name || 'Unknown',
        action_type: 'option',
        action_name: stat_name || 'Mandatory Roll',
        dice_results: base_result.dice,
        stat_bonus: stat_bonus,
        willpower_spent: willpower_spent,
        risk_result: nil,
        total: total,
        helped_by: helper_names,
        observer_effects: [],
        animation_data: anim_data
      )
    end

    # ========================================
    # Support Methods
    # ========================================

    # Process recovery actions for participants
    # @param participants [Array<ActivityParticipant>]
    def process_recoveries(participants)
      participants.each do |p|
        next unless recovery_action?(p)

        # Gain 0.25 willpower (we track as integers, so gain 1 every 4 recoveries)
        # For simplicity, gain 1 willpower on recovery (matching Ravencroft's tick system)
        p.gain_willpower!(1)
      end
    end

    # Calculate help bonuses for all participants
    # @param participants [Array<ActivityParticipant>]
    # @return [Hash<Integer, Hash>] Map of participant_id => { helper_count:, helper_names: }
    def calculate_help_bonuses(participants)
      help_map = Hash.new { |h, k| h[k] = { helper_count: 0, helper_names: [] } }

      participants.each do |helper|
        next unless help_action?(helper)

        target = helper.target_participant
        next unless target

        help_map[target.id][:helper_count] += 1
        help_map[target.id][:helper_names] << helper.character&.full_name
      end

      help_map
    end

    # Calculate help bonuses with task constraint
    # Helpers must be on the same task as their target
    def calculate_help_bonuses_with_tasks(participants)
      help_map = Hash.new { |h, k| h[k] = { helper_count: 0, helper_names: [] } }

      participants.each do |helper|
        next unless help_action?(helper)

        target = helper.target_participant
        next unless target

        # Cross-task help is ignored
        helper_task = helper[:task_chosen]
        target_task = target[:task_chosen]
        next if helper_task != target_task

        help_map[target.id][:helper_count] += 1
        help_map[target.id][:helper_names] << helper.character&.full_name
      end

      help_map
    end

    private

    # Shared rolling implementation for roll_for_participant and roll_for_participant_with_task.
    # @param participant [ActivityParticipant]
    # @param action [ActivityAction]
    # @param help_bonus [Hash, nil]
    # @param stat_method [Symbol] :stat_bonus_for or :task_stat_bonus_for
    # @param variable_risk [Boolean] whether to roll variable risk dice from action
    # @return [ParticipantRoll]
    def roll_for_participant_internal(participant, action, help_bonus, stat_method:, variable_risk:)
      character = participant.character
      character_instance = participant.character_instance

      # Get observer effects for this participant
      effects = ObserverEffectService.effects_for(participant, round_type: :standard)
      applied_effects = []

      # Calculate stat bonus from action (or use stat_swap if present)
      stat_bonus = if effects[:stat_swap]
                     applied_effects << :stat_swap
                     swapped_stat = effects[:stat_swap].to_s
                     (character_instance && StatAllocationService.get_stat_value(character_instance, swapped_stat)) ||
                       action.public_send(stat_method, character_instance) || 0
                   else
                     action.public_send(stat_method, character_instance) || 0
                   end

      helper_count = help_bonus&.dig(:helper_count) || 0
      helper_names = help_bonus&.dig(:helper_names) || []

      # Roll base dice (2d8)
      explode = !effects[:block_explosions]
      applied_effects << :block_explosions if effects[:block_explosions]
      base_result = roll_base_dice(helper_count, explode: explode)

      # Add willpower dice (up to 2) based on willpower_to_spend
      willpower_spent = 0
      if effects[:block_willpower]
        applied_effects << :block_willpower
      elsif participant.willpower_to_spend.to_i > 0
        wp_count = [participant.willpower_to_spend.to_i, 2].min
        wp_count = [wp_count, participant.available_willpower.to_i].min

        if wp_count > 0
          wp_result = DiceRollService.roll(wp_count, 8, explode_on: explode ? 8 : nil)
          base_result = append_willpower(base_result, wp_result)
          willpower_spent = wp_count
          wp_count.times { participant.use_willpower!(1) }
        end
      end

      # Apply reroll_ones effect if active
      all_dice = base_result.dice
      explosion_indices = base_result.explosions
      if effects[:reroll_ones]
        all_dice, explosion_indices = reroll_ones(all_dice, explosion_indices, explode: explode)
        applied_effects << :reroll_ones
      end

      # Apply damage_on_ones effect if active and any die shows 1
      if effects[:damage_on_ones] && all_dice.any? { |d| d == 1 }
        applied_effects << :damage_on_ones
        if character_instance
          begin
            character_instance.take_damage(1)
          rescue StandardError => e
            warn "[ActivityResolutionService] Failed to apply damage_on_ones: #{e.message}"
          end
        end
      end

      # Roll variable risk dice from action (task variant only)
      risk_result = nil
      if variable_risk
        sides = action.risk_sides_value
        risk_result = roll_variable_risk(sides) if sides && sides > 0
      end

      # Calculate total
      total = all_dice.sum + stat_bonus

      # Build final RollResult for animation
      final_roll = DiceRollService::RollResult.new(
        dice: all_dice,
        base_dice: base_result.base_dice,
        explosions: explosion_indices,
        modifier: stat_bonus,
        total: total,
        count: base_result.count,
        sides: 8,
        explode_on: explode ? 8 : nil
      )
      anim_data = DiceRollService.generate_animation_data(final_roll, character_name: character&.full_name || 'Unknown')

      ParticipantRoll.new(
        participant_id: participant.id,
        character_name: character&.full_name || 'Unknown',
        action_type: 'option',
        action_name: action.choice_text,
        dice_results: all_dice,
        stat_bonus: stat_bonus,
        willpower_spent: willpower_spent,
        risk_result: risk_result,
        total: total,
        helped_by: helper_names,
        observer_effects: applied_effects,
        animation_data: anim_data
      )
    end

    # Determine if participant chose recovery action
    def recovery_action?(participant)
      participant.effort_chosen&.downcase == 'recover' ||
        participant.risk_chosen&.downcase == 'recover'
    end

    # Determine if participant chose help action
    def help_action?(participant)
      participant.effort_chosen&.downcase == 'help' && !participant.action_target.nil?
    end

    # Determine action type from participant choices
    def determine_action_type(participant)
      if recovery_action?(participant)
        'recover'
      elsif help_action?(participant)
        'help'
      else
        'option'
      end
    end

    # Build a ParticipantRoll for a helper
    def build_help_roll(participant)
      target = participant.target_participant
      target_name = target&.character&.full_name || 'another player'

      ParticipantRoll.new(
        participant_id: participant.id,
        character_name: participant.character&.full_name || 'Unknown',
        action_type: 'help',
        action_name: "Helping #{target_name}",
        dice_results: [],
        stat_bonus: 0,
        willpower_spent: 0,
        risk_result: nil,
        total: 0,
        helped_by: [],
        observer_effects: []
      )
    end

    # Build a ParticipantRoll for recovery
    def build_recover_roll(participant)
      ParticipantRoll.new(
        participant_id: participant.id,
        character_name: participant.character&.full_name || 'Unknown',
        action_type: 'recover',
        action_name: 'Recovering',
        dice_results: [],
        stat_bonus: 0,
        willpower_spent: 0,
        risk_result: nil,
        total: 0,
        helped_by: [],
        observer_effects: []
      )
    end
  end
end
