# frozen_string_literal: true

module AutoGm
  # AutoGmEventService handles chaos-driven random events during Auto-GM sessions.
  #
  # Uses a Chaos Factor (1-9) to determine event probability:
  # - Higher chaos = more random events
  # - Doubles rule: If a d100 roll shows doubles (11, 22, 33, etc.) AND
  #   the tens digit <= chaos factor, a random event triggers
  #
  # Event Focus Table determines what kind of event occurs:
  # - Remote Event: Something happens elsewhere affecting the adventure
  # - NPC Action: An NPC takes unexpected action
  # - Introduce NPC: A new NPC appears
  # - Move Toward Thread: Progress toward the mission
  # - Move Away Thread: Setback to the mission
  # - Close Thread: A subplot resolves
  # - PC Negative: Bad luck for a PC
  # - PC Positive: Good luck for a PC
  # - Ambiguous: Something unclear happens
  # - NPC Negative: Bad for an NPC
  # - NPC Positive: Good for an NPC
  #
  class AutoGmEventService
    # Event Focus Table
    EVENT_FOCUS = [
      { range: 1..7,    focus: :remote_event,     description: 'Something happens elsewhere that affects the adventure' },
      { range: 8..28,   focus: :npc_action,       description: 'An NPC takes unexpected action' },
      { range: 29..35,  focus: :introduce_npc,    description: 'A new NPC appears' },
      { range: 36..45,  focus: :move_toward,      description: 'Progress toward the mission' },
      { range: 46..52,  focus: :move_away,        description: 'Setback to the mission' },
      { range: 53..55,  focus: :close_thread,     description: 'A subplot resolves' },
      { range: 56..67,  focus: :pc_negative,      description: 'Bad luck for a PC' },
      { range: 68..75,  focus: :pc_positive,      description: 'Good luck for a PC' },
      { range: 76..83,  focus: :ambiguous,        description: 'Something unclear happens' },
      { range: 84..92,  focus: :npc_negative,     description: 'Bad for an NPC' },
      { range: 93..100, focus: :npc_positive,     description: 'Good for an NPC' }
    ].freeze

    extend AutoGm::AutoGmFormatHelper

    class << self
      # Check if a random event should trigger
      # @param session [AutoGmSession] the session
      # @param roll_value [Integer, nil] override roll value (for testing)
      # @return [AutoGmAction, nil] the event action if triggered
      def check_random_event(session, roll_value = nil)
        roll_value ||= rand(1..100)

        return nil unless should_trigger?(roll_value, session.chaos_level)

        generate_random_event(session)
      end

      # Force a random event (for testing or GM override)
      # @param session [AutoGmSession] the session
      # @param focus [Symbol, nil] specific focus to use
      # @return [AutoGmAction] the event action
      def force_event(session, focus: nil)
        if focus
          focus_entry = EVENT_FOCUS.find { |f| f[:focus] == focus }
        else
          focus_roll = rand(1..100)
          focus_entry = EVENT_FOCUS.find { |f| f[:range].include?(focus_roll) }
        end

        generate_event_for_focus(session, focus_entry)
      end

      # Adjust chaos level based on whether PCs are in control
      # @param session [AutoGmSession] the session
      # @param pc_in_control [Boolean] whether PCs are in control of the situation
      def adjust_chaos(session, pc_in_control:)
        if pc_in_control
          # PCs in control = decrease chaos (more predictable)
          new_chaos = [1, session.chaos_level - 1].max
        else
          # PCs not in control = increase chaos (more unpredictable)
          new_chaos = [9, session.chaos_level + 1].min
        end

        session.adjust_chaos!(new_chaos - session.chaos_level) if new_chaos != session.chaos_level
      end

      # Get the event focus for a given roll
      # @param roll [Integer] d100 roll
      # @return [Hash] focus entry
      def focus_for_roll(roll)
        EVENT_FOCUS.find { |f| f[:range].include?(roll) }
      end

      private

      # Check if a random event should trigger based on doubles rule
      # @param roll_value [Integer] the d100 roll
      # @param chaos_level [Integer] current chaos (1-9)
      # @return [Boolean]
      def should_trigger?(roll_value, chaos_level)
        # Check for doubles (11, 22, 33, etc.)
        tens = roll_value / 10
        ones = roll_value % 10

        return false unless tens == ones  # Must be doubles
        tens <= chaos_level  # Tens digit must be <= chaos
      end

      # Generate a random event for the session
      # @param session [AutoGmSession] the session
      # @return [AutoGmAction] the event action
      def generate_random_event(session)
        focus_roll = rand(1..100)
        focus_entry = EVENT_FOCUS.find { |f| f[:range].include?(focus_roll) }

        generate_event_for_focus(session, focus_entry)
      end

      # Generate an event for a specific focus
      # @param session [AutoGmSession] the session
      # @param focus_entry [Hash] the focus entry
      # @return [AutoGmAction]
      def generate_event_for_focus(session, focus_entry)
        event_text = contextualize_event(session, focus_entry)
        formatted = format_event_message(event_text)

        # Create the event action — store plain text for LLM context
        action = AutoGmAction.create_with_next_sequence(
          session_id: session.id,
          attributes: {
            action_type: 'emit',
            status: 'pending',
            emit_text: "Random Event: #{strip_markdown(event_text)}",
            action_data: {
              event_type: 'random_event',
              focus: focus_entry[:focus].to_s,
              focus_description: focus_entry[:description]
            },
            ai_reasoning: "Chaos-driven random event triggered (focus: #{focus_entry[:focus]})"
          },
        )

        # Broadcast the event
        room_id = session.current_room_id || session.starting_room_id
        BroadcastService.to_room(
          room_id,
          formatted,
          type: :auto_gm_random_event,
          auto_gm_session_id: session.id
        )

        # Log Auto-GM random event to character stories
        IcActivityService.record(
          room_id: room_id, content: formatted[:content],
          sender: nil, type: :auto_gm
        )

        action.complete!
        action
      end

      # Contextualize the event using LLM
      # Uses Sonnet 4.5 for quality narrative consistency with the main GM
      # @param session [AutoGmSession] the session
      # @param focus_entry [Hash] the focus entry
      # @return [String] contextualized event description
      def contextualize_event(session, focus_entry)
        prompt = build_event_prompt(session, focus_entry)

        result = LLM::Client.generate(
          prompt: prompt,
          provider: 'anthropic',
          model: 'claude-sonnet-4-6',
          options: {
            max_tokens: 400,
            temperature: 0.9,
            timeout: 30
          }
        )

        result[:success] ? result[:text].strip : focus_entry[:description]
      end

      # Build prompt for event contextualization
      # @param session [AutoGmSession] the session
      # @param focus_entry [Hash] the focus entry
      # @return [String] the prompt
      def build_event_prompt(session, focus_entry)
        sketch = session.sketch
        world_state = session.world_state || {}

        GamePrompts.get(
          'auto_gm_event.contextualize',
          title: sketch['title'],
          mission_objective: sketch.dig('mission', 'objective'),
          current_stage: session.current_stage,
          status: session.status,
          chaos_level: session.chaos_level,
          focus: focus_entry[:focus],
          focus_description: focus_entry[:description],
          npcs: format_list(world_state['npcs_spawned']),
          secrets: format_list(world_state['secrets_revealed']),
          characters: session.participant_instances.map { |p| DisplayHelper.character_display_name(p) }.join(', '),
          focus_instruction: focus_specific_instruction(focus_entry[:focus])
        )
      end

      # Get focus-specific writing instructions
      # @param focus [Symbol] the focus type
      # @return [String] instruction
      def focus_specific_instruction(focus)
        case focus
        when :remote_event
          'Describe something happening elsewhere that the characters learn about or sense.'
        when :npc_action
          'An existing NPC does something unexpected. Name them specifically.'
        when :introduce_npc
          'A new character appears on the scene. Describe them briefly.'
        when :move_toward
          'Something happens that brings the characters closer to their goal.'
        when :move_away
          'A setback occurs that complicates the mission.'
        when :close_thread
          'A minor subplot or concern is resolved, for better or worse.'
        when :pc_negative
          'Something unfortunate happens to or around the characters.'
        when :pc_positive
          'The characters catch a lucky break or find an advantage.'
        when :ambiguous
          'Something strange or unclear happens. Let the players interpret it.'
        when :npc_negative
          'Something bad happens to an NPC in the adventure.'
        when :npc_positive
          'An NPC gains an advantage or has something good happen to them.'
        else
          'Describe a dramatic development.'
        end
      end

      # NOTE: format_list is inherited from AutoGmFormatHelper

    end
  end
end
