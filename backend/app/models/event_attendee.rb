# frozen_string_literal: true

# EventAttendee tracks character attendance at events.
class EventAttendee < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :event
  many_to_one :character

  STATUSES = %w[invited yes no maybe pending].freeze
  ROLES = %w[attendee host staff vip].freeze
  LEGACY_STATUS_MAP = {
    'accepted' => 'yes',
    'declined' => 'no',
    'attended' => 'yes'
  }.freeze

  def validate
    super
    validates_presence [:event_id, :character_id]
    validates_unique [:event_id, :character_id]
    validates_includes STATUSES, :status if self.status
    validates_includes ROLES, :role if self.role
  end

  def before_validation
    super
    self.status = LEGACY_STATUS_MAP.fetch(status, status) if status
  end

  def before_save
    super
    self.status ||= 'invited'
    self.role ||= 'attendee'
    self.responded_at ||= Time.now
  end

  def attending?
    status == 'yes'
  end

  def host?
    role == 'host'
  end

  def staff?
    %w[host staff].include?(role)
  end

  def confirm!
    update(status: 'yes', responded_at: Time.now)
  end

  # Alias for confirm! - marks attendee as checked in
  def check_in!
    confirm!
  end

  def decline!
    update(status: 'no', responded_at: Time.now)
  end

  # Bounce handling
  def bounced?
    bounced == true
  end

  # Bounce a character from the event
  # @param bouncer_character [Character] The character who is bouncing
  def bounce!(bouncer_character)
    update(
      bounced: true,
      bounced_at: Time.now,
      bounced_by_id: bouncer_character.id
    )
  end

  # Unban a previously bounced character
  def unban!
    update(
      bounced: false,
      bounced_at: nil,
      bounced_by_id: nil
    )
  end

  # Check if character can enter the event (not bounced)
  def can_enter?
    !bounced?
  end

  class << self
    # Find attendee record for event and character
    # @param event [Event] The event
    # @param char [Character] The character
    # @return [EventAttendee, nil]
    def for_event_and_character(event, char)
      return nil unless event && char

      first(event_id: event.id, character_id: char.id)
    end

    # Check if a character is bounced from an event
    # @param event [Event] The event
    # @param character [Character] The character
    # @return [Boolean]
    def bounced_from?(event, character)
      attendee = for_event_and_character(event, character)
      attendee&.bounced? || false
    end
  end
end
