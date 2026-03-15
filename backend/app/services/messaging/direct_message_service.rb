# frozen_string_literal: true

# DirectMessageService handles remote instant messaging (DMs) that work
# across the game world regardless of room location.
#
# Behavior varies by era:
# - Medieval/Gaslight: Routes through MessengerService (letter/telegram)
# - Modern+: Real-time delivery if online, stored for later if offline
#
# Usage:
#   DirectMessageService.send_message(sender_instance, recipient_character, "Hello!")
#   DirectMessageService.deliver_pending(character_instance)
module DirectMessageService
  extend ResultHandler

  class << self
    # Send a direct message to a character
    # @param sender_instance [CharacterInstance] the sender's character instance
    # @param recipient [Character] the recipient character
    # @param message [String] the message content
    # @return [Hash] result with success status
    def send_message(sender_instance, recipient, message, broadcast_id: nil)
      sender = sender_instance.character

      # Validate inputs
      return error("Could not find the recipient.") unless recipient
      sanitized_message = StringHelper.sanitize_user_html(message.to_s).to_s.strip
      plain_message = StringHelper.strip_html(sanitized_message).strip
      return error("What do you want to say?") if plain_message.empty?
      return error("You can't message yourself.") if recipient.id == sender.id

      # Note: MessengerService (for medieval/gaslight era delayed messaging) was removed
      # All eras now use direct DM delivery

      # Modern+ era: Check phone requirement
      if EraService.requires_phone_for_dm? && !sender_instance.has_phone?
        device_name = EraService.messaging_device_name
        return error("You need a #{device_name} to send messages.")
      end

      # Create the DM record
      dm = DirectMessage.create(
        sender_id: sender.id,
        recipient_id: recipient.id,
        content: sanitized_message
      )

      unless dm&.id
        return error("Failed to send message.")
      end

      # Check if recipient is online
      recipient_instance = recipient.primary_instance
      if recipient_instance&.online
        deliver_immediately(dm, recipient_instance, broadcast_id: broadcast_id)
        confirmation = dm.format_for_sender
      else
        # Store for later delivery and notify via Discord
        notify_offline_recipient(dm, recipient)
        confirmation = "#{dm.format_for_sender} (They are offline - message will be delivered when they log in.)"
      end

      success(
        confirmation,
        data: {
          message_id: dm.id,
          recipient_name: recipient.full_name,
          delivered: dm.delivered?,
          content: sanitized_message
        }
      )
    end

    # Deliver all pending messages to a character who just came online
    # Called from the login hook in CharacterInstance.after_save
    # @param character_instance [CharacterInstance] the character who just logged in
    # @return [Integer] number of messages delivered
    def deliver_pending(character_instance)
      return 0 unless character_instance&.online

      character = character_instance.character
      return 0 unless character

      pending = DirectMessage.pending_for(character)
      return 0 if pending.empty?

      count = 0
      pending.each do |dm|
        deliver_immediately(dm, character_instance)
        count += 1
      end

      # Send summary notification if multiple messages
      if count > 1
        BroadcastService.to_character(
          character_instance,
          "You have received #{count} messages while you were away.",
          type: :system
        )
      end

      count
    rescue StandardError => e
      warn "[DirectMessageService] Error delivering pending messages: #{e.message}"
      0
    end

    # Count pending messages for a character
    # @param character [Character] the character to check
    # @return [Integer] number of pending messages
    def pending_count(character)
      DirectMessage.pending_count_for(character)
    end

    private

    # Deliver a message immediately to an online character
    # @param dm [DirectMessage] the message to deliver
    # @param recipient_instance [CharacterInstance] the recipient's active instance
    def deliver_immediately(dm, recipient_instance, broadcast_id: nil)
      formatted = dm.format_for_recipient

      # Single lookup — used for portrait, display name, and activity logging
      sender_instance = if dm.sender_id
        CharacterInstance.where(character_id: dm.sender_id, online: true).first
      end

      knowledge = if dm.sender_id
        CharacterKnowledge.first(
          knower_character_id: recipient_instance.character_id,
          known_character_id: dm.sender_id
        )
      end

      portrait_url = (knowledge&.is_known && sender_instance) ?
        sender_instance.character&.profile_pic_url : nil
      display_name = (knowledge&.is_known && dm.sender) ?
        dm.sender.display_name_for(recipient_instance, knowledge: knowledge) : nil

      opts = { type: :dm, sender_instance: sender_instance }
      opts[:broadcast_id]        = broadcast_id  if broadcast_id
      opts[:sender_portrait_url] = portrait_url  if portrait_url
      opts[:sender_display_name] = display_name  if display_name

      BroadcastService.to_character(recipient_instance, formatted, **opts)

      # Log DM to character stories for both participants
      if sender_instance
        IcActivityService.record_targeted(
          sender: sender_instance, target: recipient_instance,
          content: dm.content, type: :dm
        )
      else
        IcActivityService.record_for(
          recipients: [recipient_instance], content: formatted,
          sender: nil, type: :dm
        )
      end

      dm.mark_delivered!

      # Track sender for reply command
      if dm.sender_id
        recipient_instance.this.update(
          last_msg_sender_character_id: dm.sender_id,
          last_msg_sender_at: Time.now
        )
      end
    end

    # Notify offline recipient via Discord
    # @param dm [DirectMessage] the message
    # @param recipient [Character] the recipient character
    def notify_offline_recipient(dm, recipient)
      NotificationService.notify_pm(
        recipient.primary_instance,
        dm.sender&.full_name || 'Someone',
        dm.content
      )

      # Email notification if user has emailmissed enabled
      email_missed_notification(recipient.user, dm.sender&.full_name || 'Someone', dm.content)
    rescue StandardError => e
      warn "[DirectMessageService] Discord notification failed: #{e.message}"
    end

    def email_missed_notification(user, sender_name, content)
      MissedEmailHelper.send(user, sender_name, content, service_name: 'DirectMessageService')
    end
  end
end
