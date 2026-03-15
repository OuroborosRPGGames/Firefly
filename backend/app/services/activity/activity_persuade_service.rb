# frozen_string_literal: true

require_relative '../../lib/safe_json_helper'

# Handles persuade round resolution for the Activity System (LLM-based).
#
# Persuade rounds are RP-based social challenges where:
# - LLM plays NPC with defined personality from round config
# - Players RP in room (regular say/emote commands)
# - After RP period OR player calls 'activity persuade':
#   - LLM evaluates persuasiveness of conversation
#   - Returns difficulty rating (DC based on how convincing)
# - One or more players roll Charisma (or specified stat) vs DC
# - Failure: Continue RP, try again (attempts tracked)
# - Success: Progress to next round
#
# Requires: GameSetting.boolean('activity_persuade_enabled')
# Model: DeepSeek (via openrouter provider)
class ActivityPersuadeService
  extend SafeJSONHelper

  class PersuadeError < StandardError; end

  # Persuasiveness ratings and their DC modifiers
  PERSUASION_RATINGS = {
    1 => { modifier: 10, label: 'Not at all convincing' },
    2 => { modifier: 5, label: 'Weak attempt' },
    3 => { modifier: 0, label: 'Reasonable' },
    4 => { modifier: -5, label: 'Good arguments' },
    5 => { modifier: -10, label: 'Excellent, nearly convinced' }
  }.freeze

  # LLM model for NPC roleplay
  PERSUADE_MODEL = 'deepseek/deepseek-v3.2'
  PERSUADE_PROVIDER = 'openrouter'

  # Evaluation result
  EvaluationResult = Struct.new(
    :rating,
    :dc_modifier,
    :adjusted_dc,
    :feedback,
    keyword_init: true
  )

  # Persuasion attempt result
  AttemptResult = Struct.new(
    :success,
    :roll_total,
    :dc,
    :npc_response,
    :attempts_made,
    keyword_init: true
  )

  class << self
    # Check if persuade rounds are enabled
    def enabled?
      GameSetting.boolean('activity_persuade_enabled')
    end

    # Calculate adjusted DC with observer effects
    # @param instance [ActivityInstance]
    # @param round [ActivityRound]
    # @param evaluation_modifier [Integer] Modifier from conversation evaluation (default 0)
    # @return [Integer] Final DC clamped between 5-30
    def adjusted_dc(instance, round, evaluation_modifier = 0)
      base_dc = round.persuade_base_dc || 10
      observer_modifier = ObserverEffectService.persuade_dc_modifier(instance)
      (base_dc + evaluation_modifier + observer_modifier).clamp(5, 30)
    end

    # Get NPC response to player speech (for RP flow)
    # @param instance [ActivityInstance]
    # @param round [ActivityRound]
    # @param player_message [String] What the player said
    # @param speaker [Character] Who said it
    # @return [String] NPC's response
    def npc_respond(instance, round, player_message, speaker)
      raise PersuadeError, 'Persuade not enabled' unless enabled?

      conversation = find_or_create_conversation(instance, round)

      # Add player message to conversation
      add_message(conversation, 'user', "#{speaker.full_name} says: #{player_message}")

      # Get NPC response
      response = call_llm_for_response(conversation, round)

      if response[:success]
        npc_text = response[:text] || 'The NPC considers your words.'
        add_message(conversation, 'assistant', npc_text)
        npc_text
      else
        "#{round.persuade_npc_name} seems distracted."
      end
    end

    # Evaluate current persuasion attempt
    # @param instance [ActivityInstance]
    # @param round [ActivityRound]
    # @return [EvaluationResult]
    def evaluate_persuasion(instance, round)
      raise PersuadeError, 'Persuade not enabled' unless enabled?

      conversation = find_or_create_conversation(instance, round)
      transcript = build_transcript(conversation)

      # Call LLM to evaluate
      result = call_llm_for_evaluation(transcript, round)

      unless result[:success]
        # Default to neutral rating on failure
        return EvaluationResult.new(
          rating: 3,
          dc_modifier: 0,
          adjusted_dc: adjusted_dc(instance, round, 0),
          feedback: 'Unable to evaluate persuasion.'
        )
      end

      parse_evaluation(result[:text] || result[:data].to_s, instance, round)
    end

    # Attempt persuasion roll after evaluation
    # @param participant [ActivityParticipant]
    # @param instance [ActivityInstance]
    # @param round [ActivityRound]
    # @return [AttemptResult]
    def attempt_persuasion(participant, instance, round)
      raise PersuadeError, 'Persuade not enabled' unless enabled?

      # Evaluate current conversation
      evaluation = evaluate_persuasion(instance, round)

      # Lower DC by 1 for each previous failed attempt (persistence pays off)
      prior_attempts = instance.persuade_attempts || 0
      final_dc = (evaluation.adjusted_dc - prior_attempts).clamp(5, 30)

      # Roll for persuasion
      roll_total = roll_persuasion(participant, round)
      success = roll_total >= final_dc

      # Update tracking
      instance.increment_persuade_attempts!
      participant.update(
        roll_result: roll_total,
        expect_roll: final_dc
      )

      # Get NPC response to the attempt
      npc_response = if success
                       generate_success_response(instance, round)
                     else
                       generate_failure_response(instance, round, evaluation)
                     end

      AttemptResult.new(
        success: success,
        roll_total: roll_total,
        dc: final_dc,
        npc_response: npc_response,
        attempts_made: instance.persuade_attempts
      )
    end

    # Get conversation for display
    # @param instance [ActivityInstance]
    # @param round [ActivityRound]
    # @return [Array<Hash>] Array of { role:, content:, timestamp: }
    def conversation_history(instance, round)
      conversation = find_or_create_conversation(instance, round)
      return [] unless conversation

      conversation.llm_messages.map do |msg|
        {
          role: msg.role == 'assistant' ? round.persuade_npc_name : 'Player',
          content: msg.content,
          timestamp: msg.created_at
        }
      end
    end

    private

    def find_or_create_conversation(instance, round)
      # Look for existing conversation via metadata
      existing = LLMConversation.where(purpose: 'activity_persuade')
                                .where(Sequel.lit("metadata->>'activity_instance_id' = ?", instance.id.to_s))
                                .first
      return existing if existing

      # Create new conversation with NPC personality as system prompt
      LLMConversation.start(
        purpose: 'activity_persuade',
        system_prompt: build_npc_system_prompt(round),
        metadata: Sequel.pg_jsonb({ 'activity_instance_id' => instance.id })
      )
    end

    def build_npc_system_prompt(round)
      GamePrompts.get('activities.persuade.npc_system',
                      npc_name: round.persuade_npc_name || 'an NPC',
                      npc_personality: round.persuade_npc_personality || 'A cautious individual who takes convincing.',
                      persuade_goal: round.persuade_goal || 'convince you of something.')
    end

    def add_message(conversation, role, content)
      return unless conversation

      LLMMessage.create(
        llm_conversation_id: conversation.id,
        role: role,
        content: content,
        created_at: Time.now
      )
    end

    def build_transcript(conversation)
      return '' unless conversation

      conversation.llm_messages.map do |msg|
        role_label = msg.role == 'assistant' ? 'NPC' : 'Player'
        "#{role_label}: #{msg.content}"
      end.join("\n\n")
    end

    def call_llm_for_response(conversation, round)
      messages = conversation.llm_messages.map do |msg|
        { role: msg.role, content: msg.content }
      end

      # Add system prompt at start
      full_messages = [{ role: 'system', content: conversation.system_prompt }] + messages

      LLM::Client.generate(
        prompt: messages.last[:content],
        model: PERSUADE_MODEL,
        provider: PERSUADE_PROVIDER,
        options: {
          system_prompt: conversation.system_prompt,
          max_tokens: 300,
          temperature: 0.8
        }
      )
    end

    def call_llm_for_evaluation(transcript, round)
      prompt = GamePrompts.get('activities.persuade.evaluation',
                               npc_personality: round.persuade_npc_personality,
                               persuade_goal: round.persuade_goal,
                               transcript: transcript)

      LLM::Client.generate(
        prompt: prompt,
        model: PERSUADE_MODEL,
        provider: PERSUADE_PROVIDER,
        json_mode: true,
        options: {
          max_tokens: 200,
          temperature: 0.5
        }
      )
    end

    def parse_evaluation(response_text, instance, round)
      data = safe_json_parse(response_text, fallback: nil, context: 'ActivityPersuadeService')

      unless data.is_a?(Hash)
        return EvaluationResult.new(
          rating: 3,
          dc_modifier: 0,
          adjusted_dc: adjusted_dc(instance, round, 0),
          feedback: 'Unable to evaluate persuasion.'
        )
      end

      raw_rating = data['rating'].to_i
      rating = (1..5).cover?(raw_rating) ? raw_rating : 3
      dc_modifier = PERSUASION_RATINGS[rating][:modifier]

      EvaluationResult.new(
        rating: rating,
        dc_modifier: dc_modifier,
        adjusted_dc: adjusted_dc(instance, round, dc_modifier),
        feedback: data['feedback'] || PERSUASION_RATINGS[rating][:label]
      )
    end

    def roll_persuasion(participant, round)
      # Roll 2d8 exploding
      base_roll = DiceRollService.roll(2, 8, explode_on: 8)

      # Add persuade stat bonus. Support both legacy persuade_stat_id and
      # newer stat_set_a configuration used by mission generation.
      stat_bonus = 0
      ci = participant.character_instance
      if ci
        stat_ids = []
        stat_ids << round.persuade_stat_id if round.persuade_stat_id
        stat_ids.concat(round.stat_set_a.to_a)
        stat_ids = stat_ids.compact.map(&:to_i).select(&:positive?).uniq
        if stat_ids.any?
          # Use strongest relevant social stat for this check.
          stat_bonus = stat_ids.map do |sid|
            stat = Stat[sid]
            stat ? (StatAllocationService.get_stat_value(ci, stat.abbreviation) || 0) : 0
          end.max || 0
        end
      end

      # Add willpower dice if spending
      wp_total = 0
      if participant.willpower_to_spend.to_i > 0
        wp_to_spend = [participant.willpower_to_spend.to_i, 2].min
        wp_to_spend = [wp_to_spend, participant.available_willpower.to_i].min

        if wp_to_spend > 0
          wp_roll = DiceRollService.roll(wp_to_spend, 8, explode_on: 8)
          wp_total = wp_roll.total
          wp_to_spend.times { participant.use_willpower!(1) }
        end
      end

      base_roll.total + wp_total + stat_bonus
    end

    def generate_success_response(instance, round)
      prompt = GamePrompts.get('activities.persuade.success_response',
                               npc_name: round.persuade_npc_name,
                               persuade_goal: round.persuade_goal)

      result = LLM::Client.generate(
        prompt: prompt,
        model: PERSUADE_MODEL,
        provider: PERSUADE_PROVIDER,
        options: { max_tokens: 150, temperature: 0.7 }
      )

      result[:success] ? (result[:text] || "Very well. You've convinced me.") : "Very well. You've convinced me."
    end

    def generate_failure_response(instance, round, evaluation)
      prompt = GamePrompts.get('activities.persuade.failure_response',
                               npc_name: round.persuade_npc_name,
                               rating: evaluation.rating,
                               feedback: evaluation.feedback)

      result = LLM::Client.generate(
        prompt: prompt,
        model: PERSUADE_MODEL,
        provider: PERSUADE_PROVIDER,
        options: { max_tokens: 150, temperature: 0.7 }
      )

      result[:success] ? (result[:text] || "I'm not convinced yet.") : "I'm not convinced yet."
    end
  end
end
