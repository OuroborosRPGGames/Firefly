# frozen_string_literal: true

module AutoGm
  # AutoGmDecisionService is the GM's brain - decides what action to take next.
  #
  # Uses Claude Sonnet 4.5 with structured JSON output to make GM decisions.
  # The service analyzes the current session state, recent actions, and adventure
  # sketch to determine the next appropriate GM action.
  # Action types are defined in AutoGmAction::ACTION_TYPES.
  #
  class AutoGmDecisionService
    extend StringHelper

    # Model for GM decisions
    GM_MODEL = { provider: 'anthropic', model: 'claude-sonnet-4-6' }.freeze

    REQUIRED_ACTION_FIELDS = {
      'emit' => %w[emit_text],
      'roll_request' => %w[roll_type],
      'move_characters' => %w[destination_room_id],
      'spawn_npc' => %w[npc_archetype_hint],
      'spawn_item' => %w[item_description]
    }.freeze

    extend AutoGm::AutoGmFormatHelper

    class << self
      # Decide what action the GM should take next
      # @param session [AutoGmSession] the session
      # @return [Hash] { action_type:, params:, reasoning:, thinking_tokens: }
      def decide(session)
        context = build_decision_context(session)
        prompt = build_prompt(session, context)

        result = LLM::Client.generate(
          prompt: prompt,
          provider: GM_MODEL[:provider],
          model: GM_MODEL[:model],
          options: {
            system_prompt: build_system_prompt(session),
            max_tokens: 1500,
            temperature: 0.8,
            timeout: 60
          },
          json_mode: true
        )

        return default_emit_action(session, 'LLM call failed') unless result[:success]

        begin
          # Strip markdown code fences if present
          text = result[:text].strip
          text = text.sub(/\A```(?:json)?\s*\n?/, '').sub(/\n?\s*```\z/, '') if text.start_with?('```')

          decision = JSON.parse(text)
          validate_decision(decision)

          # Guard against back-to-back roll requests
          decision = guard_roll_spam(session, decision)

          {
            action_type: decision['action_type'],
            params: decision,
            reasoning: decision['reasoning'],
            thinking_tokens: result[:usage]&.dig('output_tokens')
          }
        rescue JSON::ParserError => e
          default_emit_action(session, "JSON parse error: #{e.message}")
        rescue StandardError => e
          default_emit_action(session, "Decision error: #{e.message}")
        end
      end

      # Get a GM response for roll outcomes and reactive situations
      # Uses Sonnet 4.5 for quality narrative that matches the main GM loop
      # @param session [AutoGmSession] the session
      # @param situation [String] description of what happened
      # @return [Hash] decision
      def quick_response(session, situation)
        sketch = session.sketch

        prompt = GamePrompts.get(
          'auto_gm.quick_response',
          title: sketch['title'],
          mission_type: sketch.dig('mission', 'type'),
          mission_objective: sketch.dig('mission', 'objective'),
          current_stage: session.current_stage,
          total_stages: sketch.dig('structure', 'stages')&.length || 0,
          chaos_level: session.chaos_level,
          situation: situation
        )

        result = LLM::Client.generate(
          prompt: prompt,
          provider: GM_MODEL[:provider],
          model: GM_MODEL[:model],
          options: {
            max_tokens: 500,
            temperature: 0.8,
            timeout: 30
          }
        )

        {
          action_type: 'emit',
          params: { 'emit_text' => result[:success] ? result[:text] : 'The adventure continues...' },
          reasoning: "GM response to: #{situation[0..50]}..."
        }
      end

      # Check if the GM should act based on session state
      # @param session [AutoGmSession] the session
      # @return [Boolean]
      def should_act?(session)
        # Don't act if session is not running
        return false unless %w[running climax].include?(session.status)

        # Don't act if in combat (combat system handles it)
        return false if session.in_combat?

        # Always act if no actions yet
        return true if session.auto_gm_actions.empty?

        # Check time since last action
        last_action = session.auto_gm_actions_dataset.order(Sequel.desc(:created_at)).first
        return true unless last_action

        # Act if more than 30 seconds since last action
        Time.now - last_action.created_at > 30
      end

      private

      # Build system prompt for the GM
      # @param session [AutoGmSession] the session
      # @return [String]
      def build_system_prompt(session)
        sketch = session.sketch

        GamePrompts.get(
          'auto_gm.gm_system',
          title: sketch['title'],
          structure_type: sketch.dig('structure', 'type'),
          current_stage: session.current_stage,
          chaos_level: session.chaos_level
        )
      end

      # Build decision context from session state
      # @param session [AutoGmSession] the session
      # @return [Hash]
      def build_decision_context(session)
        recent_actions = session.auto_gm_actions_dataset
          .order(Sequel.desc(:sequence_number))
          .limit(10)
          .all
          .reverse

        # Count GM actions on THIS stage only (excluding player_action)
        # Find the last advance_stage action to get the boundary
        last_advance = session.auto_gm_actions_dataset
          .where(action_type: 'advance_stage')
          .order(Sequel.desc(:created_at))
          .first

        gm_actions_query = session.auto_gm_actions_dataset
          .exclude(action_type: 'player_action')
        gm_actions_query = gm_actions_query.where { created_at > last_advance.created_at } if last_advance

        gm_actions_this_stage = gm_actions_query.count

        {
          recent_actions: recent_actions.map do |a|
            { type: a.action_type, text: a.emit_text, status: a.status }
          end,
          recent_summary: get_recent_summary(session),
          world_state: session.world_state || {},
          participant_states: get_participant_states(session),
          available_stats: session.stat_names_for_prompt,
          stage_challenges: get_stage_challenges(session),
          gm_actions_this_stage: gm_actions_this_stage,
          stage_pressure: stage_advancement_pressure(gm_actions_this_stage, session)
        }
      end

      def get_recent_summary(session)
        # Get highest-level summary available
        summary = session.auto_gm_summaries_dataset
          .order(Sequel.desc(:abstraction_level), Sequel.desc(:created_at))
          .first

        summary&.content || 'No summary available yet.'
      end

      def get_stage_challenges(session)
        stage = session.current_stage_info
        return 'No stage challenges defined.' unless stage

        challenges = stage['suggested_challenges']
        return 'No specific challenges suggested for this stage.' if challenges.nil? || challenges.empty?

        challenges.map { |c| "- #{c}" }.join("\n")
      end

      def get_participant_states(session)
        session.participant_instances.map do |p|
          {
            name: DisplayHelper.character_display_name(p),
            room: p.current_room&.name,
            online: p.online
          }
        end
      end

      def build_prompt(session, context)
        sketch = session.sketch
        stages = sketch.dig('structure', 'stages') || []
        secrets = sketch.dig('secrets_twists', 'secrets') || []
        revealed = context.dig(:world_state, 'secrets_revealed') || []
        unrevealed = secrets - revealed

        GamePrompts.get(
          'auto_gm.decision',
          title: sketch['title'],
          mission_type: sketch.dig('mission', 'type'),
          mission_objective: sketch.dig('mission', 'objective'),
          current_stage: session.current_stage,
          total_stages: stages.length,
          chaos_level: session.chaos_level,
          stage_info: format_stage_info(stages, session.current_stage),
          unrevealed_secrets: unrevealed.any? ? unrevealed.join(', ') : 'All secrets revealed',
          twist_info: format_twist_info(sketch),
          success_conditions: (sketch.dig('mission', 'success_conditions') || []).join(', '),
          failure_conditions: (sketch.dig('mission', 'failure_conditions') || []).join(', '),
          recent_summary: context[:recent_summary],
          recent_actions: format_recent_actions(context[:recent_actions]),
          gm_actions_this_stage: context[:gm_actions_this_stage],
          stage_pressure: context[:stage_pressure],
          npcs_spawned: format_list(context.dig(:world_state, 'npcs_spawned')),
          secrets_revealed: format_list(context.dig(:world_state, 'secrets_revealed')),
          items_appeared: format_list(context.dig(:world_state, 'items_appeared')),
          participant_status: format_participants(context[:participant_states]),
          available_stats: context[:available_stats],
          stage_challenges: context[:stage_challenges]
        )
      end

      # Format stage info for the prompt
      # @param stages [Array<Hash>] all stages
      # @param current [Integer] current stage index
      # @return [String]
      def format_stage_info(stages, current)
        stages.each_with_index.map do |stage, i|
          marker = i == current ? '>>> ' : '    '
          climax = stage['is_climax'] ? ' [CLIMAX]' : ''
          "#{marker}#{i}: #{stage['name']}#{climax} - #{stage['description']}"
        end.join("\n")
      end

      # Format twist info for the prompt
      # @param sketch [Hash] the sketch
      # @return [String]
      def format_twist_info(sketch)
        twist = sketch['secrets_twists'] || {}
        return 'No twist defined' unless twist['twist_type']

        "Type: #{twist['twist_type']}, Trigger: #{twist['twist_trigger']}"
      end

      # Format recent actions for the prompt
      # @param actions [Array<Hash>] recent actions
      # @return [String]
      def format_recent_actions(actions)
        return 'No recent actions' if actions.nil? || actions.empty?

        actions.map do |a|
          text = a[:text] ? " - \"#{truncate(a[:text], 100)}\"" : ''
          "- #{a[:type]}#{text}"
        end.join("\n")
      end

      # NOTE: format_list is inherited from AutoGmFormatHelper

      # Format participant states for the prompt
      # @param participants [Array<Hash>] participant states
      # @return [String]
      def format_participants(participants)
        return 'No participants' if participants.nil? || participants.empty?

        participants.map do |p|
          status = p[:online] ? 'online' : 'offline'
          "- #{p[:name]} (#{status}, in #{p[:room] || 'unknown'})"
        end.join("\n")
      end

      # Generate escalating stage advancement guidance based on action count.
      # Narrative quality matters more than strict pacing — these are encouragements,
      # not mandates. The goal is to steer the narrative toward resolving the current
      # stage's challenge so advancement feels earned.
      # @param count [Integer] GM actions on current stage
      # @param session [AutoGmSession] the session
      # @return [String] guidance message for the prompt
      def stage_advancement_pressure(count, session)
        stages = session.sketch.dig('structure', 'stages') || []
        if session.current_stage >= stages.length - 1
          return 'You are on the final stage. Consider using resolve_session when the narrative reaches a satisfying conclusion.'
        end

        next_stage = stages[session.current_stage + 1]
        next_name = next_stage ? next_stage['name'] : 'the next stage'

        case count
        when 0..3
          '' # No guidance needed yet
        when 4..5
          "Consider whether this stage's core challenge has been addressed. If so, it may be time to advance to \"#{next_name}\"."
        when 6..8
          "This stage has been running for a while. Start steering your narrative toward resolving the current challenge so the story can naturally progress to \"#{next_name}\". If you emit, write toward a conclusion for this stage."
        else
          "This stage has run for #{count} actions. The pacing is getting slow — actively wrap up the current scene. Shape your next emit to bring the stage's challenge to resolution, then advance. The players are ready for \"#{next_name}\"."
        end
      end

      # Validate the decision structure
      # @param decision [Hash] the parsed decision
      # @raise [StandardError] if invalid
      def validate_decision(decision)
        raise ArgumentError, 'Missing action_type' unless decision['action_type']
        raise ArgumentError, "Invalid action_type: #{decision['action_type']}" unless AutoGmAction::ACTION_TYPES.include?(decision['action_type'])
        raise ArgumentError, 'Missing reasoning' unless decision['reasoning']

        required = REQUIRED_ACTION_FIELDS[decision['action_type']] || []
        required.each do |field|
          raise ArgumentError, "Missing required field for #{decision['action_type']}: #{field}" unless decision_field_present?(decision, field)
        end
      end

      # Some action fields have legacy aliases we still accept.
      # @param decision [Hash]
      # @param field [String]
      # @return [Boolean]
      def decision_field_present?(decision, field)
        value = decision[field]
        return true unless value.nil? || (value.respond_to?(:empty?) && value.empty?)

        case field
        when 'roll_type'
          alt = decision['check_type']
          !alt.nil? && !(alt.respond_to?(:empty?) && alt.empty?)
        when 'npc_archetype_hint'
          alt = decision['npc_name'] || decision['name_hint']
          !alt.nil? && !(alt.respond_to?(:empty?) && alt.empty?)
        when 'item_description'
          alt = decision['description']
          !alt.nil? && !(alt.respond_to?(:empty?) && alt.empty?)
        else
          false
        end
      end

      # Guard against back-to-back roll requests
      # If the last GM action was a roll_request, convert this one to an emit
      # that narrates the roll description instead
      # @param session [AutoGmSession] the session
      # @param decision [Hash] the parsed decision
      # @return [Hash] the decision (possibly converted)
      def guard_roll_spam(session, decision)
        return decision unless decision['action_type'] == 'roll_request'

        last_gm_action = session.auto_gm_actions_dataset
          .exclude(action_type: 'player_action')
          .order(Sequel.desc(:created_at))
          .first

        return decision unless last_gm_action&.action_type == 'roll_request'

        # Convert to emit — narrate the situation instead of requesting another roll
        warn "[AutoGmDecision] Blocked back-to-back roll_request, converting to emit"
        decision['action_type'] = 'emit'
        decision['emit_text'] ||= decision['roll_type'] || 'The situation develops...'
        decision['reasoning'] = "Converted from roll_request (anti-spam): #{decision['reasoning']}"
        decision
      end

      # Create a default emit action as fallback
      # @param session [AutoGmSession] the session
      # @param reason [String] why we're falling back
      # @return [Hash]
      def default_emit_action(session, reason)
        {
          action_type: 'emit',
          params: { 'emit_text' => 'The adventure continues...', 'fallback_reason' => reason },
          reasoning: "Default fallback action: #{reason}"
        }
      end

      # NOTE: truncate method is inherited from StringHelper
    end
  end
end
