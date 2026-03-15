# frozen_string_literal: true

require 'cgi'

# Sends staff alerts through multiple channels:
# - In-game broadcast to online staff
# - Discord webhook
# - Email (placeholder for Postmark or similar)
module StaffAlertService
  extend StringHelper

  DISCORD_COLOR = 0xe74c3c  # Red for alerts

  class << self
    # Send alert for trigger activation
    # @param trigger [Trigger] The trigger that fired
    # @param activation [TriggerActivation] The activation record
    # @param send_discord [Boolean] Whether to send Discord notification
    # @param send_email [Boolean] Whether to send email notification
    # @param email_recipients [String] Comma-separated email addresses
    def send_trigger_alert(trigger:, activation:, send_discord: false, send_email: false, email_recipients: nil)
      message = build_alert_message(trigger, activation)

      # In-game: Always broadcast to online staff
      broadcast_to_staff(message)

      # Discord: If enabled and webhook configured
      send_discord_alert(trigger, activation, message) if send_discord

      # Email: If enabled and recipients configured
      send_email_alert(trigger, activation, message, email_recipients) if send_email && email_recipients
    end

    # Direct staff broadcast (public for use by TriggerCodeExecutor)
    # @param message [String] Message to broadcast
    def broadcast_to_staff(message)
      # Find all online staff character instances
      staff_instances = CharacterInstance
        .where(online: true)
        .eager(:character)
        .all
        .select { |ci| staff_character?(ci) }

      staff_instances.each do |ci|
        BroadcastService.to_character(ci, {
          content: "[STAFF ALERT] #{message}",
          html: "<span class='text-danger fw-bold'>[STAFF ALERT]</span> #{message}"
        }, type: :staff_alert)
      end

      staff_instances.length
    end

    private

    # Check if a character instance belongs to staff
    def staff_character?(ci)
      character = ci.character
      return false unless character

      # Check if character is staff or user is admin
      character.staff? || character.user&.admin?
    end

    # Build alert message from trigger and activation
    def build_alert_message(trigger, activation)
      if trigger.alert_message_template && !trigger.alert_message_template.strip.empty?
        interpolate_template(trigger.alert_message_template, trigger, activation)
      else
        default_message(trigger, activation)
      end
    end

    # Interpolate template placeholders
    def interpolate_template(template, trigger, activation)
      result = template.dup
      result.gsub!('{{trigger_name}}', trigger.name.to_s)
      result.gsub!('{{trigger_type}}', trigger.trigger_type.to_s)
      result.gsub!('{{source}}', activation.source_character&.full_name || 'System')
      result.gsub!('{{source_type}}', activation.source_type.to_s)
      result.gsub!('{{content}}', truncate(activation.triggering_content || 'N/A', 200))
      result.gsub!('{{time}}', activation.activated_at&.strftime('%H:%M:%S') || 'Unknown')
      result.gsub!('{{date}}', activation.activated_at&.strftime('%Y-%m-%d') || 'Unknown')
      result.gsub!('{{confidence}}', activation.confidence_percentage || 'N/A')

      # Clue-specific placeholders
      if activation.clue
        result.gsub!('{{clue_name}}', activation.clue.name.to_s)
        result.gsub!('{{clue_recipient}}', activation.clue_recipient&.full_name || 'Unknown')
      end

      result
    end

    # Default alert message
    def default_message(trigger, activation)
      parts = ["Trigger '#{trigger.name}' (#{trigger.trigger_type})"]
      parts << "activated by #{activation.source_character&.full_name || 'system'}"

      if activation.llm_confidence
        parts << "(#{activation.confidence_percentage} confidence)"
      end

      parts.join(' ')
    end

    # Send Discord webhook alert
    def send_discord_alert(trigger, activation, message)
      webhook_url = GameSetting.get('staff_discord_webhook')
      return unless webhook_url && !webhook_url.strip.empty?

      embed = build_discord_embed(trigger, activation, message)
      payload = { embeds: [embed] }

      Faraday.post(webhook_url) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.body = payload.to_json
        req.options.timeout = 5
      end
    rescue Faraday::Error => e
      warn "[StaffAlertService] Discord webhook failed: #{e.message}"
    rescue StandardError => e
      warn "[StaffAlertService] Discord alert error: #{e.message}"
    end

    # Build Discord embed object
    def build_discord_embed(trigger, activation, message)
      embed = {
        title: "Trigger Alert: #{trigger.name}",
        description: message,
        color: DISCORD_COLOR,
        fields: [
          { name: 'Trigger Type', value: trigger.trigger_type, inline: true },
          { name: 'Source', value: activation.source_type, inline: true }
        ],
        footer: { text: "#{GameSetting.get('game_name') || 'Firefly'} Trigger System" },
        timestamp: Time.now.utc.iso8601
      }

      # Add source character if available
      if activation.source_character
        embed[:fields] << {
          name: 'Character',
          value: activation.source_character.full_name,
          inline: true
        }
      end

      # Add confidence for LLM matches
      if activation.llm_confidence
        embed[:fields] << {
          name: 'LLM Confidence',
          value: activation.confidence_percentage,
          inline: true
        }
      end

      # Add clue info for clue_share triggers
      if activation.clue
        embed[:fields] << {
          name: 'Clue',
          value: activation.clue.name,
          inline: true
        }
        if activation.clue_recipient
          embed[:fields] << {
            name: 'Recipient',
            value: activation.clue_recipient.full_name,
            inline: true
          }
        end
      end

      embed
    end

    # Send email alert via EmailService
    def send_email_alert(trigger, activation, message, recipients)
      emails = recipients.split(',').map(&:strip).reject(&:empty?)
      return if emails.empty?
      return unless EmailService.configured?

      subject = "[#{GameSetting.get('game_name') || 'Firefly'} Alert] Trigger: #{trigger.name}"
      body = build_email_body(trigger, activation, message)

      emails.each do |email|
        success = EmailService.send_email(
          to: email,
          subject: subject,
          body: body,
          html: true
        )

        unless success
          warn "[StaffAlertService] Email to #{email} failed"
        end
      end
    rescue StandardError => e
      warn "[StaffAlertService] Email failed: #{e.message}"
    end

    # Build HTML email body for staff alerts
    def build_email_body(trigger, activation, message)
      <<~HTML
        <html>
        <body style="font-family: Arial, sans-serif; padding: 20px;">
          <h2 style="color: #c0392b;">Staff Alert: #{CGI.escapeHTML(trigger.name.to_s)}</h2>
          <div style="background: #f8f9fa; padding: 15px; border-radius: 5px; margin: 15px 0;">
            #{CGI.escapeHTML(message)}
          </div>
          <hr style="border: none; border-top: 1px solid #ddd;">
          <p style="color: #666; font-size: 12px;">
            <strong>Trigger Type:</strong> #{CGI.escapeHTML(trigger.trigger_type.to_s)}<br>
            <strong>Source:</strong> #{CGI.escapeHTML(activation.source_type.to_s)}<br>
            <strong>Confidence:</strong> #{CGI.escapeHTML(activation.confidence_percentage.to_s)}<br>
            <strong>Time:</strong> #{Time.now.strftime('%Y-%m-%d %H:%M:%S UTC')}
          </p>
        </body>
        </html>
      HTML
    end

    # NOTE: truncate method is inherited from StringHelper
  end
end
