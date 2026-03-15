# frozen_string_literal: true

# OocMessageService handles private OOC (out-of-character) messaging between users.
#
# Unlike DirectMessageService which handles IC (in-character) messages between
# characters, this service handles OOC messages at the user level.
#
# Usage:
#   OocMessageService.send_message(sender_instance, [recipient_user], "Hello!")
#   OocMessageService.deliver_pending(user)
module OocMessageService
  extend ResultHandler

  class << self
    # Send OOC messages to one or more users
    # @param sender_instance [CharacterInstance] the sender's character instance
    # @param recipient_users [Array<User>] the recipient users
    # @param message [String] the message content
    # @return [Hash] result with success status
    def send_message(sender_instance, recipient_users, message, broadcast_id: nil)
      sender_char = sender_instance.character
      sender_user = sender_char.user

      # Validate inputs
      return error("No recipients specified.") if recipient_users.nil? || recipient_users.empty?
      sanitized_message = StringHelper.sanitize_user_html(message.to_s).to_s.strip
      plain_message = StringHelper.strip_html(sanitized_message).strip
      return error("What do you want to say?") if plain_message.empty?

      # Filter out invalid recipients
      recipient_users = Array(recipient_users).compact.uniq

      # Don't allow messaging yourself
      recipient_users = recipient_users.reject { |u| u.id == sender_user.id }
      return error("You can't OOC message yourself.") if recipient_users.empty?

      # Check permissions for each recipient
      blocked_names = []
      ask_names = []
      allowed_users = []

      recipient_users.each do |recipient_user|
        # Check Relationship blocks first
        recipient_char = Character.where(user_id: recipient_user.id).first
        if recipient_char && Relationship.blocked_for_between?(sender_char, recipient_char, 'ooc')
          blocked_names << display_name_for_user(recipient_user)
          next
        end

        permission = UserPermission.ooc_permission(sender_user, recipient_user)

        case permission
        when 'no'
          blocked_names << display_name_for_user(recipient_user)
        when 'ask'
          # Check if they have an accepted OOC request
          if OocRequest.has_accepted_request?(sender_user, recipient_user)
            allowed_users << recipient_user
          else
            ask_names << display_name_for_user(recipient_user)
          end
        else # 'yes' or default
          allowed_users << recipient_user
        end
      end

      # Return error if all recipients blocked/require permission
      if allowed_users.empty?
        if blocked_names.any?
          return error("#{blocked_names.join(', ')} #{blocked_names.length == 1 ? 'has' : 'have'} blocked OOC messages from you.")
        elsif ask_names.any?
          names = ask_names.join(', ')
          return error("#{names} #{ask_names.length == 1 ? 'requires' : 'require'} an OOC request first.\nUse: oocrequest <name> <message>")
        end
      end

      # Create and send messages to allowed recipients
      sent_count = 0
      recipient_names = []

      allowed_users.each do |recipient_user|
        msg = OocMessage.create(
          sender_user_id: sender_user.id,
          recipient_user_id: recipient_user.id,
          sender_character_id: sender_char.id,
          content: sanitized_message
        )

        next unless msg&.id

        sent_count += 1
        recipient_names << display_name_for_user(recipient_user)

        # Deliver immediately if online
        recipient_instance = find_online_instance(recipient_user)
        if recipient_instance
          deliver_immediately(msg, recipient_instance, sender_char, broadcast_id: broadcast_id)
        else
          notify_offline_recipient(msg, recipient_user, sender_char)
        end
      end

      return error("Failed to send message.") if sent_count == 0

      # Build confirmation message
      recipient_list = recipient_names.join(', ')
      confirmation = "[OOC to #{recipient_list}]: #{sanitized_message}"

      # Add warnings for partial delivery
      warnings = []
      warnings << "#{blocked_names.join(', ')} blocked you" if blocked_names.any?
      warnings << "#{ask_names.join(', ')} require OOC request first" if ask_names.any?

      if warnings.any?
        confirmation += "\n(Note: #{warnings.join('; ')})"
      end

      success(
        confirmation,
        data: {
          sent_count: sent_count,
          recipient_user_ids: allowed_users.map(&:id),
          recipient_names: recipient_names,
          blocked_names: blocked_names,
          ask_names: ask_names,
          content: sanitized_message
        }
      )
    end

    # Deliver all pending OOC messages to a user who just came online
    # @param user [User] the user who just logged in
    # @return [Integer] number of messages delivered
    def deliver_pending(user)
      return 0 unless user

      pending = OocMessage.pending_for(user)
      return 0 if pending.empty?

      # Find their online character instance
      instance = find_online_instance(user)
      return 0 unless instance

      count = 0
      pending.each do |msg|
        deliver_immediately(msg, instance, msg.sender_character)
        count += 1
      end

      # Send summary notification if multiple messages
      if count > 1
        BroadcastService.to_character(
          instance,
          "You have received #{count} OOC messages while you were away.",
          type: :system
        )
      end

      count
    rescue StandardError => e
      warn "[OocMessageService] Error delivering pending messages: #{e.message}"
      0
    end

    # Count pending OOC messages for a user
    # @param user [User] the user to check
    # @return [Integer] number of pending messages
    def pending_count(user)
      OocMessage.pending_count_for(user)
    end

    private

    # Deliver a message immediately to an online user
    # @param msg [OocMessage] the message to deliver
    # @param recipient_instance [CharacterInstance] the recipient's active instance
    # @param sender_char [Character] the sender's character for display
    def deliver_immediately(msg, recipient_instance, sender_char, broadcast_id: nil)
      formatted = msg.format_for_recipient(sender_char: sender_char)

      opts = { type: :ooc }
      opts[:broadcast_id] = broadcast_id if broadcast_id

      BroadcastService.to_character(
        recipient_instance,
        formatted,
        **opts
      )

      msg.mark_delivered!

      # Track sender for reply command
      if sender_char
        recipient_instance.this.update(
          last_ooc_sender_character_id: sender_char.id,
          last_ooc_sender_at: Time.now
        )
      end
    end

    # Notify offline recipient via Discord
    # @param msg [OocMessage] the message
    # @param recipient_user [User] the recipient user
    # @param sender_char [Character] the sender's character
    def notify_offline_recipient(msg, recipient_user, sender_char)
      # Find any character for the user (for notification)
      char = Character.where(user_id: recipient_user.id).first
      return unless char

      instance = char.character_instances_dataset.first
      return unless instance

      sender_name = sender_char&.full_name || 'Someone'
      NotificationService.notify_pm(instance, sender_name, "[OOC] #{msg.content}")

      # Email notification if user has emailmissed enabled
      email_missed_notification(recipient_user, sender_name, "[OOC] #{msg.content}")
    rescue StandardError => e
      warn "[OocMessageService] Discord notification failed: #{e.message}"
    end

    def email_missed_notification(user, sender_name, content)
      MissedEmailHelper.send(user, sender_name, content, service_name: 'OocMessageService')
    end

    # Find an online character instance for a user
    # @param user [User] the user
    # @return [CharacterInstance, nil]
    def find_online_instance(user)
      # Find an online instance for this user
      CharacterInstance
        .join(:characters, id: :character_id)
        .where(Sequel[:characters][:user_id] => user.id)
        .where(Sequel[:character_instances][:online] => true)
        .select_all(:character_instances)
        .first
    end

    # Get display name for a user (prefer their online character's name)
    # @param user [User] the user
    # @return [String]
    def display_name_for_user(user)
      # Try to get their online character's name
      instance = find_online_instance(user)
      return instance.character.full_name if instance&.character

      # Fall back to any character they own
      char = Character.where(user_id: user.id).first
      char&.full_name || user.username || "User##{user.id}"
    end
  end
end
