# frozen_string_literal: true

# TriggerService orchestrates trigger detection and execution.
#
# Entry points:
#   - check_mission_triggers() - Called from ActivityService
#   - check_npc_triggers_async() - Called from NpcAnimationHandler (spawns thread)
#   - check_world_memory_triggers() - Called from WorldMemoryService
#   - check_clue_share_triggers() - Called from ClueService
#
module TriggerService
  class << self
    # Check mission-based triggers
    # @param activity_instance [ActivityInstance] The activity instance
    # @param event_type [String] 'succeed', 'fail', 'branch', 'round_complete'
    # @param round [Integer, nil] Round number for round_complete
    # @param branch [Integer, nil] Branch number for branch events
    def check_mission_triggers(activity_instance:, event_type:, round: nil, branch: nil)
      triggers = Trigger.where(
        trigger_type: 'mission',
        is_active: true,
        activity_id: activity_instance.activity_id,
        mission_event_type: event_type
      )

      # Filter by specific round if provided
      triggers = triggers.where(specific_round: round) if round && event_type == 'round_complete'

      # Filter by specific branch if provided
      triggers = triggers.where(specific_branch: branch) if branch && event_type == 'branch'

      # Also include triggers without specific round/branch filters
      if round
        triggers = Trigger.where(
          trigger_type: 'mission',
          is_active: true,
          activity_id: activity_instance.activity_id,
          mission_event_type: event_type
        ).where { Sequel.|({specific_round: round}, {specific_round: nil}) }
      end

      triggers.each do |trigger|
        activate_trigger(
          trigger: trigger,
          source_type: 'system',
          source_character: activity_instance.initiator,
          context: {
            activity_instance_id: activity_instance.id,
            activity_name: activity_instance.activity&.name,
            event_type: event_type,
            round: round,
            branch: branch
          }
        )
      end
    rescue StandardError => e
      warn "[TriggerService] Mission trigger check failed: #{e.message}"
    end

    # Check NPC emote triggers (async - uses LLM)
    # @param npc_instance [CharacterInstance] The NPC instance
    # @param emote_content [String] The emote text
    # @param arranged_scene_id [Integer, nil] Optional scene ID for scene-specific triggers
    def check_npc_triggers_async(npc_instance:, emote_content:, arranged_scene_id: nil)
      Thread.new do
        check_npc_triggers(
          npc_instance: npc_instance,
          emote_content: emote_content,
          arranged_scene_id: arranged_scene_id
        )
      rescue StandardError => e
        warn "[TriggerService] NPC trigger check failed: #{e.message}"
      end
    end

    # Check NPC emote triggers (sync version for testing)
    # @param npc_instance [CharacterInstance] The NPC instance
    # @param emote_content [String] The emote text
    # @param arranged_scene_id [Integer, nil] Optional scene ID for scene-specific triggers
    def check_npc_triggers(npc_instance:, emote_content:, arranged_scene_id: nil)
      return if emote_content.nil? || emote_content.strip.empty?

      npc = npc_instance.character
      return unless npc&.npc?

      # Find applicable triggers with scene scope filtering
      triggers = Trigger.where(trigger_type: 'npc', is_active: true)

      # Include global triggers (no scene) + scene-specific triggers if in a scene
      if arranged_scene_id
        triggers = triggers.where(
          Sequel.|(
            { arranged_scene_id: nil },
            { arranged_scene_id: arranged_scene_id }
          )
        )
      else
        # Only global triggers when not in a scene
        triggers = triggers.where(arranged_scene_id: nil)
      end

      triggers = triggers.all

      # Filter to triggers that apply to this NPC
      applicable_triggers = triggers.select { |t| t.applies_to_npc?(npc) }

      applicable_triggers.each do |trigger|
        match_result = check_trigger_match(trigger, emote_content)
        next unless match_result[:matched]

        activate_trigger(
          trigger: trigger,
          source_type: 'npc',
          source_character: npc,
          source_instance: npc_instance,
          triggering_content: emote_content,
          matching_details: match_result[:details],
          llm_confidence: match_result[:confidence],
          llm_reasoning: match_result[:reasoning],
          context: {
            room_id: npc_instance.current_room_id,
            npc_name: npc.full_name,
            npc_archetype_id: npc.npc_archetype_id
          }
        )
      end
    rescue StandardError => e
      warn "[TriggerService] NPC trigger check failed: #{e.message}"
    end

    # Check world memory triggers
    # @param world_memory [WorldMemory] The newly created world memory
    def check_world_memory_triggers(world_memory:)
      triggers = Trigger.where(trigger_type: 'world_memory', is_active: true).all

      triggers.each do |trigger|
        next unless memory_matches_trigger?(world_memory, trigger)

        # Check content match
        content = world_memory.summary || world_memory.raw_log
        match_result = check_trigger_match(trigger, content)
        next unless match_result[:matched]

        # Get involved characters for context
        character_names = world_memory.characters.map(&:full_name).join(', ')

        activate_trigger(
          trigger: trigger,
          source_type: 'system',
          triggering_content: content,
          matching_details: match_result[:details],
          llm_confidence: match_result[:confidence],
          llm_reasoning: match_result[:reasoning],
          context: {
            world_memory_id: world_memory.id,
            publicity_level: world_memory.publicity_level,
            importance: world_memory.importance,
            room_id: world_memory.primary_room&.id,
            characters_involved: character_names
          }
        )
      end
    rescue StandardError => e
      warn "[TriggerService] World memory trigger check failed: #{e.message}"
    end

    # Check clue share triggers
    # @param clue [Clue] The shared clue
    # @param npc [Character] The NPC who shared
    # @param recipient [Character] The PC who received
    # @param room [Room, nil] The room where shared
    def check_clue_share_triggers(clue:, npc:, recipient:, room: nil)
      triggers = Trigger.where(trigger_type: 'clue_share', is_active: true).all

      triggers.each do |trigger|
        # Check if trigger applies to this clue/NPC
        next unless clue_matches_trigger?(clue, npc, trigger)

        content = "#{npc.full_name} shared clue '#{clue.name}' with #{recipient.full_name}: #{clue.content}"
        match_result = check_trigger_match(trigger, content)
        next unless match_result[:matched]

        activate_trigger(
          trigger: trigger,
          source_type: 'npc',
          source_character: npc,
          triggering_content: content,
          matching_details: match_result[:details],
          llm_confidence: match_result[:confidence],
          llm_reasoning: match_result[:reasoning],
          clue: clue,
          clue_recipient: recipient,
          context: {
            clue_id: clue.id,
            clue_name: clue.name,
            npc_id: npc.id,
            npc_name: npc.full_name,
            recipient_id: recipient.id,
            recipient_name: recipient.full_name,
            room_id: room&.id
          }
        )
      end
    rescue StandardError => e
      warn "[TriggerService] Clue share trigger check failed: #{e.message}"
    end

    private

    # Check if world memory matches trigger filters
    def memory_matches_trigger?(memory, trigger)
      # Check publicity filter
      if trigger.memory_publicity_filter && trigger.memory_publicity_filter != 'any'
        return false unless memory.publicity_level == trigger.memory_publicity_filter
      end

      # Check importance
      if trigger.min_importance
        return false unless (memory.importance || 5) >= trigger.min_importance
      end

      # Check character filters
      filters = trigger.character_filters || {}
      if filters['required_character_ids']
        memory_char_ids = memory.characters.map(&:id)
        required_ids = filters['required_character_ids'].map(&:to_i)
        return false unless (required_ids - memory_char_ids).empty?
      end

      true
    end

    # Check if clue share matches trigger filters
    def clue_matches_trigger?(clue, npc, trigger)
      # If trigger has specific NPC filter
      if trigger.npc_character_id
        return false unless trigger.npc_character_id == npc.id
      end

      # Could add clue-specific filters here in the future
      true
    end

    # Check if content matches trigger condition
    def check_trigger_match(trigger, content)
      return { matched: true, details: 'No condition', confidence: 1.0 } if trigger.condition_value.nil? || trigger.condition_value.strip.empty?

      case trigger.condition_type
      when 'exact'
        matched = content.to_s.downcase.strip == trigger.condition_value.downcase.strip
        { matched: matched, details: 'Exact match', confidence: matched ? 1.0 : 0.0 }

      when 'contains'
        matched = content.to_s.downcase.include?(trigger.condition_value.downcase)
        { matched: matched, details: "Contains '#{trigger.condition_value}'", confidence: matched ? 1.0 : 0.0 }

      when 'regex'
        begin
          regex = Regexp.new(trigger.condition_value, Regexp::IGNORECASE)
          matched = content.to_s.match?(regex)
          { matched: matched, details: "Regex: #{trigger.condition_value}", confidence: matched ? 1.0 : 0.0 }
        rescue RegexpError => e
          { matched: false, details: "Invalid regex: #{e.message}", confidence: 0.0 }
        end

      when 'llm_match'
        TriggerLLMMatcherService.check_match(
          content: content.to_s,
          prompt: trigger.llm_match_prompt || trigger.condition_value,
          threshold: trigger.llm_match_threshold || 0.7
        )

      else
        { matched: false, details: 'Unknown condition type', confidence: 0.0 }
      end
    end

    # Activate a trigger - create record and execute actions
    def activate_trigger(trigger:, source_type:, source_character: nil, source_instance: nil,
                         triggering_content: nil, matching_details: nil, llm_confidence: nil,
                         llm_reasoning: nil, context: {}, clue: nil, clue_recipient: nil)

      activation = TriggerActivation.create(
        trigger_id: trigger.id,
        source_type: source_type,
        source_character_id: source_character&.id,
        source_instance_id: source_instance&.id,
        triggering_content: triggering_content,
        matching_details: matching_details,
        llm_confidence: llm_confidence,
        llm_reasoning: llm_reasoning,
        context_data: Sequel.pg_jsonb(context),
        clue_id: clue&.id,
        clue_recipient_id: clue_recipient&.id,
        activated_at: Time.now
      )

      # Execute actions
      execute_trigger_actions(trigger, activation, context)

      activation
    end

    # Execute trigger actions (code block and/or alerts)
    def execute_trigger_actions(trigger, activation, context)
      success = true
      result = nil
      error = nil

      begin
        # Execute code block if configured
        if trigger.should_execute_code? && trigger.code_block && !trigger.code_block.strip.empty?
          result = TriggerCodeExecutor.execute(
            code: trigger.code_block,
            context: context,
            activation: activation
          )
        end

        # Send staff alerts if configured
        if trigger.should_alert_staff?
          StaffAlertService.send_trigger_alert(
            trigger: trigger,
            activation: activation,
            send_discord: trigger.send_discord,
            send_email: trigger.send_email,
            email_recipients: trigger.email_recipients
          )
        end
      rescue StandardError => e
        success = false
        error = e.message
        warn "[TriggerService] Action execution failed: #{e.message}"
      end

      activation.update(
        action_executed: true,
        action_success: success,
        action_result: result.to_s,
        action_error: error
      )
    end
  end
end
