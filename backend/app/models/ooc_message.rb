# frozen_string_literal: true

# OocMessage represents a private out-of-character message between users.
#
# Unlike DirectMessage which is character-to-character (IC), OocMessage is
# user-to-user for OOC communication. This supports the "ooc" command for
# private OOC messaging to individuals.
#
# Messages are delivered instantly if the recipient is online, or stored
# for delivery when they next log in.
class OocMessage < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :sender_user, class: :User, key: :sender_user_id
  many_to_one :recipient_user, class: :User, key: :recipient_user_id
  many_to_one :sender_character, class: :Character, key: :sender_character_id

  def validate
    super
    validates_presence [:sender_user_id, :recipient_user_id, :content]
    validates_min_length 1, :content
    validates_max_length 2000, :content
  end

  def before_save
    super
    self.content = content.strip if content
  end

  # Mark as delivered and set timestamp
  def mark_delivered!
    update(delivered: true, delivered_at: Time.now)
  end

  # Check if this message has been delivered
  def delivered?
    delivered == true
  end

  # Format for display to recipient
  # OOC messages always show full character name (not personalized)
  # and apply the sender's speech_color to their name
  # @param sender_char [Character, nil] optional sender character for display
  # @return [String] formatted message
  def format_for_recipient(sender_char: nil)
    char = sender_char || sender_character
    sender_name = char&.full_name || sender_user&.username || 'Someone'
    colored_name = apply_speech_color(sender_name, char&.speech_color)
    "[OOC from #{colored_name}]: #{content}"
  end

  # Format for display to sender (confirmation)
  # @param recipient_char [Character, nil] optional recipient character for display
  # @return [String] formatted message
  def format_for_sender(recipient_char: nil)
    recipient_name = recipient_char&.full_name || recipient_user&.username || 'someone'
    "[OOC to #{recipient_name}]: #{content}"
  end

  private

  # Apply speech color styling to a name
  # Delegates to MessageFormattingHelper canonical implementation
  # @param name [String] the name to color
  # @param color [String, nil] hex color (e.g., '#FF5733')
  # @return [String] the name, optionally wrapped in a color span
  def apply_speech_color(name, color)
    MessageFormattingHelper.apply_speech_color_to_text(name, color)
  end

  class << self
    # Find all undelivered messages for a user
    # @param user [User] the recipient user
    # @return [Array<OocMessage>] pending messages
    def pending_for(user)
      where(recipient_user_id: user.id, delivered: false)
        .order(:created_at)
        .eager(:sender_user, :sender_character)
        .all
    end

    # Count undelivered messages for a user
    # @param user [User] the recipient user
    # @return [Integer] count of pending messages
    def pending_count_for(user)
      where(recipient_user_id: user.id, delivered: false).count
    end

    # Get recent messages sent by a user
    # @param user [User] the sender
    # @param limit [Integer] max messages to return
    # @return [Array<OocMessage>]
    def recent_sent_by(user, limit: 20)
      where(sender_user_id: user.id)
        .order(Sequel.desc(:created_at))
        .limit(limit)
        .eager(:recipient_user, :sender_character)
        .all
    end

    # Get recent messages received by a user
    # @param user [User] the recipient
    # @param limit [Integer] max messages to return
    # @return [Array<OocMessage>]
    def recent_received_by(user, limit: 20)
      where(recipient_user_id: user.id)
        .order(Sequel.desc(:created_at))
        .limit(limit)
        .eager(:sender_user, :sender_character)
        .all
    end

    # Get recent OOC contacts for a user (users they've exchanged OOC messages with)
    # @param user [User] the user
    # @param limit [Integer] max contacts to return
    # @return [Array<User>] recent OOC contacts
    def recent_contacts_for(user, limit: 10)
      # Get user IDs from recent sent and received messages
      sent_to = where(sender_user_id: user.id)
                  .exclude(recipient_user_id: nil)
                  .order(Sequel.desc(:created_at))
                  .limit(limit * 2)
                  .select_map(:recipient_user_id)

      received_from = where(recipient_user_id: user.id)
                        .exclude(sender_user_id: nil)
                        .order(Sequel.desc(:created_at))
                        .limit(limit * 2)
                        .select_map(:sender_user_id)

      # Combine and dedupe, prioritizing most recent
      contact_ids = (sent_to + received_from).uniq.first(limit)
      return [] if contact_ids.empty?

      User.where(id: contact_ids).all.sort_by { |u| contact_ids.index(u.id) }
    end
  end
end
