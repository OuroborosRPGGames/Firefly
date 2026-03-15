# frozen_string_literal: true

# GroupMember links a Character to a Group with their rank and status.
# For secret groups, members have a handle (alias) that's shown instead of their real name.
class GroupMember < Sequel::Model
  include StatusEnum

  plugin :validation_helpers
  plugin :timestamps

  many_to_one :group
  many_to_one :character

  RANKS = %w[member officer leader].freeze
  status_enum :status, %w[active inactive suspended removed]
  GREEK_LETTERS = %w[Alpha Beta Gamma Delta Epsilon Zeta Eta Theta Iota Kappa
                     Lambda Mu Nu Xi Omicron Pi Rho Sigma Tau Upsilon
                     Phi Chi Psi Omega].freeze

  def validate
    super
    validates_presence [:group_id, :character_id]
    validates_unique [:group_id, :character_id]
    validates_includes RANKS, :rank if rank
    validate_status_enum
    validates_max_length 50, :handle if handle

    # Handle must be unique within the group
    validate_handle_uniqueness if handle && group_id
  end

  def before_save
    super
    self.rank ||= 'member'
    self.status ||= 'active'
    self.joined_at ||= Time.now
  end

  def leader?
    rank == 'leader' || group&.leader_character_id == character_id
  end

  def officer?
    %w[officer leader].include?(rank) || leader?
  end

  def can_invite?
    officer?
  end

  def can_kick?
    officer?
  end

  def promote!(new_rank)
    update(rank: new_rank)
  end

  def suspend!
    update(status: 'suspended')
  end

  def reinstate!
    update(status: 'active')
  end

  # Display name for this member
  # In secret groups, shows handle; in public groups, shows real name
  def display_name_for(_viewer_character = nil)
    if group&.secret?
      handle || default_greek_handle
    else
      character&.full_name || '[Unknown]'
    end
  end

  # Generate a default Greek letter handle based on join order
  def default_greek_handle
    return 'Member' unless group_id

    # Get all members ordered by joined_at, find this member's position
    members = GroupMember.where(group_id: group_id)
                         .order(:joined_at, :id)
                         .select_map(:id)
    position = members.index(id) || 0
    GREEK_LETTERS[position % GREEK_LETTERS.length]
  end

  private

  def validate_handle_uniqueness
    existing = GroupMember.where(group_id: group_id, handle: handle)
                          .exclude(id: id)
                          .first
    errors.add(:handle, 'is already taken in this group') if existing
  end
end
