# frozen_string_literal: true

# UserPermission manages user-to-user social permission settings for the unified permission system.
# Each user has one "generic" row (target_user_id = nil) with actual permission values,
# and can have specific rows for individual users that default to 'generic' (meaning "use my generic setting").
#
# Example flow:
#   - User has generic row with ooc_messaging: 'yes'
#   - User creates specific row for annoying_user with ooc_messaging: 'no'
#   - User creates specific row for friend_user with ooc_messaging: 'generic'
#   - Result: annoying_user is blocked, friend_user uses generic (allowed), everyone else uses generic (allowed)
#
class UserPermission < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps

  many_to_one :user
  many_to_one :target_user, class: :User, key: :target_user_id
  many_to_one :display_character, class: :Character, key: :display_character_id

  # For generic row (target_user_id = nil), these are the actual values
  # For specific rows, 'generic' means "use my generic setting"
  VISIBILITY_VALUES = %w[generic default never favorite always].freeze
  OOC_VALUES = %w[generic yes no ask].freeze
  IC_VALUES = %w[generic yes no].freeze
  LEAD_FOLLOW_VALUES = %w[generic yes no].freeze
  DRESS_STYLE_VALUES = %w[generic yes no].freeze
  CHANNEL_VALUES = %w[generic yes muted].freeze
  GROUP_VALUES = %w[generic favored neutral disfavored].freeze

  def validate
    super
    validates_presence :user_id
    validates_includes VISIBILITY_VALUES, :visibility if visibility
    validates_includes OOC_VALUES, :ooc_messaging if ooc_messaging
    validates_includes IC_VALUES, :ic_messaging if ic_messaging
    validates_includes LEAD_FOLLOW_VALUES, :lead_follow if lead_follow
    validates_includes DRESS_STYLE_VALUES, :dress_style if dress_style
    validates_includes CHANNEL_VALUES, :channel_muting if channel_muting
    validates_includes GROUP_VALUES, :group_preference if group_preference
  end

  def generic?
    target_user_id.nil?
  end

  # === Class Methods for Permission Checks ===

  # Get effective value for a permission field, handling 'generic' fallback
  # @param user [User] The user whose permission we're checking
  # @param target_user [User] The target user this permission applies to
  # @param field [Symbol] The permission field to check
  # @param default [String] Default value if no permission exists
  def self.effective_value(user, target_user, field, default:)
    return default unless user

    # Single query to fetch both specific and generic rows
    # Note: Sequel generates IN(NULL, id) which doesn't match NULL in SQL,
    # so we use an explicit OR condition for correct NULL handling.
    conditions = Sequel.or(target_user_id: nil)
    conditions = Sequel.|(conditions, { target_user_id: target_user.id }) if target_user
    rows = where(user_id: user.id).where(conditions).all

    specific = rows.find { |r| r.target_user_id == target_user&.id } if target_user
    generic_perm = rows.find { |r| r.target_user_id.nil? }

    if specific
      value = specific.send(field)
      # If 'generic', fall back to generic row
      if value == 'generic' || value.nil?
        return generic_perm&.send(field) || default
      end
      return value
    end

    # No specific permission, use generic
    generic_perm&.send(field) || default
  end

  # Get or create generic permission for a user (with sensible defaults)
  def self.generic_for(user)
    find_or_create(user_id: user.id, target_user_id: nil) do |p|
      # Set sensible defaults for generic row (not 'generic' since this IS the generic)
      p.visibility = 'default'
      p.ooc_messaging = 'yes'
      p.ic_messaging = 'yes'
      p.lead_follow = 'yes'
      p.dress_style = 'yes'
      p.channel_muting = 'yes'
      p.group_preference = 'neutral'
    end
  end

  # Get or create specific permission for a user pair (defaults to 'generic' for all fields)
  def self.specific_for(user, target_user, display_character: nil)
    find_or_create(user_id: user.id, target_user_id: target_user.id) do |p|
      p.display_character_id = display_character&.id
      # All fields default to 'generic' for specific rows (schema default)
    end
  end

  # Get permission row for user pair (does not create)
  def self.for_users(user, target_user)
    return nil unless user && target_user

    where(user_id: user.id, target_user_id: target_user.id).first
  end

  # Check if user1 can see user2 in where list
  def self.can_see_in_where?(viewer_user, target_user, target_locatability)
    visibility = effective_value(target_user, viewer_user, :visibility, default: 'default')

    case visibility
    when 'never' then false
    when 'always' then true
    when 'favorite' then %w[yes favorites].include?(target_locatability)
    else # 'default'
      target_locatability == 'yes'
    end
  end

  # Check if user1 can send OOC to user2
  def self.ooc_permission(sender_user, target_user)
    effective_value(target_user, sender_user, :ooc_messaging, default: 'yes')
  end

  # Check if user1 can send IC messages to user2
  def self.ic_allowed?(sender_user, target_user)
    effective_value(target_user, sender_user, :ic_messaging, default: 'yes') == 'yes'
  end

  # Check if user1 can lead/follow user2
  def self.lead_follow_allowed?(actor_user, target_user)
    effective_value(target_user, actor_user, :lead_follow, default: 'yes') == 'yes'
  end

  # Check if user1 can dress/tattoo/style user2
  def self.dress_style_allowed?(actor_user, target_user)
    effective_value(target_user, actor_user, :dress_style, default: 'yes') == 'yes'
  end

  # Check if user1 should see user2's channel messages
  def self.channel_visible?(viewer_user, sender_user)
    effective_value(viewer_user, sender_user, :channel_muting, default: 'yes') == 'yes'
  end

  # Get mutual content consents between two users
  def self.mutual_content_consents(user1, user2, codes: nil, default: 'no')
    return [] unless user1 && user2

    candidate_codes = if codes
                        Array(codes).map { |code| normalize_content_code(code) }.uniq
                      else
                        ContentRestriction.where(is_active: true).select_map(:code).map { |code| normalize_content_code(code) }
                      end

    candidate_codes.select do |code|
      content_consent_allowed?(user1, user2, code, default: default) &&
        content_consent_allowed?(user2, user1, code, default: default)
    end
  end

  # Get effective consent value for a code from user -> target_user
  # Specific row values override generic row values, with 'generic' falling back.
  # @return [String] 'yes', 'no', or default
  def self.effective_content_consent(user, target_user, code, default: 'no')
    return default unless user

    normalized_code = normalize_content_code(code)
    specific = target_user ? for_users(user, target_user) : nil
    generic_perm = where(user_id: user.id, target_user_id: nil).first

    specific_value = specific&.content_consent_for(normalized_code)
    if specific && specific_value != 'generic'
      return specific_value
    end

    generic_value = generic_perm&.content_consent_for(normalized_code)
    return generic_value if %w[yes no].include?(generic_value)

    default
  end

  # Check whether user consents to code for a specific target user.
  def self.content_consent_allowed?(user, target_user, code, default: 'no')
    effective_content_consent(user, target_user, code, default: default) == 'yes'
  end

  def self.normalize_content_code(code)
    code.to_s.strip.upcase
  end

  # === Content Consent Helpers ===

  def content_consent_for(code)
    normalized_code = self.class.normalize_content_code(code)
    consents = (content_consents || {})
    value = consents[normalized_code] || consents[code.to_s] || consents[code.to_s.downcase]
    return value if value

    generic? ? 'no' : 'generic'
  end

  def set_content_consent!(code, value)
    normalized_code = self.class.normalize_content_code(code)
    normalized_value = value.to_s.downcase
    normalized_value = 'yes' if %w[true on 1].include?(normalized_value)
    normalized_value = 'no' if %w[false off 0].include?(normalized_value)

    new_consents = JSON.parse((content_consents || {}).to_json)
    if normalized_value == 'generic'
      new_consents.delete(normalized_code)
    else
      new_consents[normalized_code] = normalized_value
    end

    self.content_consents = new_consents
    this.update(content_consents: Sequel.pg_jsonb_wrap(new_consents))
    refresh
  end

  # === List Methods ===

  # Get all specific permissions for a user (excluding generic)
  def self.all_specific_for(user)
    where(user_id: user.id)
      .exclude(target_user_id: nil)
      .order(:display_character_id)
  end
end
