# frozen_string_literal: true

# Service for orchestrating the abuse monitoring system.
#
# Provides the main entry point for checking messages for abuse,
# manages settings, and coordinates with detection and moderation services.
#
# Two-tier AI moderation:
# 1. Gemini Flash 2.5-lite for quick initial screening
# 2. Claude Opus 4.5 for verification of flagged content
#
# Usage:
#   result = AbuseMonitoringService.check_message(
#     content: "Hello world",
#     message_type: 'say',
#     character_instance: ci
#   )
#   # => { allowed: true, delayed: false, check_id: nil }
#
class AbuseMonitoringService
  extend StringHelper

  # Setting keys
  ENABLED_KEY = 'abuse_monitoring_enabled'
  DELAY_MODE_KEY = 'abuse_monitoring_delay_mode'
  THRESHOLD_KEY = 'abuse_monitoring_playtime_threshold'

  # Default playtime threshold before abuse monitoring activates (in hours)
  DEFAULT_THRESHOLD_HOURS = 100

  class << self
    # Main entry point - check a message for abuse
    #
    # @param content [String] The message content
    # @param message_type [String] Type of message (say, emote, whisper, etc.)
    # @param character_instance [CharacterInstance] The sender
    # @param context [Hash] Additional context (room name, recent messages)
    # @return [Hash] { allowed: Boolean, delayed: Boolean, check_id: Integer|nil, error: String|nil }
    def check_message(content:, message_type:, character_instance:, context: {})
      # Skip if disabled
      return allow_result unless enabled?

      # Skip empty messages
      return allow_result if blank?(content)

      # Pre-LLM screening (runs for ALL users - no exemption for exploits)
      pre_llm_result = ContentScreeningService.screen(
        content: content,
        character_instance: character_instance,
        message_type: message_type
      )

      if pre_llm_result[:flagged]
        return handle_pre_llm_detection(
          pre_llm_result: pre_llm_result,
          character_instance: character_instance,
          content: content,
          message_type: message_type,
          context: context
        )
      end

      # Add universe theme for LLM context
      context[:universe_theme] = universe_theme(character_instance)

      # Skip LLM checks if user is exempt (100+ hours playtime, unless override active)
      return allow_result if exempt?(character_instance)

      # Create abuse check record
      check = AbuseCheck.create_for_message(
        content: content,
        message_type: message_type,
        character_instance: character_instance,
        context: context
      )

      if delay_mode?
        # Synchronous check - block until verified
        process_sync(check)
      else
        # Async check - allow message, process in background
        process_async(check)
        allow_result(check_id: check.id)
      end
    rescue StandardError => e
      warn "[AbuseMonitoring] Error checking message: #{e.class}: #{e.message}"
      # On error, allow the message but log the issue
      allow_result(error: e.message)
    end

    # Check if abuse monitoring is enabled
    #
    # @return [Boolean]
    def enabled?
      GameSetting.boolean(ENABLED_KEY)
    end

    # Enable abuse monitoring
    #
    # @return [Boolean]
    def enable!
      GameSetting.set(ENABLED_KEY, true, type: 'boolean')
      true
    end

    # Disable abuse monitoring
    #
    # @return [Boolean]
    def disable!
      GameSetting.set(ENABLED_KEY, false, type: 'boolean')
      true
    end

    # Check if delay mode is enabled (wait for check vs allow through)
    #
    # @return [Boolean]
    def delay_mode?
      GameSetting.boolean(DELAY_MODE_KEY)
    end

    # Set delay mode
    #
    # @param enabled [Boolean]
    # @return [Boolean]
    def set_delay_mode!(enabled)
      GameSetting.set(DELAY_MODE_KEY, enabled, type: 'boolean')
      true
    end

    # Get playtime threshold for exemption (in hours)
    #
    # @return [Integer]
    def playtime_threshold_hours
      GameSetting.integer(THRESHOLD_KEY) || GameConfig::Moderation::ABUSE_THRESHOLD_HOURS
    end

    # Set playtime threshold for exemption
    #
    # @param hours [Integer]
    # @return [Boolean]
    def set_playtime_threshold!(hours)
      GameSetting.set(THRESHOLD_KEY, hours.to_i, type: 'integer')
      true
    end

    # Check if a character is exempt from abuse checks
    #
    # @param character_instance [CharacterInstance]
    # @return [Boolean]
    def exempt?(character_instance)
      return false if override_active?  # Staff override bypasses all exemptions

      user = character_instance&.character&.user
      return false unless user

      threshold_seconds = playtime_threshold_hours * 3600
      (user.total_playtime_seconds || 0) >= threshold_seconds
    end

    # Check if a staff override is currently active
    #
    # @return [Boolean]
    def override_active?
      AbuseMonitoringOverride.active?
    end

    # Get the current active override (if any)
    #
    # @return [AbuseMonitoringOverride, nil]
    def current_override
      AbuseMonitoringOverride.current
    end

    # Activate a staff override (check all players for 1 hour)
    #
    # @param staff_user [User] The staff member triggering the override
    # @param reason [String, nil] Optional reason
    # @param duration_seconds [Integer] Duration (default: 1 hour)
    # @return [AbuseMonitoringOverride]
    def activate_override!(staff_user:, reason: nil, duration_seconds: 3600)
      AbuseMonitoringOverride.activate!(
        staff_user: staff_user,
        reason: reason,
        duration_seconds: duration_seconds
      )
    end

    # Deactivate all active overrides
    #
    # @return [Integer] Number of overrides deactivated
    def deactivate_overrides!
      AbuseMonitoringOverride.where(active: true).update(active: false)
    end

    # Process pending abuse checks (called by scheduler)
    #
    # @param limit [Integer] Max checks to process
    # @return [Hash] { gemini: Integer, escalated: Integer, errors: Integer }
    def process_pending_checks!(limit: 10)
      return { gemini: 0, escalated: 0, errors: 0 } unless enabled?

      results = { gemini: 0, escalated: 0, errors: 0 }

      # Process pending Gemini checks
      AbuseCheck.pending_gemini_checks(limit: limit).each do |check|
        begin
          process_gemini_check(check)
          results[:gemini] += 1
        rescue StandardError => e
          warn "[AbuseMonitoring] Error in Gemini check ##{check.id}: #{e.message}"
          results[:errors] += 1
        end
      end

      # Process pending escalations
      AbuseCheck.pending_escalation(limit: limit).each do |check|
        begin
          process_claude_verification(check)
          results[:escalated] += 1
        rescue StandardError => e
          warn "[AbuseMonitoring] Error in Claude verification ##{check.id}: #{e.message}"
          results[:errors] += 1
        end
      end

      results
    end

    # Get status summary for admin dashboard
    #
    # @return [Hash]
    def status
      {
        enabled: enabled?,
        delay_mode: delay_mode?,
        playtime_threshold_hours: playtime_threshold_hours,
        override_active: override_active?,
        override: current_override&.to_admin_hash,
        pending_checks: AbuseCheck.where(status: 'pending').count,
        flagged_checks: AbuseCheck.where(status: 'flagged').count,
        confirmed_today: AbuseCheck.where(status: 'confirmed')
                                   .where { created_at > Time.now - GameConfig::Timeouts::ABUSE_CHECK_WINDOW_SECONDS }
                                   .count
      }
    end

    private

    # Process synchronous check (delay mode)
    def process_sync(check)
      start_time = Time.now

      # First pass: Gemini
      check.start_gemini_check!
      gemini_result = AbuseDetectionService.gemini_check(check)

      if gemini_result[:flagged]
        check.mark_gemini_result!(
          flagged: true,
          confidence: gemini_result[:confidence],
          reasoning: gemini_result[:reasoning],
          category: gemini_result[:category]
        )

        # Second pass: Claude verification
        check.start_escalation!
        claude_result = AbuseDetectionService.claude_verify(check)

        processing_time = ((Time.now - start_time) * 1000).to_i

        if claude_result[:confirmed]
          check.mark_claude_result!(
            confirmed: true,
            confidence: claude_result[:confidence],
            reasoning: claude_result[:reasoning],
            category: claude_result[:category],
            severity: claude_result[:severity],
            processing_time_ms: processing_time
          )

          # Execute moderation actions
          AutoModerationService.execute_actions(check)

          deny_result(check_id: check.id, reason: 'Content flagged for moderation review')
        else
          check.mark_claude_result!(
            confirmed: false,
            confidence: claude_result[:confidence],
            reasoning: claude_result[:reasoning],
            category: 'false_positive',
            processing_time_ms: processing_time
          )
          allow_result(check_id: check.id, delayed: true)
        end
      else
        check.mark_gemini_result!(
          flagged: false,
          confidence: gemini_result[:confidence],
          reasoning: gemini_result[:reasoning]
        )
        allow_result(check_id: check.id, delayed: true)
      end
    end

    # Process async check (non-delay mode) - just queue for background processing
    def process_async(check)
      # Mark as delayed for background processing
      check.update(message_delayed: false)
      # Background processor will handle the rest
    end

    # Process a single Gemini check
    def process_gemini_check(check)
      check.start_gemini_check!
      result = AbuseDetectionService.gemini_check(check)

      check.mark_gemini_result!(
        flagged: result[:flagged],
        confidence: result[:confidence],
        reasoning: result[:reasoning],
        category: result[:category]
      )

      # If flagged, it will be picked up for escalation in the next cycle
    end

    # Process Claude verification for a flagged check
    def process_claude_verification(check)
      start_time = Time.now
      check.start_escalation!

      result = AbuseDetectionService.claude_verify(check)
      processing_time = ((Time.now - start_time) * 1000).to_i

      if result[:confirmed]
        check.mark_claude_result!(
          confirmed: true,
          confidence: result[:confidence],
          reasoning: result[:reasoning],
          category: result[:category],
          severity: result[:severity],
          processing_time_ms: processing_time
        )

        # Execute moderation actions (async mode - post-hoc moderation)
        AutoModerationService.execute_actions(check)
      else
        check.mark_claude_result!(
          confirmed: false,
          confidence: result[:confidence],
          reasoning: result[:reasoning],
          category: 'false_positive',
          processing_time_ms: processing_time
        )
      end
    end

    # Helper to build allow result
    def allow_result(check_id: nil, delayed: false, error: nil)
      {
        allowed: true,
        delayed: delayed,
        check_id: check_id,
        error: error
      }
    end

    # Helper to build deny result
    def deny_result(check_id:, reason:)
      {
        allowed: false,
        delayed: true,
        check_id: check_id,
        reason: reason
      }
    end

    # Handle pre-LLM detection results (exploits, prompt injection)
    # These are immediate blocks with no exemption
    def handle_pre_llm_detection(pre_llm_result:, character_instance:, content:, message_type:, context:)
      # Create abuse check record for the pre-LLM detection
      check = AbuseCheck.create_for_pre_llm_detection(
        content: content,
        message_type: message_type,
        character_instance: character_instance,
        pre_llm_result: pre_llm_result,
        context: context
      )

      # Execute immediate moderation for exploits
      AutoModerationService.execute_actions(check)

      deny_result(
        check_id: check.id,
        reason: "Message blocked: #{pre_llm_result[:category].to_s.gsub('_', ' ')}"
      )
    end

    # Get the universe/setting theme for immersion context
    def universe_theme(character_instance)
      return 'fantasy' unless character_instance

      room = character_instance.current_room
      return 'fantasy' unless room

      location = room.location
      return 'fantasy' unless location

      zone = location.zone
      return 'fantasy' unless zone

      world = zone.world
      return 'fantasy' unless world

      universe = world.universe
      return 'fantasy' unless universe

      # Use universe theme or default to fantasy
      universe.theme.to_s.strip.empty? ? 'fantasy' : universe.theme
    rescue StandardError => e
      warn "[AbuseMonitoring] Error getting universe theme: #{e.message}"
      'fantasy'
    end
  end
end
