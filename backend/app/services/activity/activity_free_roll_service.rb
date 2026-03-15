# frozen_string_literal: true

require_relative '../../lib/safe_json_helper'

# Handles free roll round resolution for the Activity System (LLM-based).
#
# Free roll rounds are open-ended problem solving where:
# - LLM acts as GM, picks stats/DC based on player descriptions
# - Participants can make ONE assess roll before action
# - Player describes action, LLM picks stat(s) and DC
# - Player rolls, LLM narrates outcome
# - LLM decides when problem is solved and how well
#
# Requires: GameSetting.boolean('activity_free_roll_enabled')
# Model: Claude Sonnet 4.5 (via anthropic provider)
class ActivityFreeRollService
  extend SafeJSONHelper

  class FreeRollError < StandardError; end

  # Result of LLM evaluation
  EvaluationResult = Struct.new(
    :stat_ids,
    :stat_names,
    :dc,
    :success_desc,
    :failure_desc,
    :context_revealed,  # For assess: what they learn
    keyword_init: true
  )

  # Result of a free roll action
  ActionResult = Struct.new(
    :participant_id,
    :character_name,
    :action_description,
    :stat_names,
    :roll_total,
    :dc,
    :success,
    :narration,
    keyword_init: true
  )

  # LLM model to use for free roll GM
  FREE_ROLL_MODEL = 'claude-sonnet-4-6'
  FREE_ROLL_PROVIDER = 'anthropic'

  class << self
    # Check if free roll is enabled
    def enabled?
      GameSetting.boolean('activity_free_roll_enabled')
    end

    # Process an assess request from a participant
    # @param participant [ActivityParticipant]
    # @param description [String] What they want to assess
    # @param round [ActivityRound]
    # @return [EvaluationResult, nil] The LLM's evaluation or nil if failed
    def assess!(participant, description, round)
      raise FreeRollError, 'Free roll not enabled' unless enabled?
      raise FreeRollError, 'Already used assess this round' if participant.assess_used?

      instance = participant.instance
      activity = instance.activity

      # Build prompt for LLM
      prompt = build_assess_prompt(round, activity, description, participant)

      # Call LLM
      result = call_llm(prompt, round)
      return nil unless result[:success]

      # Parse response
      evaluation = parse_evaluation(result[:text] || result[:data].to_s)
      return nil unless evaluation

      # Mark assess as used
      participant.use_assess!

      # Roll the assess check
      roll_result = roll_for_stats(participant, evaluation.stat_ids, evaluation.stat_names)

      # Determine what they learn based on roll
      context = if roll_result >= evaluation.dc
                  evaluation.context_revealed || 'You successfully gather information.'
                else
                  'You fail to discern anything useful.'
                end

      evaluation.context_revealed = context
      evaluation
    end

    # Process an action from a participant
    # @param participant [ActivityParticipant]
    # @param description [String] What action they want to take
    # @param round [ActivityRound]
    # @return [ActionResult]
    def take_action(participant, description, round)
      raise FreeRollError, 'Free roll not enabled' unless enabled?

      instance = participant.instance
      activity = instance.activity

      # Build prompt for LLM
      prompt = build_action_prompt(round, activity, description, participant, instance)

      # Call LLM
      result = call_llm(prompt, round)
      raise FreeRollError, 'LLM request failed' unless result[:success]

      # Parse response
      evaluation = parse_evaluation(result[:text] || result[:data].to_s)
      raise FreeRollError, 'Failed to parse LLM response' unless evaluation

      # Roll for the action
      roll_total = roll_for_stats(participant, evaluation.stat_ids, evaluation.stat_names)
      success = roll_total >= evaluation.dc

      # Get narration from LLM
      narration = success ? evaluation.success_desc : evaluation.failure_desc

      # Update participant
      participant.increment_action_count!
      participant.reset_assess!  # Reset assess for next action
      participant.update(
        roll_result: roll_total,
        expect_roll: evaluation.dc
      )

      ActionResult.new(
        participant_id: participant.id,
        character_name: participant.character&.full_name,
        action_description: description,
        stat_names: evaluation.stat_names,
        roll_total: roll_total,
        dc: evaluation.dc,
        success: success,
        narration: narration
      )
    end

    # Check if round is complete (LLM decides)
    # @param instance [ActivityInstance]
    # @param round [ActivityRound]
    # @return [Hash] { complete: Boolean, success: Boolean, narration: String }
    def check_round_complete(instance, round)
      # For now, complete after all participants have acted at least once
      participants = instance.active_participants.all
      all_acted = participants.all? { |p| p.total_actions > 0 }

      return { complete: false, success: false, narration: nil } unless all_acted

      # Could add LLM evaluation of overall success here
      { complete: true, success: true, narration: 'The group has addressed the challenge.' }
    end

    private

    def build_assess_prompt(round, activity, description, participant)
      additional_context = round.free_roll_context ? "Additional Context: #{round.free_roll_context}" : ''

      GamePrompts.get('activities.free_roll.assess',
                      activity_name: activity.display_name,
                      round_description: round.emit_text,
                      additional_context: additional_context,
                      participant_name: participant.character&.full_name,
                      assessment_text: description)
    end

    def build_action_prompt(round, activity, description, participant, instance)
      # Get recent action history for context
      recent_actions_list = instance.active_participants.map do |p|
        next nil if p.total_actions.zero?

        "#{p.character&.full_name}: #{p.total_actions} action(s) taken"
      end.compact.join(', ')

      additional_context = round.free_roll_context ? "Additional Context: #{round.free_roll_context}" : ''
      recent_actions = (!recent_actions_list.nil? && !recent_actions_list.empty?) ? "Previous actions: #{recent_actions_list}" : ''

      GamePrompts.get('activities.free_roll.action',
                      activity_name: activity.display_name,
                      round_description: round.emit_text,
                      additional_context: additional_context,
                      recent_actions: recent_actions,
                      participant_name: participant.character&.full_name,
                      action_text: description)
    end

    def call_llm(prompt, round)
      LLM::Client.generate(
        prompt: prompt,
        model: FREE_ROLL_MODEL,
        provider: FREE_ROLL_PROVIDER,
        json_mode: true,
        options: {
          max_tokens: 500,
          temperature: 0.7
        }
      )
    end

    def parse_evaluation(response_text)
      data = safe_json_parse(response_text, fallback: nil, context: 'ActivityFreeRollService')
      return nil if data.nil?

      stat_names = Array(data['stat_names']).map { |v| v.to_s.strip }.reject(&:empty?)
      stat_ids = Array(data['stat_ids']).map(&:to_i).select(&:positive?)
      stat_ids = resolve_stat_ids(stat_names) if stat_ids.empty?
      dc = data['dc'].to_i

      EvaluationResult.new(
        stat_ids: stat_ids,
        stat_names: stat_names,
        dc: dc.positive? ? dc : 10,
        success_desc: data['success_desc'],
        failure_desc: data['failure_desc'],
        context_revealed: data['context_revealed']
      )
    end

    def roll_for_stats(participant, stat_ids, stat_names = [])
      # Roll 2d8 exploding
      base_roll = DiceRollService.roll(2, 8, explode_on: 8)

      # Add stat bonuses
      stat_bonus = 0
      ci = participant.character_instance
      if ci
        # Try stat IDs first
        stat_ids.each do |stat_id|
          stat = Stat[stat_id]
          next unless stat

          stat_bonus += StatAllocationService.get_stat_value(ci, stat.abbreviation) || 0
        end

        # Fallback for LLM responses that provide names but no IDs
        if stat_bonus.zero?
          stat_names.each do |stat_name|
            next if stat_name.empty?

            stat = find_stat_by_name(stat_name)
            next unless stat

            value = StatAllocationService.get_stat_value(ci, stat.abbreviation)
            stat_bonus += value.to_i if value
          end
        end
      end

      # Add willpower if spending
      wp_total = 0
      if participant.willpower_to_spend.to_i > 0
        wp_count = [participant.willpower_to_spend.to_i, 2].min
        wp_count = [wp_count, participant.available_willpower.to_i].min

        if wp_count > 0
          wp_roll = DiceRollService.roll(wp_count, 8, explode_on: 8)
          wp_total = wp_roll.total
          wp_count.times { participant.use_willpower!(1) }
        end
      end

      base_roll.total + wp_total + stat_bonus
    end

    def resolve_stat_ids(stat_names)
      return [] unless defined?(Stat)

      stat_names.filter_map do |name|
        find_stat_by_name(name)&.id
      end.uniq
    end

    def find_stat_by_name(name)
      return nil unless defined?(Stat)
      return nil if name.nil? || name.to_s.strip.empty?

      normalized = name.to_s.strip.downcase
      Stat.where(Sequel.function(:lower, :abbreviation) => normalized).first ||
        Stat.where(Sequel.function(:lower, :name) => normalized).first
    end

  end
end
