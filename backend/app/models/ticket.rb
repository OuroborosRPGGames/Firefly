# frozen_string_literal: true

# Ticket tracks player-submitted issues, suggestions, and reports.
#
# Tickets are user-based (not character-based) and follow a single
# resolution model where staff resolves with a note.
#
# Examples:
#   ticket = Ticket.create(
#     user: current_user,
#     category: 'bug',
#     subject: 'Combat damage not calculating correctly',
#     content: 'When I attack with a sword, damage shows as 0...'
#   )
#   ticket.resolve!(by_user: staff, notes: "Fixed in commit abc123")
#
class Ticket < Sequel::Model
  plugin :timestamps

  many_to_one :user
  many_to_one :room
  many_to_one :resolved_by_user, class: :User, key: :resolved_by_user_id

  CATEGORIES = %w[bug typo behaviour request suggestion documentation other].freeze
  STATUSES = %w[open resolved closed].freeze

  # Validations
  def validate
    super
    errors.add(:category, 'must be valid') unless CATEGORIES.include?(category)
    errors.add(:status, 'must be valid') unless STATUSES.include?(status)
    errors.add(:subject, 'is required') if StringHelper.blank?(subject)
    errors.add(:content, 'is required') if StringHelper.blank?(content)
    errors.add(:subject, 'is too long (max 200 characters)') if subject && subject.length > 200
  end

  # Scopes
  dataset_module do
    # Note: named status_open to avoid conflict with Kernel#open
    def status_open
      where(status: 'open')
    end

    def resolved
      where(status: 'resolved')
    end

    def closed
      where(status: 'closed')
    end

    def by_category(cat)
      where(category: cat)
    end

    def recent(limit = 50)
      order(Sequel.desc(:created_at)).limit(limit)
    end
  end

  # Resolve the ticket with notes
  #
  # @param by_user [User] Staff member resolving
  # @param notes [String] Resolution notes
  # @return [self]
  def resolve!(by_user:, notes:)
    update(
      status: 'resolved',
      resolved_by_user_id: by_user.id,
      resolution_notes: notes,
      resolved_at: Time.now
    )
    self
  end

  # Close without resolution (e.g., duplicate, invalid)
  #
  # @param by_user [User] Staff member closing
  # @param notes [String] Reason for closing
  # @return [self]
  def close!(by_user:, notes: nil)
    update(
      status: 'closed',
      resolved_by_user_id: by_user.id,
      resolution_notes: notes,
      resolved_at: Time.now
    )
    self
  end

  # Reopen a resolved/closed ticket
  #
  # @return [self]
  def reopen!
    update(
      status: 'open',
      resolved_by_user_id: nil,
      resolution_notes: nil,
      resolved_at: nil
    )
    self
  end

  # Update ticket with AI investigation notes
  #
  # @param notes [String] AI-generated investigation report
  # @return [self]
  def investigate!(notes:)
    update(
      investigation_notes: notes,
      investigated_at: Time.now
    )
    self
  end

  # Check if ticket has been investigated
  def investigated?
    StringHelper.present?(investigation_notes)
  end

  # Check status
  def open?
    status == 'open'
  end

  def resolved?
    status == 'resolved'
  end

  def closed?
    status == 'closed'
  end

  # Human-readable category
  def category_display
    category&.capitalize
  end

  # Human-readable status
  def status_display
    status&.capitalize
  end

  # For admin display
  def to_admin_hash
    {
      id: id,
      user_id: user_id,
      username: system_generated ? 'System' : (user&.username || 'Unknown'),
      category: category,
      subject: subject,
      content: content,
      status: status,
      system_generated: system_generated,
      room_id: room_id,
      room_name: room&.name,
      game_context: game_context,
      resolved_by: resolved_by_user&.username,
      resolution_notes: resolution_notes,
      resolved_at: resolved_at&.iso8601,
      investigation_notes: investigation_notes,
      investigated_at: investigated_at&.iso8601,
      created_at: created_at&.iso8601,
      updated_at: updated_at&.iso8601
    }
  end
end
