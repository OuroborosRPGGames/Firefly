# frozen_string_literal: true

require 'bcrypt'

class User < Sequel::Model
  plugin :validation_helpers
  plugin :timestamps
  
  one_to_many :characters
  one_to_many :friends
  one_to_many :blocks
  one_to_many :content_consents
  one_to_many :events_created, class: :Event, key: :creator_user_id
  
  attr_accessor :password, :password_confirmation

  DISCORD_HANDLE_REGEX = /\A[a-z0-9](?:[a-z0-9_.]{0,30}[a-z0-9])?\z/
  DISCORD_HANDLE_ERROR = 'Invalid Discord handle. Use @username (no #1234).'
  
  def validate
    super
    validates_presence [:username, :email]
    validates_unique :username
    validates_unique :email
    validates_format /\A[\w+\-.]+@[a-z\d\-]+(\.[a-z\d\-]+)*\.[a-z]+\z/i, :email
    validates_min_length 3, :username
    validates_max_length 50, :username
    validates_max_length 255, :email
  end
  
  def before_save
    super
    self.username = titlecase_username(self.username.strip) if self.username
    self.email = self.email.strip.downcase if self.email
  end

  def active_characters
    characters_dataset.where(active: true)
  end

  def player_characters
    characters_dataset.where(is_npc: false, active: true)
  end

  def staff_characters
    characters_dataset.where(is_staff_character: true, active: true)
  end

  # ========================================
  # Admin & Permission Methods
  # ========================================

  # Check if this is the first user being created (for auto-admin)
  def before_create
    super
    # First registered user becomes admin automatically
    self.is_admin = true if User.count == 0
  end

  # Check if user is an admin
  # @return [Boolean]
  def admin?
    is_admin == true
  end

  # Check if user has a specific permission
  # Admins have all permissions implicitly
  # @param permission_name [String, Symbol]
  # @return [Boolean]
  def has_permission?(permission_name)
    return true if admin?

    perms = permissions
    return false if perms.nil?

    perms[permission_name.to_s] == true
  end

  # Grant a permission to this user
  # @param permission_name [String, Symbol]
  # @return [Boolean] success
  def grant_permission!(permission_name)
    return false unless Permission.valid?(permission_name)

    # Convert to plain Hash to avoid Sequel JSONB wrapper issues
    perms = (permissions || {}).to_h
    perms[permission_name.to_s] = true
    # Use direct SQL update to ensure JSONB is properly stored
    self.this.update(permissions: Sequel.pg_jsonb_wrap(perms))
    refresh
    true
  end

  # Revoke a permission from this user
  # @param permission_name [String, Symbol]
  # @return [Boolean] success
  def revoke_permission!(permission_name)
    # Convert to plain Hash to avoid Sequel JSONB wrapper issues
    perms = (permissions || {}).to_h
    perms.delete(permission_name.to_s)
    # Use direct SQL update to ensure JSONB is properly stored
    self.this.update(permissions: Sequel.pg_jsonb_wrap(perms))
    refresh
    true
  end

  # Get list of granted permissions
  # @return [Array<String>]
  def granted_permissions
    return Permission.all if admin?

    perms = permissions
    return [] if perms.nil?

    perms.select { |_k, v| v == true }.keys
  end

  # Convenience permission checks
  def can_access_admin_console?
    has_permission?('can_access_admin_console')
  end

  def can_create_staff_characters?
    has_permission?('can_create_staff_characters')
  end

  def can_see_all_rp?
    has_permission?('can_see_all_rp')
  end

  def can_go_invisible?
    has_permission?('can_go_invisible')
  end

  def can_manage_users?
    has_permission?('can_manage_users')
  end

  def can_manage_permissions?
    has_permission?('can_manage_permissions')
  end

  def can_build?
    has_permission?('can_build')
  end

  def can_manage_npcs?
    has_permission?('can_manage_npcs')
  end

  def can_moderate?
    has_permission?('can_moderate')
  end

  # Check if user has any staff-related permissions
  def staff?
    admin? || can_create_staff_characters? || can_see_all_rp? || can_go_invisible?
  end

  # ========================================
  # Suspension Methods
  # ========================================

  # Check if this user is currently suspended
  # Accounts for temporary suspensions that have expired
  # @return [Boolean]
  def suspended?
    return false unless suspended_at

    # If suspended_until is nil, it's a permanent suspension
    return true if suspended_until.nil?

    # Check if temporary suspension is still active
    suspended_until > Time.now
  end

  # Suspend this user
  # @param reason [String, nil] Reason for suspension
  # @param until_time [Time, nil] When suspension ends (nil = permanent)
  # @param by_user [User, nil] Staff member who suspended
  # @return [self]
  def suspend!(reason: nil, until_time: nil, by_user: nil)
    # Use this.update to bypass mass assignment restrictions
    self.this.update(
      suspended_at: Time.now,
      suspended_until: until_time,
      suspension_reason: reason,
      suspended_by_user_id: by_user&.id
    )
    refresh
    self
  end

  # Remove suspension from this user
  # @return [self]
  def unsuspend!
    # Use this.update to bypass mass assignment restrictions
    self.this.update(
      suspended_at: nil,
      suspended_until: nil,
      suspension_reason: nil,
      suspended_by_user_id: nil
    )
    refresh
    self
  end

  # Check if this is a permanent suspension
  # @return [Boolean]
  def suspension_permanent?
    suspended? && suspended_until.nil?
  end

  # Get remaining suspension time in seconds
  # @return [Integer, nil] Seconds remaining, or nil if permanent/not suspended
  def suspension_remaining
    return nil unless suspended? && suspended_until

    remaining = suspended_until - Time.now
    remaining > 0 ? remaining.to_i : 0
  end

  # Get the user who suspended this account
  # @return [User, nil]
  def suspended_by
    return nil unless suspended_by_user_id

    User[suspended_by_user_id]
  end

  # Format suspension status for display
  # @return [Hash, nil]
  def suspension_info
    return nil unless suspended?

    {
      suspended_at: suspended_at,
      suspended_until: suspended_until,
      reason: suspension_reason,
      permanent: suspension_permanent?,
      remaining_seconds: suspension_remaining,
      suspended_by: suspended_by&.username
    }
  end

  # Auto-lift expired suspensions
  # Called on login attempts to clear temporary bans that have expired
  # @return [Boolean] true if suspension was lifted
  def check_suspension_expired!
    return false unless suspended_at
    return false if suspended_until.nil?  # Permanent suspension, don't auto-lift
    return false if suspended_until > Time.now  # Still active

    unsuspend!
    true
  end

  # ========================================
  # Muting Methods (Temporary Communication Block)
  # ========================================

  # Check if user is currently muted
  # Muting prevents sending messages but allows login/gameplay
  # @return [Boolean]
  def muted?
    return false unless muted_until

    muted_until > Time.now
  end

  # Get remaining mute time in seconds
  # @return [Integer] Seconds remaining, or 0 if not muted
  def mute_remaining_seconds
    return 0 unless muted?

    (muted_until - Time.now).to_i
  end

  # Mute this user for a specified duration
  # @param duration_seconds [Integer] How long to mute (nil = indefinite)
  # @return [self]
  def mute!(duration_seconds)
    return self if duration_seconds.nil? || duration_seconds <= 0

    self.this.update(muted_until: Time.now + duration_seconds)
    refresh
    self
  end

  # Remove mute from this user
  # @return [self]
  def unmute!
    self.this.update(muted_until: nil)
    refresh
    self
  end

  # Check and clear expired mute
  # @return [Boolean] true if mute was cleared
  def check_mute_expired!
    return false unless muted_until
    return false if muted_until > Time.now

    unmute!
    true
  end

  # Format mute status for display
  # @return [Hash, nil]
  def mute_info
    return nil unless muted?

    remaining = mute_remaining_seconds
    {
      muted_until: muted_until,
      remaining_seconds: remaining,
      remaining_display: format_duration(remaining)
    }
  end

  # ========================================
  # Email Verification Methods
  # ========================================

  # Check if user's email is verified
  # @return [Boolean]
  def email_verified?
    !confirmed_at.nil?
  end

  # Check if email verification is required for this user
  # Returns true if verification is enabled AND user is not yet verified
  # @return [Boolean]
  def verification_required?
    GameSetting.boolean('email_require_verification') && !email_verified?
  end

  # Generate a new confirmation token
  # Token expires after 24 hours
  # @return [String] The generated token
  def generate_confirmation_token!
    token = SecureRandom.urlsafe_base64(32)
    update(
      confirmation_token: token,
      confirmation_token_created_at: Time.now
    )
    token
  end

  # Check if the current confirmation token is still valid (not expired)
  # Tokens expire after 24 hours
  # @return [Boolean]
  def confirmation_token_valid?
    return false if confirmation_token.nil?
    return false if confirmation_token_created_at.nil?

    Time.now - confirmation_token_created_at < 24 * 60 * 60 # 24 hours
  end

  # Confirm email address with provided token
  # @param token [String] The confirmation token from email
  # @return [Symbol] :success, :invalid, or :expired
  def confirm_email!(token)
    return :invalid if confirmation_token.nil? || confirmation_token != token
    return :expired unless confirmation_token_valid?

    update(
      confirmed_at: Time.now,
      confirmation_token: nil,
      confirmation_token_created_at: nil
    )
    :success
  end

  # ========================================
  # Password Reset Methods
  # ========================================

  # Generate a new password reset token
  # Token expires after 1 hour (shorter than email verification for security)
  # @return [String] The generated token
  def generate_password_reset_token!
    token = SecureRandom.urlsafe_base64(32)
    self.this.update(
      password_reset_token: token,
      password_reset_token_created_at: Time.now
    )
    refresh
    token
  end

  # Check if the current password reset token is still valid (not expired)
  # Tokens expire after 1 hour for security
  # @return [Boolean]
  def password_reset_token_valid?
    return false if password_reset_token.nil?
    return false if password_reset_token_created_at.nil?

    Time.now - password_reset_token_created_at < 60 * 60 # 1 hour
  end

  # Reset password with provided token
  # @param token [String] The password reset token from email
  # @param new_password [String] The new password to set
  # @return [Symbol] :success, :invalid, or :expired
  def reset_password_with_token!(token, new_password)
    return :invalid if password_reset_token.nil? || password_reset_token != token
    return :expired unless password_reset_token_valid?

    set_password(new_password)
    self.this.update(
      password_digest: self.password_digest,
      password_hash: self.password_hash,
      salt: self.salt,
      password_reset_token: nil,
      password_reset_token_created_at: nil
    )
    refresh
    :success
  end

  # ========================================
  # Connection History Methods
  # ========================================

  # Get all IP addresses this user has connected from
  # @return [Array<String>]
  def known_ips
    ConnectionLog.unique_ips_for_user(id)
  end

  # Get recent connection history for this user
  # @param limit [Integer] Number of logs to return
  # @return [Array<ConnectionLog>]
  def connection_history(limit: 50)
    ConnectionLog.recent_for_user(id, limit: limit)
  end

  # Get count of recent failed login attempts
  # @return [Integer]
  def recent_failed_logins
    ConnectionLog.where(user_id: id, outcome: 'invalid_credentials')
                 .where { created_at > Time.now - GameConfig::Timeouts::RATE_LIMIT_WINDOW_SECONDS }
                 .count
  end

  # ========================================
  # Playtime Tracking
  # ========================================

  # Default threshold for abuse check exemption (100 hours in seconds)
  ABUSE_CHECK_EXEMPTION_THRESHOLD = 360_000

  # Get total playtime in hours
  # @return [Float]
  def total_playtime_hours
    (total_playtime_seconds || 0) / 3600.0
  end

  # Check if user is exempt from abuse checks based on playtime
  # Users with 100+ hours of playtime are trusted and exempt
  # @return [Boolean]
  def exempt_from_abuse_checks?
    (total_playtime_seconds || 0) >= ABUSE_CHECK_EXEMPTION_THRESHOLD
  end

  # Increment playtime by given seconds
  # Called when a character logs out to record session duration
  # @param seconds [Integer] Seconds to add
  # @return [self]
  def increment_playtime!(seconds)
    return self if seconds.nil? || seconds <= 0

    new_total = (total_playtime_seconds || 0) + seconds.to_i
    update(total_playtime_seconds: new_total)
    self
  end

  # Format playtime for display
  # @return [String] e.g., "42h 30m"
  def playtime_display
    total = total_playtime_seconds || 0
    hours = total / 3600
    minutes = (total % 3600) / 60
    "#{hours}h #{minutes}m"
  end

  # ========================================
  # Gradient Preferences
  # ========================================

  # Get gradient preferences JSONB
  # Structure: { recent_gradients: [id1, id2, ...] } (max 10)
  def gradient_preferences
    self[:gradient_preferences] || {}
  end

  def gradient_preferences=(val)
    self[:gradient_preferences] = val.is_a?(Hash) ? Sequel.pg_jsonb_wrap(val) : val
  end

  # Get recently used gradient IDs (max 10)
  def recent_gradient_ids
    prefs = gradient_preferences
    (prefs['recent_gradients'] || []).first(10)
  end

  # Add a gradient to recent list (moves to front if exists)
  def add_recent_gradient!(gradient_id)
    prefs = (gradient_preferences || {}).to_h
    recent = prefs['recent_gradients'] || []

    # Remove if already present, add to front, limit to 10
    recent.delete(gradient_id)
    recent.unshift(gradient_id)
    prefs['recent_gradients'] = recent.first(10)

    self.this.update(gradient_preferences: Sequel.pg_jsonb_wrap(prefs))
    refresh
  end

  # ========================================
  # Media Preferences
  # ========================================

  def media_preferences
    self[:media_preferences] || {}
  end

  def media_preferences=(val)
    self[:media_preferences] = val.is_a?(Hash) ? Sequel.pg_jsonb_wrap(val) : val
  end

  def media_autoplay?
    media_preferences.fetch('autoplay', true)
  end

  def media_start_muted?
    media_preferences.fetch('start_muted', false)
  end

  def update_media_preferences!(updates)
    prefs = (media_preferences || {}).to_h
    prefs.merge!(updates.transform_keys(&:to_s))
    self.this.update(media_preferences: Sequel.pg_jsonb_wrap(prefs))
    refresh
  end

  # ========================================
  # Narrator Voice Configuration (TTS)
  # ========================================

  # Get narrator voice settings hash
  # Used for TTS narration of room descriptions, actions, system messages
  # @return [Hash] voice_type, voice_pitch, voice_speed
  def narrator_settings
    {
      voice_type: narrator_voice_type || 'Kore',
      voice_pitch: narrator_voice_pitch || 0.0,
      voice_speed: narrator_voice_speed || 1.0
    }
  end

  # Set narrator voice configuration
  # @param type [String] Chirp 3 HD voice name (e.g., 'Kore', 'Charon')
  # @param pitch [Float] Pitch adjustment (-20.0 to +20.0)
  # @param speed [Float] Speaking rate (0.25 to 4.0)
  def set_narrator_voice!(type:, pitch: 0.0, speed: 1.0)
    update(
      narrator_voice_type: type,
      narrator_voice_pitch: pitch.to_f.clamp(-20.0, 20.0),
      narrator_voice_speed: speed.to_f.clamp(0.25, 4.0)
    )
  end

  # Check if user has a custom narrator voice configured
  def has_narrator_voice?
    narrator_voice_type && !narrator_voice_type.to_s.empty?
  end
  alias narrator_voice? has_narrator_voice?

  # ========================================
  # Accessibility Settings
  # ========================================

  # Check if accessibility mode is enabled
  # When enabled, output is optimized for screen readers
  # @return [Boolean]
  def accessibility_mode?
    accessibility_mode == true
  end

  # Check if screen reader optimization is enabled
  # Implies accessibility mode if either is on
  # @return [Boolean]
  def screen_reader_mode?
    screen_reader_optimized == true || accessibility_mode?
  end

  # Check if TTS should pause when user is typing
  # @return [Boolean]
  def tts_pause_on_typing?
    tts_pause_on_typing != false
  end

  # Check if TTS should auto-resume after typing stops
  # @return [Boolean]
  def tts_auto_resume?
    tts_auto_resume != false
  end

  # Get all accessibility settings as a hash
  # @return [Hash]
  def accessibility_settings
    {
      accessibility_mode: accessibility_mode?,
      screen_reader_optimized: screen_reader_optimized == true,
      tts_pause_on_typing: tts_pause_on_typing?,
      tts_auto_resume: tts_auto_resume?,
      reduced_visual_effects: reduced_visual_effects == true,
      high_contrast_mode: high_contrast_mode == true,
      color_blindness_mode: respond_to?(:color_blindness_mode) ? color_blindness_mode : nil,
      dyslexia_font: respond_to?(:dyslexia_font) ? (dyslexia_font == true) : false
    }
  end

  # Configure accessibility settings
  # All parameters are optional - only provided values are updated
  # @param mode [Boolean, nil] Accessibility mode toggle
  # @param screen_reader [Boolean, nil] Screen reader optimization
  # @param pause_on_typing [Boolean, nil] Pause TTS when typing
  # @param auto_resume [Boolean, nil] Auto-resume TTS after typing
  # @param reduced_effects [Boolean, nil] Reduce visual effects
  # @param high_contrast [Boolean, nil] High contrast mode
  def configure_accessibility!(mode: nil, screen_reader: nil, pause_on_typing: nil,
                               auto_resume: nil, reduced_effects: nil, high_contrast: nil,
                               color_blindness: nil, dyslexia: nil)
    updates = {}
    updates[:accessibility_mode] = mode unless mode.nil?
    updates[:screen_reader_optimized] = screen_reader unless screen_reader.nil?
    updates[:tts_pause_on_typing] = pause_on_typing unless pause_on_typing.nil?
    updates[:tts_auto_resume] = auto_resume unless auto_resume.nil?
    updates[:reduced_visual_effects] = reduced_effects unless reduced_effects.nil?
    updates[:high_contrast_mode] = high_contrast unless high_contrast.nil?
    if !color_blindness.nil? && respond_to?(:color_blindness_mode)
      valid_modes = %w[protanopia deuteranopia tritanopia]
      updates[:color_blindness_mode] = valid_modes.include?(color_blindness) ? color_blindness : nil
    end
    if !dyslexia.nil? && respond_to?(:dyslexia_font)
      updates[:dyslexia_font] = dyslexia == true
    end
    update(updates) unless updates.empty?
  end

  # ========================================
  # Discord Notification Settings
  # ========================================

  # Check if Discord notifications are configured
  # @return [Boolean]
  def discord_configured?
    (discord_webhook_url && !discord_webhook_url.to_s.strip.empty?) ||
      (discord_username && !discord_username.to_s.strip.empty?)
  end

  # Check if webhook is configured
  # @return [Boolean]
  def discord_webhook_configured?
    discord_webhook_url && !discord_webhook_url.to_s.strip.empty?
  end

  # Check if Discord handle is configured (for bot DMs)
  # @return [Boolean]
  def discord_dm_configured?
    discord_username && !discord_username.to_s.strip.empty?
  end

  # Check if user should receive Discord notification for an event
  # @param character_instance [CharacterInstance, nil] Current instance (to check online status)
  # @param event_type [Symbol] :memo, :pm, or :mention
  # @return [Boolean]
  def should_notify_discord?(character_instance, event_type)
    return false unless discord_configured?

    # Check online/offline preference
    is_online = character_instance&.online
    if is_online
      return false unless discord_notify_online
    else
      return false unless discord_notify_offline
    end

    # Check event type preference
    case event_type
    when :memo then discord_notify_memos
    when :pm then discord_notify_pms
    when :mention then discord_notify_mentions
    else false
    end
  end

  # Get all Discord notification settings as a hash
  # @return [Hash]
  def discord_settings
    {
      webhook_url: discord_webhook_url,
      username: discord_username,
      notify_offline: discord_notify_offline,
      notify_online: discord_notify_online,
      notify_memos: discord_notify_memos,
      notify_pms: discord_notify_pms,
      notify_mentions: discord_notify_mentions
    }
  end

  # Update Discord settings
  # @param settings [Hash] Settings to update
  def update_discord_settings!(settings)
    updates = {}
    updates[:discord_webhook_url] = settings[:webhook_url] if settings.key?(:webhook_url)

    if settings.key?(:username)
      if settings[:username].nil? || settings[:username].to_s.strip.empty?
        updates[:discord_username] = nil
      else
        normalized_handle = self.class.normalize_discord_handle(settings[:username])
        raise Sequel::ValidationFailed, DISCORD_HANDLE_ERROR unless normalized_handle

        updates[:discord_username] = normalized_handle
      end
    end

    updates[:discord_notify_offline] = settings[:notify_offline] if settings.key?(:notify_offline)
    updates[:discord_notify_online] = settings[:notify_online] if settings.key?(:notify_online)
    updates[:discord_notify_memos] = settings[:notify_memos] if settings.key?(:notify_memos)
    updates[:discord_notify_pms] = settings[:notify_pms] if settings.key?(:notify_pms)
    updates[:discord_notify_mentions] = settings[:notify_mentions] if settings.key?(:notify_mentions)
    update(updates) unless updates.empty?
  end

  # Normalize Discord handle into canonical @handle format.
  # Accepts '@name' or 'name'. Rejects legacy 'name#1234' format.
  # @param value [String, nil]
  # @return [String, nil] normalized handle (e.g., "@player.one"), or nil if invalid/blank
  def self.normalize_discord_handle(value)
    return nil if value.nil?

    handle = value.to_s.strip
    return nil if handle.empty?
    return nil if handle.include?('#')

    handle = handle[1..] if handle.start_with?('@')
    handle = handle.to_s.strip.downcase
    return nil if handle.empty?
    return nil if handle.length < 2 || handle.length > 32
    return nil if handle.include?('..')
    return nil unless handle.match?(DISCORD_HANDLE_REGEX)

    "@#{handle}"
  end

  # Check whether the provided Discord handle is valid in modern format.
  # @param value [String, nil]
  # @return [Boolean]
  def self.valid_discord_handle?(value)
    !normalize_discord_handle(value).nil?
  end

  # Authentication methods
  def self.authenticate(username_or_email, password)
    # Case-insensitive username/email lookup
    return nil if username_or_email.nil?

    input = username_or_email.strip
    user = where(
      Sequel.ilike(:username, input) | Sequel.ilike(:email, input)
    ).first
    return nil unless user
    
    digest = user.password_digest || user.password_hash
    return nil unless digest
    
    begin
      if BCrypt::Password.new(digest) == password
        if user.password_digest.nil?
          user.update(password_digest: digest)
        end
        user
      else
        nil
      end
    rescue BCrypt::Errors::InvalidHash
      nil
    end
  end
  
  def set_password(new_password)
    self.password = new_password
    self.password_digest = BCrypt::Password.create(new_password)
    # Also set legacy fields for compatibility
    self.password_hash = self.password_digest
    self.salt = SecureRandom.hex(16) # Generate a salt even though bcrypt handles its own
  end

  # Verify password for current user (instance method)
  # @param password [String] Plain text password to verify
  # @return [Boolean] True if password matches
  def authenticate(password)
    digest = password_digest || password_hash
    return false unless digest

    begin
      BCrypt::Password.new(digest) == password
    rescue BCrypt::Errors::InvalidHash
      false
    end
  end

  def generate_session_token!
    self.session_token = SecureRandom.hex(32)
    save(validate: false)
    session_token
  end
  
  def clear_session_token!
    self.session_token = nil
    save(validate: false)
  end
  
  def generate_remember_token!
    self.remember_token = SecureRandom.hex(32)
    self.remember_created_at = Time.now
    save(validate: false)
    remember_token
  end
  
  def clear_remember_token!
    self.remember_token = nil
    self.remember_created_at = nil
    save(validate: false)
  end
  
  def remember_valid?(token)
    return false unless remember_token && remember_created_at
    return false unless remember_token == token
    # Remember tokens are valid for 30 days
    remember_created_at > Time.now - (30 * 24 * 60 * 60)
  end

  # API token for machine-to-machine auth (MCP servers, etc.)
  # Tokens are hashed with BCrypt for security.
  # Default expiration: 90 days (nil = never expires for dev convenience)
  def generate_api_token!(expires_in: nil)
    token = SecureRandom.hex(32)
    self[:api_token_digest] = BCrypt::Password.create(token)
    self[:api_token_created_at] = Time.now
    self[:api_token_expires_at] = expires_in ? Time.now + expires_in : nil
    self[:api_token_last_used_at] = nil
    save(validate: false)
    log_api_token_event('generated')
    token  # Return plaintext token only once - it cannot be retrieved later
  end

  def clear_api_token!
    log_api_token_event('cleared')
    self[:api_token_digest] = nil
    self[:api_token_expires_at] = nil
    self[:api_token_created_at] = nil
    self[:api_token_last_used_at] = nil
    save(validate: false)
  end

  def api_token_valid?(token)
    return false if self[:api_token_digest].nil?
    return false if token.nil? || token.empty?
    return false unless token.match?(/\A[a-f0-9]{64}\z/)
    return false if api_token_expired?

    begin
      BCrypt::Password.new(self[:api_token_digest]) == token
    rescue BCrypt::Errors::InvalidHash
      false
    end
  end

  def api_token_expired?
    return false if self[:api_token_expires_at].nil?  # nil = never expires
    self[:api_token_expires_at] < Time.now
  end

  # Check if this user is an API agent (uses API token for authentication)
  # Agents have shorter inactivity timeouts than regular players
  def agent?
    !self[:api_token_digest].nil? && !api_token_expired?
  end

  def touch_api_token_usage!
    self[:api_token_last_used_at] = Time.now
    save(validate: false)
  end

  # Find user by API token using constant-time comparison
  # Returns user if token valid and not expired, nil otherwise
  def self.find_by_api_token(token)
    return nil if token.nil? || token.empty?
    return nil unless token.match?(/\A[a-f0-9]{64}\z/)

    # Find all users with a token digest (typically very few)
    candidates = where(Sequel.~(api_token_digest: nil)).all

    # Use constant-time comparison to prevent timing attacks
    user = candidates.find { |u| u.api_token_valid?(token) }
    return nil unless user

    # Track usage and return
    user.touch_api_token_usage!
    log_api_token_access(user)
    user
  end

  private

  # Format seconds as a human-readable duration
  # @param seconds [Integer]
  # @return [String] e.g., "5 minutes", "1 hour 30 minutes"
  def format_duration(seconds)
    return "0 seconds" if seconds <= 0

    hours = seconds / 3600
    minutes = (seconds % 3600) / 60
    secs = seconds % 60

    parts = []
    parts << "#{hours} hour#{'s' if hours != 1}" if hours > 0
    parts << "#{minutes} minute#{'s' if minutes != 1}" if minutes > 0
    parts << "#{secs} second#{'s' if secs != 1}" if secs > 0 && hours == 0

    parts.join(' ')
  end

  # Titlecase a username, handling multi-word names and hyphenated names
  def titlecase_username(name)
    return nil if name.nil?
    return '' if name.empty?

    name.split(/\s+/).map do |word|
      next word if word.empty?

      if word.include?('-')
        word.split('-').map(&:capitalize).join('-')
      else
        word.capitalize
      end
    end.join(' ')
  end

  def log_api_token_event(event)
    warn "[API_TOKEN] User #{id}: token #{event}"
  end

  def self.log_api_token_access(user)
    warn "[API_TOKEN] Access granted: user=#{user.id}"
  end
end
