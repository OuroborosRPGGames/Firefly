# frozen_string_literal: true

# Central notification dispatch service
# Handles routing notifications to appropriate delivery services (Discord, etc.)
module NotificationService
  # Notify a character that they received a memo
  # @param recipient_instance [CharacterInstance, nil] The recipient's active instance (may be nil if offline)
  # @param memo [Memo] The memo that was received
  def self.notify_memo(recipient_instance, memo)
    return unless recipient_instance && memo

    character = recipient_instance.character
    return unless character

    user = character.user
    return unless user

    return unless user.should_notify_discord?(recipient_instance, :memo)

    sender = Character[memo.sender_id]
    sender_name = sender&.full_name || 'Unknown'
    title = "New memo from #{sender_name}"
    body = "<strong>Subject:</strong> #{memo.subject}<br><br>#{memo.content}"

    deliver(user, title, body, :memo)
  end

  # Notify a character that they received a private message (when offline)
  # @param recipient_instance [CharacterInstance] The instance that should receive notification
  # @param sender_name [String] Name of the sender
  # @param message [String] The message content
  def self.notify_pm(recipient_instance, sender_name, message)
    return unless recipient_instance

    character = recipient_instance.character
    return unless character

    user = character.user
    return unless user

    return unless user.should_notify_discord?(recipient_instance, :pm)

    title = "Private message from #{sender_name}"
    deliver(user, title, message, :pm)
  end

  # Notify a character that they were mentioned in an emote (when offline)
  # @param recipient_instance [CharacterInstance] The instance that was mentioned
  # @param emote_text [String] The full emote text
  # @param emoting_character [Character] The character who emoted
  def self.notify_mention(recipient_instance, emote_text, emoting_character)
    return unless recipient_instance && emoting_character

    character = recipient_instance.character
    return unless character

    user = character.user
    return unless user

    return unless user.should_notify_discord?(recipient_instance, :mention)

    title = "#{emoting_character.full_name} mentioned you"
    deliver(user, title, emote_text, :mention)
  end

  # Send a test notification to verify configuration
  # @param user [User] The user to send test to
  # @return [Boolean] true if successful
  def self.send_test(user)
    return false unless user&.discord_configured?

    title = "Test Notification"
    body = "Your Discord notifications are working! You'll receive notifications for memos, messages, and RP mentions when you're offline."

    deliver(user, title, body, :test)
  end

  private

  # Deliver notification through configured channels
  # @param user [User] User to notify
  # @param title [String] Notification title
  # @param body [String] Notification body
  # @param event_type [Symbol] Type of event
  # @return [Boolean] true if any delivery succeeded
  def self.deliver(user, title, body, event_type)
    success = false

    # Try webhook delivery
    if user.discord_webhook_configured?
      success = DiscordWebhookService.send(
        user.discord_webhook_url,
        title: title,
        body: body,
        event_type: event_type
      )
    end

    # Phase 2: Add bot DM delivery here when implemented
    # if user.discord_dm_configured?
    #   success ||= DiscordBotService.send_dm(user.discord_username, title, body)
    # end

    success
  end
end
