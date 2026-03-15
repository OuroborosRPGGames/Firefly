# frozen_string_literal: true

module AutoGm
  # AutoGmCompressionService manages hierarchical summarization for context compression.
  #
  # Summaries are organized in levels:
  # - Level 1 (Events): 5-10 actions summarized into a brief event summary
  # - Level 2 (Scene): Multiple event summaries combined into a scene summary
  # - Level 3 (Act): Multiple scene summaries combined into an act summary
  # - Level 4 (Session): Full session summary
  #
  # This allows the GM loop to maintain context without growing unboundedly.
  #
  class AutoGmCompressionService
    # Compression hierarchy (from centralized config)
    ACTIONS_PER_EVENT = GameConfig::AutoGm::COMPRESSION[:actions_per_event]
    EVENTS_PER_SCENE = GameConfig::AutoGm::COMPRESSION[:events_per_scene]
    SCENES_PER_ACT = GameConfig::AutoGm::COMPRESSION[:scenes_per_act]
    ACTS_PER_SESSION = GameConfig::AutoGm::COMPRESSION[:acts_per_session]

    class << self
      # Update compression for a session after new actions
      # @param session [AutoGmSession] the session
      # @return [Array<AutoGmSummary>] any new summaries created
      def update(session)
        summaries_created = []

        # Check if we need to create event-level summary
        if needs_event_summary?(session)
          summary = create_event_summary(session)
          summaries_created << summary if summary
        end

        # Check if we need to create scene-level summary
        if AutoGmSummary.needs_abstraction?(session, AutoGmSummary::LEVEL_EVENTS)
          summary = create_scene_summary(session)
          summaries_created << summary if summary
        end

        # Check if we need to create act-level summary
        if AutoGmSummary.needs_abstraction?(session, AutoGmSummary::LEVEL_SCENE)
          summary = create_act_summary(session)
          summaries_created << summary if summary
        end

        # Check if we need to create session-level summary
        if AutoGmSummary.needs_abstraction?(session, AutoGmSummary::LEVEL_ACT)
          summary = create_session_summary(session)
          summaries_created << summary if summary
        end

        summaries_created
      end

      # Get the most relevant summary for context
      # @param session [AutoGmSession] the session
      # @return [String] summary content
      def get_relevant_summary(session)
        # Try to get the best summary at each level, starting from highest
        summary = AutoGmSummary.best_for_context(session)

        return summary.content if summary

        # Fall back to recent actions
        recent_actions = session.auto_gm_actions_dataset
          .where(action_type: 'emit')
          .order(Sequel.desc(:created_at))
          .limit(5)
          .all

        if recent_actions.any?
          recent_actions.map(&:emit_text).compact.join(' ')
        else
          'The adventure has just begun.'
        end
      end

      # Get context window for GM decisions
      # @param session [AutoGmSession] the session
      # @param max_tokens [Integer] approximate max tokens
      # @return [String] formatted context
      def get_context_window(session, max_tokens: 2000)
        parts = []

        # Always include latest session summary if available
        session_summary = session.auto_gm_summaries_dataset
          .where(abstraction_level: AutoGmSummary::LEVEL_SESSION)
          .order(Sequel.desc(:created_at))
          .first
        parts << "SESSION: #{session_summary.content}" if session_summary

        # Add recent act summary
        act_summary = session.auto_gm_summaries_dataset
          .where(abstraction_level: AutoGmSummary::LEVEL_ACT, abstracted: false)
          .order(Sequel.desc(:created_at))
          .first
        parts << "RECENT ACT: #{act_summary.content}" if act_summary

        # Add recent scene summary
        scene_summary = session.auto_gm_summaries_dataset
          .where(abstraction_level: AutoGmSummary::LEVEL_SCENE, abstracted: false)
          .order(Sequel.desc(:created_at))
          .first
        parts << "CURRENT SCENE: #{scene_summary.content}" if scene_summary

        # Add recent events summary
        event_summary = session.auto_gm_summaries_dataset
          .where(abstraction_level: AutoGmSummary::LEVEL_EVENTS, abstracted: false)
          .order(Sequel.desc(:created_at))
          .first
        parts << "RECENT EVENTS: #{event_summary.content}" if event_summary

        # Add very recent raw actions (last 3)
        recent_actions = session.auto_gm_actions_dataset
          .where(action_type: 'emit')
          .exclude(emit_text: nil)
          .order(Sequel.desc(:created_at))
          .limit(3)
          .all
          .reverse

        if recent_actions.any?
          parts << "JUST NOW: #{recent_actions.map(&:emit_text).join(' ')}"
        end

        result = parts.join("\n\n")

        # Truncate if too long
        if result.length > max_tokens * 4  # rough char estimate
          result = result[0..(max_tokens * 4)]
          result = "#{result}..."
        end

        result
      end

      # Manually trigger summarization at a specific level
      # @param session [AutoGmSession] the session
      # @param level [Integer] target level
      # @return [AutoGmSummary, nil]
      def summarize_at_level(session, level)
        case level
        when AutoGmSummary::LEVEL_EVENTS
          create_event_summary(session, force: true)
        when AutoGmSummary::LEVEL_SCENE
          create_scene_summary(session, force: true)
        when AutoGmSummary::LEVEL_ACT
          create_act_summary(session, force: true)
        when AutoGmSummary::LEVEL_SESSION
          create_session_summary(session, force: true)
        end
      end

      private

      # Check if we need a new event summary
      # @param session [AutoGmSession] the session
      # @return [Boolean]
      def needs_event_summary?(session)
        # Count actions since last event summary
        last_event_summary = session.auto_gm_summaries_dataset
          .where(abstraction_level: AutoGmSummary::LEVEL_EVENTS)
          .order(Sequel.desc(:created_at))
          .first

        if last_event_summary
          actions_since = session.auto_gm_actions_dataset
            .where { created_at > last_event_summary.created_at }
            .count
        else
          actions_since = session.auto_gm_actions.count
        end

        actions_since >= ACTIONS_PER_EVENT
      end

      # Create an event-level summary
      # @param session [AutoGmSession] the session
      # @param force [Boolean] force creation even if not needed
      # @return [AutoGmSummary, nil]
      def create_event_summary(session, force: false)
        return nil unless force || needs_event_summary?(session)

        # Get actions to summarize
        last_summary = session.auto_gm_summaries_dataset
          .where(abstraction_level: AutoGmSummary::LEVEL_EVENTS)
          .order(Sequel.desc(:created_at))
          .first

        actions = if last_summary
          session.auto_gm_actions_dataset
            .where { created_at > last_summary.created_at }
            .order(:created_at)
            .all
        else
          session.auto_gm_actions_dataset
            .order(:created_at)
            .limit(ACTIONS_PER_EVENT)
            .all
        end

        return nil if actions.empty?

        # Generate summary
        content = generate_summary(session, actions, 'events')
        importance = calculate_importance(actions)

        AutoGmSummary.create_events_summary(session, content, importance: importance)
      end

      # Create a scene-level summary
      # @param session [AutoGmSession] the session
      # @param force [Boolean] force creation
      # @return [AutoGmSummary, nil]
      def create_scene_summary(session, force: false)
        return nil unless force || AutoGmSummary.needs_abstraction?(session, AutoGmSummary::LEVEL_EVENTS)

        event_summaries = AutoGmSummary.unabstracted_at_level(session, AutoGmSummary::LEVEL_EVENTS).all
        return nil if event_summaries.empty?

        # Generate scene summary from event summaries
        content = generate_abstraction(session, event_summaries, 'scene')
        importance = event_summaries.map(&:importance).max

        summary = AutoGmSummary.create_scene_summary(session, content, importance: importance)

        # Mark event summaries as abstracted
        event_summaries.each(&:mark_abstracted!)

        summary
      end

      # Create an act-level summary
      # @param session [AutoGmSession] the session
      # @param force [Boolean] force creation
      # @return [AutoGmSummary, nil]
      def create_act_summary(session, force: false)
        return nil unless force || AutoGmSummary.needs_abstraction?(session, AutoGmSummary::LEVEL_SCENE)

        scene_summaries = AutoGmSummary.unabstracted_at_level(session, AutoGmSummary::LEVEL_SCENE).all
        return nil if scene_summaries.empty?

        content = generate_abstraction(session, scene_summaries, 'act')
        importance = scene_summaries.map(&:importance).max

        summary = AutoGmSummary.create_act_summary(session, content, importance: importance)

        scene_summaries.each(&:mark_abstracted!)

        summary
      end

      # Create a session-level summary
      # @param session [AutoGmSession] the session
      # @param force [Boolean] force creation
      # @return [AutoGmSummary, nil]
      def create_session_summary(session, force: false)
        return nil unless force || AutoGmSummary.needs_abstraction?(session, AutoGmSummary::LEVEL_ACT)

        act_summaries = AutoGmSummary.unabstracted_at_level(session, AutoGmSummary::LEVEL_ACT).all
        return nil if act_summaries.empty?

        content = generate_abstraction(session, act_summaries, 'session')
        importance = 0.9  # Session summaries are always high importance

        summary = AutoGmSummary.create_session_summary(session, content, importance: importance)

        act_summaries.each(&:mark_abstracted!)

        summary
      end

      # Generate a summary from actions using LLM
      # @param session [AutoGmSession] the session
      # @param actions [Array<AutoGmAction>] actions to summarize
      # @param level [String] summary level name
      # @return [String]
      def generate_summary(session, actions, level)
        action_texts = actions.map(&:emit_text).compact.join("\n- ")

        prompt = GamePrompts.get(
          'auto_gm_compression.event_summary',
          title: session.sketch['title'],
          level: level,
          action_texts: action_texts
        )

        result = LLM::Client.generate(
          prompt: prompt,
          provider: 'google_gemini',
          model: 'gemini-3-flash-preview',
          options: { max_tokens: 200, temperature: 0.5 }
        )

        result[:success] ? result[:text].strip : action_texts[0..500]
      end

      # Generate an abstraction from lower-level summaries
      # @param session [AutoGmSession] the session
      # @param summaries [Array<AutoGmSummary>] summaries to abstract
      # @param level [String] target level name
      # @return [String]
      def generate_abstraction(session, summaries, level)
        summary_texts = summaries.map(&:content).join("\n\n")

        prompt = GamePrompts.get(
          'auto_gm_compression.abstraction',
          source_level: summaries.first.level_name,
          target_level: level,
          title: session.sketch['title'],
          summary_texts: summary_texts
        )

        result = LLM::Client.generate(
          prompt: prompt,
          provider: 'google_gemini',
          model: 'gemini-3-flash-preview',
          options: { max_tokens: 300, temperature: 0.5 }
        )

        result[:success] ? result[:text].strip : summary_texts[0..500]
      end

      # Calculate importance score from actions
      # @param actions [Array<AutoGmAction>] actions
      # @return [Float]
      def calculate_importance(actions)
        # Higher importance if actions include significant types
        significant_types = %w[reveal_secret trigger_twist advance_stage start_climax resolve_session]

        significant_count = actions.count { |a| significant_types.include?(a.action_type) }

        base = 0.5
        bonus = significant_count * 0.1

        [base + bonus, 0.9].min
      end
    end
  end
end
