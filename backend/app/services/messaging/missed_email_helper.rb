# frozen_string_literal: true

module MissedEmailHelper
  # Send an email notification for a missed message.
  # @param user [User] the recipient user
  # @param sender_name [String] display name of the sender
  # @param content [String] the message content
  # @param service_name [String] name for logging (e.g. "DirectMessageService")
  def self.send(user, sender_name, content, service_name:)
    return unless user&.email
    return unless EmailService.configured?

    settings = nil
    REDIS_POOL.with { |redis| settings = redis.get("settings:user:#{user.id}") }
    return unless settings

    parsed = JSON.parse(settings)
    return unless parsed['emailmissed'] == true || parsed['emailmissed'] == 'true'

    EmailService.send_email(
      to: user.email,
      subject: "Missed message from #{sender_name}",
      body: "You received a message while offline:\n\nFrom: #{sender_name}\n#{content}\n\nLog in to reply.",
      html: false
    )
  rescue StandardError => e
    warn "[#{service_name}] Email notification failed: #{e.message}"
  end
end
