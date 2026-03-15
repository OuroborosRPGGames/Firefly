# frozen_string_literal: true

# DirectMessage represents a remote instant message that can be delivered
# across the game world, regardless of room location.
#
# In modern+ eras, these are delivered instantly if the recipient is online,
# or stored for delivery when they next log in.
#
# In medieval/gaslight eras, messages are routed through MessengerService
# instead of being stored as DirectMessages.
class DirectMessage < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true

  many_to_one :sender, class: :Character, key: :sender_id
  many_to_one :recipient, class: :Character, key: :recipient_id

  def validate
    super
    validates_presence [:sender_id, :recipient_id, :content]
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
  def format_for_recipient
    "#{sender&.full_name || 'Someone'} messages: \"#{content}\""
  end

  # Format for display to sender (confirmation)
  def format_for_sender
    "You message #{recipient&.full_name || 'someone'}: \"#{content}\""
  end

  class << self
    # Find all undelivered messages for a character
    # @param character [Character] the recipient character
    # @return [Array<DirectMessage>] pending messages
    def pending_for(character)
      where(recipient_id: character.id, delivered: false)
        .order(:created_at)
        .eager(:sender)
        .all
    end

    # Count undelivered messages for a character
    # @param character [Character] the recipient character
    # @return [Integer] count of pending messages
    def pending_count_for(character)
      where(recipient_id: character.id, delivered: false).count
    end

    # Get recent messages sent by a character
    # @param character [Character] the sender
    # @param limit [Integer] max messages to return
    # @return [Array<DirectMessage>]
    def recent_sent_by(character, limit: 20)
      where(sender_id: character.id)
        .order(Sequel.desc(:created_at))
        .limit(limit)
        .eager(:recipient)
        .all
    end

    # Get recent messages received by a character
    # @param character [Character] the recipient
    # @param limit [Integer] max messages to return
    # @return [Array<DirectMessage>]
    def recent_received_by(character, limit: 20)
      where(recipient_id: character.id)
        .order(Sequel.desc(:created_at))
        .limit(limit)
        .eager(:sender)
        .all
    end
  end
end
