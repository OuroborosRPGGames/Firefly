# frozen_string_literal: true

# OocRequest handles the "ask" flow for OOC messaging permissions.
# When a user has ooc_messaging set to 'ask', senders must first submit
# an OOC request explaining what they want to discuss. The target can
# accept or decline; declining creates a 1-hour cooldown.
#
# Flow:
#   1. Sender tries to PM target who has ooc_messaging: 'ask'
#   2. PM fails, suggesting oocrequest command
#   3. Sender runs: oocrequest Bob "I'd like to discuss the plot"
#   4. Target gets notification, runs: oocaccept Bob (or oocdecline Bob)
#   5. If accepted, sender can now PM target
#   6. If declined, sender cannot request again for 1 hour
#
class OocRequest < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :sender_user, class: :User, key: :sender_user_id
  many_to_one :target_user, class: :User, key: :target_user_id
  many_to_one :sender_character, class: :Character, key: :sender_character_id
  many_to_one :target_character, class: :Character, key: :target_character_id

  status_enum :status, %w[pending accepted declined]

  def validate
    super
    validates_presence [:sender_user_id, :target_user_id, :message]
    validate_status_enum
    validates_max_length 500, :message
  end

  def accept!
    update(status: 'accepted', responded_at: Time.now)
  end

  def decline!
    update(
      status: 'declined',
      responded_at: Time.now,
      cooldown_until: Time.now + (GameConfig::Moderation::OOC_REQUEST_COOLDOWN_HOURS * 3600)
    )
  end

  # Check if sender is in cooldown with target
  def self.in_cooldown?(sender_user, target_user)
    recent = where(sender_user_id: sender_user.id, target_user_id: target_user.id)
              .where(status: 'declined')
              .where { cooldown_until > Time.now }
              .first
    !!recent
  end

  # Get pending requests for a user
  def self.pending_for(user)
    where(target_user_id: user.id, status: 'pending')
      .order(Sequel.desc(:created_at))
  end

  # Check if sender has an accepted request with target (for permission check)
  def self.has_accepted_request?(sender_user, target_user)
    where(
      sender_user_id: sender_user.id,
      target_user_id: target_user.id,
      status: 'accepted'
    ).count.positive?
  end

  # Get cooldown remaining time for display
  def cooldown_remaining
    return nil unless cooldown_until && cooldown_until > Time.now

    (cooldown_until - Time.now).to_i
  end
end
