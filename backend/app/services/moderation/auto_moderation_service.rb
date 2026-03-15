# frozen_string_literal: true

# Service for executing automatic moderation actions on confirmed abuse.
#
# Graduated response system:
# - Serious abuse (hate_speech, threats, doxxing, csam, exploit_attempt):
#   Immediate permanent ban with IP blocks
# - Lesser offenses (spam, immersion_breaking, griefing):
#   Warning → Temp mute (15 min) → 1-week suspension
#
# All actions are logged in the moderation_actions table for audit.
#
class AutoModerationService
  extend StringHelper

  # Duration constants (from centralized config)
  IP_BAN_DURATION = GameConfig::Moderation::DURATIONS[:ip_ban]
  RANGE_BAN_DURATION = GameConfig::Moderation::DURATIONS[:range_ban]
  REGISTRATION_FREEZE_DURATION = GameConfig::Moderation::DURATIONS[:registration_freeze]
  ONE_WEEK_SUSPENSION = GameConfig::Moderation::DURATIONS[:suspension]
  TEMP_MUTE_DURATION = GameConfig::Moderation::DURATIONS[:temp_mute]

  # Setting key for registration freeze
  REGISTRATION_FREEZE_KEY = 'registration_frozen_until'

  # Categories requiring immediate permanent action
  SERIOUS_ABUSE_CATEGORIES = %w[
    hate_speech threats doxxing csam exploit_attempt
  ].freeze

  # Categories using graduated response
  GRADUATED_RESPONSE_CATEGORIES = %w[
    spam immersion_breaking griefing
  ].freeze

  class << self
    # Execute all moderation actions for a confirmed abuse check
    #
    # @param check [AbuseCheck] The confirmed abuse check
    # @return [Array<ModerationAction>] The actions taken
    def execute_actions(check)
      return [] unless check.abuse_confirmed? || check.pre_llm_detected?

      category = check.abuse_category
      user = check.user

      if SERIOUS_ABUSE_CATEGORIES.include?(category)
        execute_serious_abuse_actions(check)
      elsif GRADUATED_RESPONSE_CATEGORIES.include?(category)
        execute_graduated_response(check)
      else
        # Default to serious for unknown categories (harassment, other)
        execute_serious_abuse_actions(check)
      end
    rescue StandardError => e
      warn "[AutoModeration] Error executing actions for check ##{check.id}: #{e.message}"
      notify_staff_error(check, e)
      []
    end

    # Execute full moderation for serious abuse (permanent ban)
    def execute_serious_abuse_actions(check)
      user = check.user
      ip_address = check.ip_address

      actions = []

      # 1. Ban specific IP for 3 months
      actions << ban_ip(user, ip_address, check)

      # 2. Ban IP range (/24) for 24 hours
      actions << ban_ip_range(user, ip_address, check)

      # 3. Suspend new account creation for 1 hour
      actions << freeze_registration(check)

      # 4. Disable user account (permanent)
      actions << suspend_user(user, check, permanent: true)

      # 5. Logout all characters
      actions << logout_all_characters(user, check)

      # 6. Notify staff
      notify_staff(check, actions)

      # Update the check with action taken
      check.mark_actioned!('moderated')

      warn "[AutoModeration] Executed #{actions.compact.length} serious abuse actions for check ##{check.id}"
      actions.compact
    end

    # Execute graduated response for lesser offenses
    # Warning → Temp mute → 1-week suspension
    def execute_graduated_response(check)
      user = check.user
      return [] unless user

      actions = []
      warning_count = warning_count(user, check.abuse_category)

      case warning_count
      when 0
        # First offense: Warning only
        actions << issue_warning(user, check)
        notify_staff(check, actions, level: 'warning')
        check.mark_actioned!('warned')
      when 1
        # Second offense: Temp mute (15 minutes)
        actions << issue_warning(user, check)
        actions << temp_mute_user(user, check)
        notify_staff(check, actions, level: 'mute')
        check.mark_actioned!('muted')
      else
        # Third+ offense: 1-week suspension
        actions << issue_warning(user, check)
        actions << suspend_user(user, check, permanent: false, duration: ONE_WEEK_SUSPENSION)
        actions << logout_all_characters(user, check)
        notify_staff(check, actions, level: 'suspension')
        check.mark_actioned!('suspended')
      end

      warn "[AutoModeration] Graduated response (level #{warning_count + 1}) for check ##{check.id}"
      actions.compact
    end

    # Get the warning count for a user in a specific category
    def warning_count(user, category)
      return 0 unless user

      # Count previous warnings/actions in the same category
      ModerationAction.where(user_id: user.id)
                      .where { created_at > Time.now - (30 * 24 * 3600) }  # Last 30 days
                      .where(action_type: 'warning')
                      .count
    end

    # Check if registration is currently frozen
    #
    # @return [Boolean]
    def registration_frozen?
      frozen_until = GameSetting.get(REGISTRATION_FREEZE_KEY)
      return false if blank?(frozen_until)

      begin
        Time.parse(frozen_until) > Time.now
      rescue ArgumentError
        false
      end
    end

    # Get when registration freeze expires
    #
    # @return [Time, nil]
    def registration_frozen_until
      frozen_until = GameSetting.get(REGISTRATION_FREEZE_KEY)
      return nil if blank?(frozen_until)

      begin
        freeze_time = Time.parse(frozen_until)
        freeze_time > Time.now ? freeze_time : nil
      rescue ArgumentError
        nil
      end
    end

    # Manually reverse a moderation action
    #
    # @param action [ModerationAction] The action to reverse
    # @param by_user [User] Staff member reversing
    # @param reason [String] Reason for reversal
    # @return [Boolean] Success
    def reverse_action!(action, by_user:, reason:)
      return false if action.reversed

      case action.action_type
      when 'ip_ban'
        reverse_ip_ban(action)
      when 'range_ban'
        reverse_range_ban(action)
      when 'suspend'
        reverse_suspension(action)
      when 'registration_freeze'
        reverse_registration_freeze
      end

      action.reverse!(by_user: by_user, reason: reason)
      true
    rescue StandardError => e
      warn "[AutoModeration] Error reversing action ##{action.id}: #{e.message}"
      false
    end

    private

    # Ban specific IP for 3 months
    def ban_ip(user, ip_address, check)
      return nil unless ip_address && !ip_address.to_s.strip.empty?

      expires_at = Time.now + IP_BAN_DURATION

      # Create the actual IP ban
      IpBan.ban_ip!(
        ip_address,
        reason: "Auto-moderation: #{check.abuse_category} (check ##{check.id})",
        expires_at: expires_at
      )

      # Log the action
      ModerationAction.create_ip_ban(
        user: user,
        ip_address: ip_address,
        reason: "Confirmed abuse: #{check.abuse_category}",
        duration_seconds: IP_BAN_DURATION,
        abuse_check: check
      )
    end

    # Ban IP range (/24) for 24 hours
    def ban_ip_range(user, ip_address, check)
      return nil unless ip_address && !ip_address.to_s.strip.empty?

      # Convert IP to /24 range
      parts = ip_address.to_s.split('.')
      return nil if parts.length != 4

      range = "#{parts[0..2].join('.')}.0/24"
      expires_at = Time.now + RANGE_BAN_DURATION

      # Create the IP range ban
      IpBan.ban_ip!(
        range,
        reason: "Auto-moderation range ban: #{check.abuse_category} (check ##{check.id})",
        expires_at: expires_at
      )

      # Log the action
      ModerationAction.create_range_ban(
        user: user,
        ip_range: range,
        reason: "Confirmed abuse: #{check.abuse_category}",
        duration_seconds: RANGE_BAN_DURATION,
        abuse_check: check
      )
    end

    # Freeze new account registration for 1 hour
    def freeze_registration(check)
      expires_at = Time.now + REGISTRATION_FREEZE_DURATION
      GameSetting.set(REGISTRATION_FREEZE_KEY, expires_at.iso8601, type: 'string')

      ModerationAction.create_registration_freeze(
        reason: "Auto-freeze due to confirmed abuse (check ##{check.id})",
        duration_seconds: REGISTRATION_FREEZE_DURATION,
        abuse_check: check
      )
    end

    # Issue a warning to the user (logged but no action)
    def issue_warning(user, check)
      return nil unless user

      ModerationAction.create(
        user_id: user.id,
        action_type: 'warning',
        reason: "Warning for #{check.abuse_category}: #{truncate(check.message_content, 100)}",
        abuse_check_id: check.id,
        warning_count: warning_count(user, check.abuse_category) + 1
      )
    end

    # Temporarily mute a user (can't send messages)
    def temp_mute_user(user, check)
      return nil unless user

      user.mute!(TEMP_MUTE_DURATION)

      ModerationAction.create(
        user_id: user.id,
        action_type: 'temp_mute',
        reason: "Temp mute for #{check.abuse_category}: #{truncate(check.message_content, 100)}",
        duration_seconds: TEMP_MUTE_DURATION,
        abuse_check_id: check.id,
        is_temp_mute: true,
        temp_mute_duration_seconds: TEMP_MUTE_DURATION,
        expires_at: Time.now + TEMP_MUTE_DURATION
      )
    end

    # Suspend user account
    # @param permanent [Boolean] If true, permanent until staff review. If false, timed.
    # @param duration [Integer] Duration in seconds (only if permanent: false)
    def suspend_user(user, check, permanent: true, duration: nil)
      return nil unless user

      until_time = permanent ? nil : Time.now + (duration || ONE_WEEK_SUSPENSION)

      user.suspend!(
        reason: "Auto-moderation: #{check.abuse_category} (check ##{check.id})",
        until_time: until_time
      )

      ModerationAction.create_suspension(
        user: user,
        reason: "#{permanent ? 'Permanent' : "#{duration / 86400}-day"} suspension for #{check.abuse_category}",
        duration_seconds: permanent ? nil : duration,
        abuse_check: check
      )
    end

    # Force logout all user's characters
    def logout_all_characters(user, check)
      return nil unless user

      logged_out_count = 0

      user.characters.each do |char|
        char.character_instances.where(online: true).each do |ci|
          ci.update(
            online: false,
            session_start_at: nil,
            last_activity: Time.now
          )

          # Broadcast disconnect to room
          BroadcastService.to_room(
            ci.current_room_id,
            "#{char.full_name} has been disconnected by the system.",
            exclude: [ci.id]
          ) if ci.current_room_id

          logged_out_count += 1
        end
      end

      ModerationAction.create_logout(
        user: user,
        reason: "Force logout due to confirmed abuse (#{logged_out_count} character(s))",
        abuse_check: check
      )
    end

    # Notify all online staff about the moderation action
    # @param level [String] 'serious', 'warning', 'mute', 'suspension'
    def notify_staff(check, actions, level: 'serious')
      message = build_staff_notification(check, actions, level: level)

      # In-game notification
      StaffAlertService.broadcast_to_staff(message)

      # Discord webhook (if configured) - only for serious or suspensions
      send_discord_notification(check, message) if %w[serious suspension].include?(level)
    end

    # Notify staff of an error during moderation
    def notify_staff_error(check, error)
      message = "[AUTO-MOD ERROR] Failed to execute moderation for abuse check ##{check.id}: #{error.message}"
      StaffAlertService.broadcast_to_staff(message)
    end

    # Build notification message for staff
    def build_staff_notification(check, actions, level: 'serious')
      user = check.user
      char = check.character_instance&.character

      header = case level
               when 'warning' then '[AUTO-MOD WARNING] User warned'
               when 'mute' then '[AUTO-MOD MUTE] User temporarily muted'
               when 'suspension' then '[AUTO-MOD SUSPENSION] User suspended for 1 week'
               else '[AUTO-MODERATION] Abuse confirmed - permanent action'
               end

      lines = [
        header,
        "User: #{user&.username || 'Unknown'} (ID: #{user&.id})",
        "Character: #{char&.full_name || 'Unknown'}",
        "Category: #{check.abuse_category}",
        "Severity: #{check.severity}",
        "IP: #{check.ip_address}",
        "Message: #{truncate(check.message_content, 100)}",
        "Actions: #{actions.compact.map(&:action_type).join(', ')}"
      ]

      lines.join("\n")
    end

    # Send Discord webhook notification
    def send_discord_notification(check, message)
      webhook_url = GameSetting.get('staff_discord_webhook')
      return unless webhook_url && !webhook_url.to_s.strip.empty?

      embed = build_discord_embed(check)
      payload = { embeds: [embed] }

      Faraday.post(webhook_url) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.body = payload.to_json
        req.options.timeout = 5
      end
    rescue Faraday::Error => e
      warn "[AutoModeration] Discord webhook failed: #{e.message}"
    rescue StandardError => e
      warn "[AutoModeration] Discord notification error: #{e.message}"
    end

    # Build Discord embed for moderation alert
    def build_discord_embed(check)
      user = check.user
      char = check.character_instance&.character

      severity_colors = {
        'critical' => 0xff0000,  # Red
        'high' => 0xff6600,      # Orange
        'medium' => 0xffcc00,    # Yellow
        'low' => 0x00ff00        # Green
      }

      {
        title: 'Auto-Moderation Action Taken',
        description: "Confirmed abuse has been automatically moderated.",
        color: severity_colors[check.severity] || 0xe74c3c,
        fields: [
          { name: 'User', value: user&.username || 'Unknown', inline: true },
          { name: 'Character', value: char&.full_name || 'Unknown', inline: true },
          { name: 'Category', value: check.abuse_category, inline: true },
          { name: 'Severity', value: check.severity, inline: true },
          { name: 'IP', value: check.ip_address || 'Unknown', inline: true },
          { name: 'Message', value: truncate(check.message_content, 200) }
        ],
        footer: { text: "Check ##{check.id}" },
        timestamp: Time.now.utc.iso8601
      }
    end

    # Reverse IP ban
    def reverse_ip_ban(action)
      ban = IpBan.where(ip_pattern: action.ip_address, active: true).first
      ban&.deactivate!
    end

    # Reverse range ban
    def reverse_range_ban(action)
      ban = IpBan.where(ip_pattern: action.ip_range, active: true).first
      ban&.deactivate!
    end

    # Reverse user suspension
    def reverse_suspension(action)
      user = action.user
      user&.unsuspend!
    end

    # Reverse registration freeze
    def reverse_registration_freeze
      GameSetting.set(REGISTRATION_FREEZE_KEY, nil, type: 'string')
    end

    # NOTE: truncate method is inherited from StringHelper
  end
end
