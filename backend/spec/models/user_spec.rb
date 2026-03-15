# frozen_string_literal: true

require 'spec_helper'

RSpec.describe User do
  # ========================================
  # Validations
  # ========================================

  describe 'validations' do
    it 'requires username' do
      user = build(:user, username: nil)
      expect(user.valid?).to be false
      expect(user.errors[:username]).to include('is not present')
    end

    it 'requires email' do
      user = build(:user, email: nil)
      expect(user.valid?).to be false
      expect(user.errors[:email]).to include('is not present')
    end

    it 'requires unique username' do
      create(:user, username: 'UniqueTestUser')
      duplicate = build(:user, username: 'UniqueTestUser')
      # Database constraint catches uniqueness violations
      expect { duplicate.save }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'requires unique email' do
      create(:user, email: 'unique-test@example.com')
      duplicate = build(:user, email: 'unique-test@example.com')
      # Model validation catches uniqueness violations
      expect { duplicate.save }.to raise_error(Sequel::ValidationFailed, /email is already taken/)
    end

    it 'validates email format' do
      user = build(:user, email: 'not-an-email')
      expect(user.valid?).to be false
      expect(user.errors[:email]).to include('is invalid')
    end

    it 'accepts valid email formats' do
      valid_emails = ['valid1@example.com', 'valid2+tag@example.com', 'valid3.name@sub.example.co.uk']
      valid_emails.each_with_index do |email, i|
        user = build(:user, username: "ValidEmailTest#{i}", email: email)
        expect(user.valid?).to eq(true), "Expected #{email} to be valid, errors: #{user.errors.full_messages}"
      end
    end

    it 'requires username to be at least 3 characters' do
      user = build(:user, username: 'Ab')
      expect(user.valid?).to be false
      expect(user.errors[:username]).to include('is shorter than 3 characters')
    end

    it 'requires username to be at most 50 characters' do
      user = build(:user, username: 'A' * 51)
      expect(user.valid?).to be false
      expect(user.errors[:username]).to include('is longer than 50 characters')
    end
  end

  # ========================================
  # Before Save Hooks
  # ========================================

  describe 'before save hooks' do
    it 'titlecases username' do
      user = create(:user, username: 'john doe')
      expect(user.username).to eq('John Doe')
    end

    it 'titlecases hyphenated usernames' do
      user = create(:user, username: 'mary-jane watson')
      expect(user.username).to eq('Mary-Jane Watson')
    end

    it 'strips whitespace from username' do
      user = create(:user, username: '  testuser  ')
      expect(user.username).to eq('Testuser')
    end

    it 'lowercases email' do
      user = create(:user, email: 'TEST@EXAMPLE.COM')
      expect(user.email).to eq('test@example.com')
    end

    it 'normalizes email during save' do
      # Note: Whitespace would fail email format validation before before_save runs
      # So we test the normalization that does work (lowercasing)
      user = create(:user, email: 'NORMALIZE@EXAMPLE.COM')
      expect(user.email).to eq('normalize@example.com')
    end
  end

  # ========================================
  # Character Queries
  # ========================================

  describe 'character queries' do
    let(:user) { create(:user) }

    describe '#active_characters' do
      it 'returns only active characters' do
        active = create(:character, user: user, active: true)
        inactive = create(:character, user: user, active: false)

        result = user.active_characters.all
        expect(result).to include(active)
        expect(result).not_to include(inactive)
      end
    end

    describe '#player_characters' do
      it 'returns active non-NPC characters' do
        # Create characters directly to bypass validations
        player_char = Character.create(
          user_id: user.id, name: 'PlayerChar', forename: 'Player', is_npc: false, active: true,
          short_desc: 'A player', nickname: 'Player'
        )
        npc_char = Character.new(
          user_id: user.id, name: 'NPCChar', forename: 'NPC', is_npc: true, active: true,
          short_desc: 'An NPC', nickname: 'NPC'
        )
        npc_char.save(validate: false) # Bypass NPC validation
        inactive_char = Character.create(
          user_id: user.id, name: 'InactiveChar', forename: 'Inactive', is_npc: false, active: false,
          short_desc: 'Inactive', nickname: 'Inactive'
        )

        result = user.player_characters.all
        expect(result.map(&:id)).to include(player_char.id)
        expect(result.map(&:id)).not_to include(npc_char.id)
        expect(result.map(&:id)).not_to include(inactive_char.id)
      end
    end

    describe '#staff_characters' do
      it 'returns active staff characters' do
        # Give user permission to create staff characters
        user.grant_permission!('can_create_staff_characters')

        staff_char = Character.new(
          user_id: user.id, name: 'StaffChar', forename: 'Staff', is_staff_character: true, active: true,
          short_desc: 'Staff', nickname: 'Staff'
        )
        staff_char.save(validate: false) # Bypass validation
        normal_char = Character.create(
          user_id: user.id, name: 'NormalChar', forename: 'Normal', is_staff_character: false, active: true,
          short_desc: 'Normal', nickname: 'Normal'
        )
        inactive_staff = Character.new(
          user_id: user.id, name: 'InactiveStaff', forename: 'InactiveStaff', is_staff_character: true, active: false,
          short_desc: 'Inactive Staff', nickname: 'InactiveStaff'
        )
        inactive_staff.save(validate: false)

        result = user.staff_characters.all
        expect(result.map(&:id)).to include(staff_char.id)
        expect(result.map(&:id)).not_to include(normal_char.id)
        expect(result.map(&:id)).not_to include(inactive_staff.id)
      end
    end
  end

  # ========================================
  # Admin & Permission Methods
  # ========================================

  describe 'admin and permissions' do
    describe '#admin?' do
      it 'returns true for admin users' do
        user = create(:user, :admin)
        expect(user.admin?).to be true
      end

      it 'returns false for regular users' do
        user = create(:user)
        expect(user.admin?).to be false
      end
    end

    describe 'first user auto-admin' do
      it 'makes the first user an admin automatically' do
        # Clear all users to test first-user logic
        Character.dataset.delete # Clear characters first due to FK
        User.dataset.delete

        # Create user without factory to avoid factory's after_create hook
        first_user = User.new(username: 'FirstUser', email: 'first@example.com')
        first_user.set_password('password')
        first_user.save

        # First user should be auto-admin via before_create
        expect(first_user.admin?).to be true
      end
    end

    describe '#has_permission?' do
      it 'returns true for any permission if user is admin' do
        admin = create(:user, :admin)
        expect(admin.has_permission?('can_build')).to be true
        expect(admin.has_permission?('nonexistent_permission')).to be true
      end

      it 'returns true if user has the specific permission' do
        user = create(:user)
        user.grant_permission!('can_build')
        expect(user.has_permission?('can_build')).to be true
      end

      it 'returns false if user lacks the permission' do
        user = create(:user)
        expect(user.has_permission?('can_build')).to be false
      end

      it 'accepts symbol permission names' do
        user = create(:user)
        user.grant_permission!(:can_build)
        expect(user.has_permission?(:can_build)).to be true
      end
    end

    describe '#grant_permission!' do
      it 'grants a valid permission' do
        user = create(:user)
        result = user.grant_permission!('can_build')
        expect(result).to be true
        expect(user.has_permission?('can_build')).to be true
      end

      it 'returns false for invalid permissions' do
        user = create(:user)
        result = user.grant_permission!('invalid_permission')
        expect(result).to be false
      end

      it 'persists permission to database' do
        user = create(:user)
        user.grant_permission!('can_build')
        reloaded = User[user.id]
        expect(reloaded.has_permission?('can_build')).to be true
      end
    end

    describe '#revoke_permission!' do
      it 'revokes a granted permission' do
        user = create(:user)
        user.grant_permission!('can_build')
        user.revoke_permission!('can_build')
        expect(user.has_permission?('can_build')).to be false
      end

      it 'returns true even if permission was not granted' do
        user = create(:user)
        result = user.revoke_permission!('can_build')
        expect(result).to be true
      end
    end

    describe '#granted_permissions' do
      it 'returns all permissions for admins' do
        admin = create(:user, :admin)
        expect(admin.granted_permissions).to eq(Permission.all)
      end

      it 'returns only granted permissions for regular users' do
        user = create(:user)
        user.grant_permission!('can_build')
        user.grant_permission!('can_moderate')
        expect(user.granted_permissions).to contain_exactly('can_build', 'can_moderate')
      end

      it 'returns empty array for users with no permissions' do
        user = create(:user)
        expect(user.granted_permissions).to eq([])
      end
    end

    describe '#staff?' do
      it 'returns true for admins' do
        admin = create(:user, :admin)
        expect(admin.staff?).to be true
      end

      it 'returns true for users with staff permissions' do
        user = create(:user)
        user.grant_permission!('can_create_staff_characters')
        expect(user.staff?).to be true
      end

      it 'returns false for regular users' do
        user = create(:user)
        expect(user.staff?).to be false
      end
    end

    describe 'convenience permission methods' do
      let(:user) { create(:user) }

      it '#can_access_admin_console? checks the correct permission' do
        expect(user.can_access_admin_console?).to be false
        user.grant_permission!('can_access_admin_console')
        expect(user.can_access_admin_console?).to be true
      end

      it '#can_build? checks the correct permission' do
        expect(user.can_build?).to be false
        user.grant_permission!('can_build')
        expect(user.can_build?).to be true
      end

      it '#can_moderate? checks the correct permission' do
        expect(user.can_moderate?).to be false
        user.grant_permission!('can_moderate')
        expect(user.can_moderate?).to be true
      end
    end
  end

  # ========================================
  # Suspension Methods
  # ========================================

  describe 'suspension' do
    let(:user) { create(:user) }
    let(:staff) { create(:user, :admin) }

    describe '#suspended?' do
      it 'returns false for non-suspended users' do
        expect(user.suspended?).to be false
      end

      it 'returns true for permanently suspended users' do
        user.suspend!(reason: 'Bad behavior')
        expect(user.suspended?).to be true
      end

      it 'returns true for temporarily suspended users within suspension period' do
        user.suspend!(reason: 'Timeout', until_time: Time.now + 3600)
        expect(user.suspended?).to be true
      end

      it 'returns false for expired temporary suspensions' do
        user.suspend!(reason: 'Timeout', until_time: Time.now - 1)
        expect(user.suspended?).to be false
      end
    end

    describe '#suspend!' do
      it 'sets suspension fields' do
        user.suspend!(reason: 'Test reason', until_time: Time.now + 3600, by_user: staff)
        expect(user.suspended_at).not_to be_nil
        expect(user.suspension_reason).to eq('Test reason')
        expect(user.suspended_by_user_id).to eq(staff.id)
      end

      it 'creates permanent suspension when until_time is nil' do
        user.suspend!(reason: 'Permanent ban')
        expect(user.suspension_permanent?).to be true
      end
    end

    describe '#unsuspend!' do
      it 'clears all suspension fields' do
        user.suspend!(reason: 'Test', by_user: staff)
        user.unsuspend!
        expect(user.suspended?).to be false
        expect(user.suspended_at).to be_nil
        expect(user.suspension_reason).to be_nil
        expect(user.suspended_by_user_id).to be_nil
      end
    end

    describe '#suspension_permanent?' do
      it 'returns true for permanent suspensions' do
        user.suspend!(reason: 'Banned')
        expect(user.suspension_permanent?).to be true
      end

      it 'returns false for temporary suspensions' do
        user.suspend!(reason: 'Timeout', until_time: Time.now + 3600)
        expect(user.suspension_permanent?).to be false
      end
    end

    describe '#suspension_remaining' do
      it 'returns nil for non-suspended users' do
        expect(user.suspension_remaining).to be_nil
      end

      it 'returns nil for permanent suspensions' do
        user.suspend!(reason: 'Banned')
        expect(user.suspension_remaining).to be_nil
      end

      it 'returns remaining seconds for temporary suspensions' do
        user.suspend!(reason: 'Timeout', until_time: Time.now + 3600)
        remaining = user.suspension_remaining
        expect(remaining).to be_between(3590, 3600)
      end
    end

    describe '#suspended_by' do
      it 'returns the staff member who suspended' do
        user.suspend!(reason: 'Test', by_user: staff)
        expect(user.suspended_by).to eq(staff)
      end

      it 'returns nil if no suspender recorded' do
        user.suspend!(reason: 'Test')
        expect(user.suspended_by).to be_nil
      end
    end

    describe '#suspension_info' do
      it 'returns nil for non-suspended users' do
        expect(user.suspension_info).to be_nil
      end

      it 'returns suspension details hash' do
        user.suspend!(reason: 'Test reason', by_user: staff)
        info = user.suspension_info
        expect(info[:reason]).to eq('Test reason')
        expect(info[:permanent]).to be true
        expect(info[:suspended_by]).to eq(staff.username)
      end
    end

    describe '#check_suspension_expired!' do
      it 'returns false for non-suspended users' do
        expect(user.check_suspension_expired!).to be false
      end

      it 'returns false for permanent suspensions' do
        user.suspend!(reason: 'Permanent')
        expect(user.check_suspension_expired!).to be false
        expect(user.suspended?).to be true
      end

      it 'returns false for active temporary suspensions' do
        user.suspend!(reason: 'Timeout', until_time: Time.now + 3600)
        expect(user.check_suspension_expired!).to be false
        expect(user.suspended?).to be true
      end

      it 'returns true and unsuspends for expired suspensions' do
        user.suspend!(reason: 'Timeout', until_time: Time.now - 1)
        result = user.check_suspension_expired!
        expect(result).to be true
        expect(user.suspended?).to be false
      end
    end
  end

  # ========================================
  # Mute Methods
  # ========================================

  describe 'muting' do
    let(:user) { create(:user) }

    describe '#muted?' do
      it 'returns false for non-muted users' do
        expect(user.muted?).to be false
      end

      it 'returns true when muted_until is in the future' do
        user.mute!(900) # 15 minutes
        expect(user.muted?).to be true
      end

      it 'returns false when mute has expired' do
        user.this.update(muted_until: Time.now - 1)
        expect(user.muted?).to be false
      end
    end

    describe '#mute!' do
      it 'sets muted_until to future time' do
        user.mute!(900)
        expect(user.muted_until).to be > Time.now
        expect(user.muted_until).to be_within(5).of(Time.now + 900)
      end

      it 'returns self for chaining' do
        result = user.mute!(900)
        expect(result).to eq(user)
      end

      it 'ignores nil duration' do
        user.mute!(nil)
        expect(user.muted?).to be false
      end

      it 'ignores zero duration' do
        user.mute!(0)
        expect(user.muted?).to be false
      end

      it 'ignores negative duration' do
        user.mute!(-100)
        expect(user.muted?).to be false
      end
    end

    describe '#unmute!' do
      it 'clears muted_until' do
        user.mute!(900)
        user.unmute!
        expect(user.muted?).to be false
        expect(user.muted_until).to be_nil
      end
    end

    describe '#mute_remaining_seconds' do
      it 'returns 0 for non-muted users' do
        expect(user.mute_remaining_seconds).to eq(0)
      end

      it 'returns remaining seconds for muted users' do
        user.mute!(900)
        remaining = user.mute_remaining_seconds
        expect(remaining).to be_between(890, 900)
      end
    end

    describe '#check_mute_expired!' do
      it 'returns false for non-muted users' do
        expect(user.check_mute_expired!).to be false
      end

      it 'returns false for active mutes' do
        user.mute!(900)
        expect(user.check_mute_expired!).to be false
        expect(user.muted?).to be true
      end

      it 'returns true and unmutes when mute has expired' do
        user.this.update(muted_until: Time.now - 1)
        user.refresh
        result = user.check_mute_expired!
        expect(result).to be true
        expect(user.muted?).to be false
      end
    end

    describe '#mute_info' do
      it 'returns nil for non-muted users' do
        expect(user.mute_info).to be_nil
      end

      it 'returns mute details hash for muted users' do
        user.mute!(900)
        info = user.mute_info
        expect(info[:muted_until]).to be_within(5).of(Time.now + 900)
        expect(info[:remaining_seconds]).to be_between(890, 900)
        expect(info[:remaining_display]).to be_a(String)
      end
    end
  end

  # ========================================
  # Email Verification
  # ========================================

  describe 'email verification' do
    let(:user) { create(:user) }

    describe '#email_verified?' do
      it 'returns false when confirmed_at is nil' do
        expect(user.email_verified?).to be false
      end

      it 'returns true when confirmed_at is set' do
        user.update(confirmed_at: Time.now)
        expect(user.email_verified?).to be true
      end
    end

    describe '#generate_confirmation_token!' do
      it 'generates a token' do
        token = user.generate_confirmation_token!
        expect(token).to be_a(String)
        expect(token.length).to be > 20
      end

      it 'stores the token on the user' do
        token = user.generate_confirmation_token!
        expect(user.confirmation_token).to eq(token)
      end

      it 'sets confirmation_token_created_at' do
        user.generate_confirmation_token!
        expect(user.confirmation_token_created_at).to be_within(1).of(Time.now)
      end
    end

    describe '#confirmation_token_valid?' do
      it 'returns false when no token exists' do
        expect(user.confirmation_token_valid?).to be false
      end

      it 'returns true for fresh tokens' do
        user.generate_confirmation_token!
        expect(user.confirmation_token_valid?).to be true
      end

      it 'returns false for expired tokens (>24 hours)' do
        user.generate_confirmation_token!
        user.update(confirmation_token_created_at: Time.now - (25 * 60 * 60))
        expect(user.confirmation_token_valid?).to be false
      end
    end

    describe '#confirm_email!' do
      before { user.generate_confirmation_token! }

      it 'returns :success with correct token' do
        token = user.confirmation_token
        result = user.confirm_email!(token)
        expect(result).to eq(:success)
      end

      it 'sets confirmed_at on success' do
        token = user.confirmation_token
        user.confirm_email!(token)
        expect(user.confirmed_at).not_to be_nil
      end

      it 'clears token on success' do
        token = user.confirmation_token
        user.confirm_email!(token)
        expect(user.confirmation_token).to be_nil
      end

      it 'returns :invalid with wrong token' do
        result = user.confirm_email!('wrong-token')
        expect(result).to eq(:invalid)
      end

      it 'returns :expired for expired tokens' do
        user.update(confirmation_token_created_at: Time.now - (25 * 60 * 60))
        result = user.confirm_email!(user.confirmation_token)
        expect(result).to eq(:expired)
      end
    end
  end

  # ========================================
  # Password Reset
  # ========================================

  describe 'password reset' do
    let(:user) { create(:user) }

    describe '#generate_password_reset_token!' do
      it 'generates a token' do
        token = user.generate_password_reset_token!
        expect(token).to be_a(String)
        expect(token.length).to be > 20
      end

      it 'stores the token on the user' do
        token = user.generate_password_reset_token!
        expect(user.password_reset_token).to eq(token)
      end

      it 'sets password_reset_token_created_at' do
        user.generate_password_reset_token!
        expect(user.password_reset_token_created_at).to be_within(1).of(Time.now)
      end
    end

    describe '#password_reset_token_valid?' do
      it 'returns false when no token exists' do
        expect(user.password_reset_token_valid?).to be false
      end

      it 'returns true for fresh tokens' do
        user.generate_password_reset_token!
        expect(user.password_reset_token_valid?).to be true
      end

      it 'returns false for expired tokens (>1 hour)' do
        user.generate_password_reset_token!
        user.update(password_reset_token_created_at: Time.now - (2 * 60 * 60))
        expect(user.password_reset_token_valid?).to be false
      end
    end

    describe '#reset_password_with_token!' do
      before { user.generate_password_reset_token! }

      it 'returns :success with correct token' do
        token = user.password_reset_token
        result = user.reset_password_with_token!(token, 'new_password123')
        expect(result).to eq(:success)
      end

      it 'changes the password on success' do
        token = user.password_reset_token
        user.reset_password_with_token!(token, 'new_password123')
        user.refresh
        authenticated = User.authenticate(user.username, 'new_password123')
        expect(authenticated&.id).to eq(user.id)
      end

      it 'clears token on success' do
        token = user.password_reset_token
        user.reset_password_with_token!(token, 'new_password123')
        expect(user.password_reset_token).to be_nil
        expect(user.password_reset_token_created_at).to be_nil
      end

      it 'returns :invalid with wrong token' do
        result = user.reset_password_with_token!('wrong-token', 'new_password123')
        expect(result).to eq(:invalid)
      end

      it 'returns :expired for expired tokens' do
        user.update(password_reset_token_created_at: Time.now - (2 * 60 * 60))
        result = user.reset_password_with_token!(user.password_reset_token, 'new_password123')
        expect(result).to eq(:expired)
      end

      it 'does not change password on failure' do
        user.set_password('original_password')
        user.save
        user.reset_password_with_token!('wrong-token', 'new_password123')
        user.refresh
        authenticated = User.authenticate(user.username, 'original_password')
        expect(authenticated&.id).to eq(user.id)
      end
    end
  end

  # ========================================
  # Playtime Tracking
  # ========================================

  describe 'playtime tracking' do
    let(:user) { create(:user) }

    describe '#total_playtime_hours' do
      it 'returns 0 for new users' do
        expect(user.total_playtime_hours).to eq(0.0)
      end

      it 'converts seconds to hours' do
        user.update(total_playtime_seconds: 7200)
        expect(user.total_playtime_hours).to eq(2.0)
      end
    end

    describe '#exempt_from_abuse_checks?' do
      it 'returns false for users under 100 hours' do
        user.update(total_playtime_seconds: 359_999)
        expect(user.exempt_from_abuse_checks?).to be false
      end

      it 'returns true for users with 100+ hours' do
        user.update(total_playtime_seconds: 360_000)
        expect(user.exempt_from_abuse_checks?).to be true
      end
    end

    describe '#increment_playtime!' do
      it 'adds seconds to total' do
        user.increment_playtime!(3600)
        expect(user.total_playtime_seconds).to eq(3600)
      end

      it 'accumulates over multiple calls' do
        user.increment_playtime!(3600)
        user.increment_playtime!(1800)
        expect(user.total_playtime_seconds).to eq(5400)
      end

      it 'ignores nil or negative values' do
        user.increment_playtime!(nil)
        user.increment_playtime!(-100)
        expect(user.total_playtime_seconds || 0).to eq(0)
      end
    end

    describe '#playtime_display' do
      it 'formats hours and minutes' do
        user.update(total_playtime_seconds: 7830) # 2h 10m 30s
        expect(user.playtime_display).to eq('2h 10m')
      end

      it 'handles zero playtime' do
        expect(user.playtime_display).to eq('0h 0m')
      end
    end
  end

  # ========================================
  # Authentication
  # ========================================

  describe 'authentication' do
    describe '.authenticate' do
      let(:user) { create(:user, username: 'TestUser', email: 'test@example.com') }

      before do
        user.set_password('correct_password')
        user.save
      end

      it 'authenticates with correct username and password' do
        result = User.authenticate('TestUser', 'correct_password')
        expect(result&.id).to eq(user.id)
      end

      it 'authenticates with email instead of username' do
        result = User.authenticate('test@example.com', 'correct_password')
        expect(result&.id).to eq(user.id)
      end

      it 'authenticates case-insensitively' do
        result = User.authenticate('testuser', 'correct_password')
        expect(result&.id).to eq(user.id)
      end

      it 'returns nil for wrong password' do
        result = User.authenticate('TestUser', 'wrong_password')
        expect(result).to be_nil
      end

      it 'returns nil for non-existent user' do
        result = User.authenticate('nobody', 'password')
        expect(result).to be_nil
      end
    end

    describe '#set_password' do
      it 'sets password_digest' do
        user = build(:user)
        user.set_password('new_password')
        expect(user.password_digest).to be_a(String)
        expect(user.password_digest).to start_with('$2')
      end

      it 'allows authentication after setting' do
        user = create(:user)
        user.set_password('new_password')
        user.save
        result = User.authenticate(user.username, 'new_password')
        expect(result&.id).to eq(user.id)
      end
    end
  end

  # ========================================
  # Session Tokens
  # ========================================

  describe 'session tokens' do
    let(:user) { create(:user) }

    describe '#generate_session_token!' do
      it 'generates a hex token' do
        token = user.generate_session_token!
        expect(token).to match(/\A[a-f0-9]{64}\z/)
      end

      it 'persists the token' do
        token = user.generate_session_token!
        expect(User[user.id].session_token).to eq(token)
      end
    end

    describe '#clear_session_token!' do
      it 'removes the session token' do
        user.generate_session_token!
        user.clear_session_token!
        expect(user.session_token).to be_nil
      end
    end
  end

  # ========================================
  # Remember Tokens
  # ========================================

  describe 'remember tokens' do
    let(:user) { create(:user) }

    describe '#generate_remember_token!' do
      it 'generates a hex token' do
        token = user.generate_remember_token!
        expect(token).to match(/\A[a-f0-9]{64}\z/)
      end

      it 'sets remember_created_at' do
        user.generate_remember_token!
        expect(user.remember_created_at).to be_within(1).of(Time.now)
      end
    end

    describe '#remember_valid?' do
      it 'returns true for valid fresh token' do
        token = user.generate_remember_token!
        expect(user.remember_valid?(token)).to be true
      end

      it 'returns false for wrong token' do
        user.generate_remember_token!
        expect(user.remember_valid?('wrong-token')).to be false
      end

      it 'returns false for expired token (>30 days)' do
        token = user.generate_remember_token!
        user.update(remember_created_at: Time.now - (31 * 24 * 60 * 60))
        expect(user.remember_valid?(token)).to be false
      end

      it 'returns false when no token exists' do
        expect(user.remember_valid?('any-token')).to be false
      end
    end

    describe '#clear_remember_token!' do
      it 'clears token and timestamp' do
        user.generate_remember_token!
        user.clear_remember_token!
        expect(user.remember_token).to be_nil
        expect(user.remember_created_at).to be_nil
      end
    end
  end

  # ========================================
  # API Tokens
  # ========================================

  describe 'API tokens' do
    let(:user) { create(:user) }

    describe '#generate_api_token!' do
      it 'generates a hex token' do
        token = user.generate_api_token!
        expect(token).to match(/\A[a-f0-9]{64}\z/)
      end

      it 'stores a hashed digest, not plaintext' do
        token = user.generate_api_token!
        expect(user[:api_token_digest]).not_to eq(token)
        expect(user[:api_token_digest]).to start_with('$2')
      end

      it 'sets created_at timestamp' do
        user.generate_api_token!
        expect(user[:api_token_created_at]).to be_within(1).of(Time.now)
      end

      it 'can set expiration' do
        user.generate_api_token!(expires_in: 3600)
        expect(user[:api_token_expires_at]).to be_within(5).of(Time.now + 3600)
      end

      it 'defaults to no expiration' do
        user.generate_api_token!
        expect(user[:api_token_expires_at]).to be_nil
      end
    end

    describe '#api_token_valid?' do
      it 'returns true for valid token' do
        token = user.generate_api_token!
        expect(user.api_token_valid?(token)).to be true
      end

      it 'returns false for wrong token' do
        user.generate_api_token!
        expect(user.api_token_valid?('wrong' * 16)).to be false
      end

      it 'returns false for expired token' do
        token = user.generate_api_token!(expires_in: -1)
        expect(user.api_token_valid?(token)).to be false
      end

      it 'returns false for nil token' do
        user.generate_api_token!
        expect(user.api_token_valid?(nil)).to be false
      end

      it 'returns false for malformed token' do
        user.generate_api_token!
        expect(user.api_token_valid?('short')).to be false
      end
    end

    describe '#api_token_expired?' do
      it 'returns false when no expiration set' do
        user.generate_api_token!
        expect(user.api_token_expired?).to be false
      end

      it 'returns false for future expiration' do
        user.generate_api_token!(expires_in: 3600)
        expect(user.api_token_expired?).to be false
      end

      it 'returns true for past expiration' do
        user.generate_api_token!(expires_in: -1)
        expect(user.api_token_expired?).to be true
      end
    end

    describe '#clear_api_token!' do
      it 'clears all token fields' do
        user.generate_api_token!
        user.clear_api_token!
        expect(user[:api_token_digest]).to be_nil
        expect(user[:api_token_expires_at]).to be_nil
        expect(user[:api_token_created_at]).to be_nil
      end
    end

    describe '.find_by_api_token' do
      it 'finds user by valid token' do
        token = user.generate_api_token!
        found = User.find_by_api_token(token)
        expect(found&.id).to eq(user.id)
      end

      it 'returns nil for invalid token' do
        user.generate_api_token!
        found = User.find_by_api_token('invalid' * 8)
        expect(found).to be_nil
      end

      it 'returns nil for nil token' do
        found = User.find_by_api_token(nil)
        expect(found).to be_nil
      end

      it 'updates last_used_at on successful lookup' do
        token = user.generate_api_token!
        User.find_by_api_token(token)
        user.refresh
        expect(user[:api_token_last_used_at]).to be_within(1).of(Time.now)
      end
    end

    describe '#agent?' do
      it 'returns true when user has valid API token' do
        user.generate_api_token!
        expect(user.agent?).to be true
      end

      it 'returns false when no API token' do
        expect(user.agent?).to be false
      end

      it 'returns false when API token is expired' do
        user.generate_api_token!(expires_in: -1)
        expect(user.agent?).to be false
      end
    end
  end

  # ========================================
  # Narrator Voice (TTS)
  # ========================================

  describe 'narrator voice' do
    let(:user) { create(:user) }

    describe '#narrator_settings' do
      it 'returns default settings' do
        settings = user.narrator_settings
        expect(settings[:voice_type]).to eq('Kore')
        expect(settings[:voice_pitch]).to eq(0.0)
        expect(settings[:voice_speed]).to eq(1.0)
      end
    end

    describe '#set_narrator_voice!' do
      it 'sets custom voice settings' do
        user.set_narrator_voice!(type: 'Charon', pitch: 5.0, speed: 1.5)
        expect(user.narrator_voice_type).to eq('Charon')
        expect(user.narrator_voice_pitch).to eq(5.0)
        expect(user.narrator_voice_speed).to eq(1.5)
      end

      it 'clamps pitch to valid range' do
        user.set_narrator_voice!(type: 'Kore', pitch: 100.0)
        expect(user.narrator_voice_pitch).to eq(20.0)
      end

      it 'clamps speed to valid range' do
        user.set_narrator_voice!(type: 'Kore', speed: 10.0)
        expect(user.narrator_voice_speed).to eq(4.0)
      end
    end

    describe '#has_narrator_voice?' do
      it 'returns true by default (default voice is Kore)' do
        # Database default is 'Kore', so has_narrator_voice? returns true
        expect(user.has_narrator_voice?).to be true
      end

      it 'returns false when voice type is cleared' do
        user.update(narrator_voice_type: nil)
        expect(user.has_narrator_voice?).to be_falsey
      end

      it 'returns true when voice type is set to custom voice' do
        user.set_narrator_voice!(type: 'Charon')
        expect(user.has_narrator_voice?).to be true
      end
    end
  end

  # ========================================
  # Accessibility Settings
  # ========================================

  describe 'accessibility settings' do
    let(:user) { create(:user) }

    describe '#accessibility_mode?' do
      it 'returns false by default' do
        expect(user.accessibility_mode?).to be false
      end

      it 'returns true when enabled' do
        user.update(accessibility_mode: true)
        expect(user.accessibility_mode?).to be true
      end
    end

    describe '#screen_reader_mode?' do
      it 'returns false by default' do
        expect(user.screen_reader_mode?).to be false
      end

      it 'returns true when screen_reader_optimized is true' do
        user.update(screen_reader_optimized: true)
        expect(user.screen_reader_mode?).to be true
      end

      it 'returns true when accessibility_mode is true (implies screen reader)' do
        user.update(accessibility_mode: true)
        expect(user.screen_reader_mode?).to be true
      end
    end

    describe '#accessibility_settings' do
      it 'returns all accessibility settings as hash' do
        settings = user.accessibility_settings
        expect(settings).to include(
          accessibility_mode: false,
          screen_reader_optimized: false,
          tts_pause_on_typing: true,
          tts_auto_resume: true
        )
      end
    end

    describe '#configure_accessibility!' do
      it 'updates only specified settings' do
        user.configure_accessibility!(mode: true, high_contrast: true)
        expect(user.accessibility_mode?).to be true
        expect(user.high_contrast_mode).to be true
        # Unspecified settings remain unchanged
        expect(user.screen_reader_optimized).to be_falsey
      end
    end
  end

  # ========================================
  # Discord Settings
  # ========================================

  describe 'discord settings' do
    let(:user) { create(:user) }

    describe '#discord_configured?' do
      it 'returns false when webhook and username are empty' do
        user.update(discord_webhook_url: nil, discord_username: nil)
        expect(user.discord_configured?).to be_falsey
      end

      it 'returns true when webhook URL is set' do
        user.update(discord_webhook_url: 'https://discord.com/api/webhooks/123')
        expect(user.discord_configured?).to be true
      end

      it 'returns true when username is set' do
        user.update(discord_username: '@user1234')
        expect(user.discord_configured?).to be true
      end
    end

    describe '#update_discord_settings!' do
      it 'updates specified settings' do
        user.update_discord_settings!(
          webhook_url: 'https://discord.com/api/webhooks/456',
          notify_memos: true
        )
        expect(user.discord_webhook_url).to eq('https://discord.com/api/webhooks/456')
        expect(user.discord_notify_memos).to be true
      end

      it 'normalizes modern discord handles' do
        user.update_discord_settings!(username: 'TeSt.User')
        expect(user.discord_username).to eq('@test.user')
      end

      it 'raises on legacy discriminator handles' do
        expect do
          user.update_discord_settings!(username: 'LegacyName#1234')
        end.to raise_error(Sequel::ValidationFailed, /Invalid Discord handle/)
      end
    end

    describe '.normalize_discord_handle' do
      it 'normalizes handles with or without @ prefix' do
        expect(User.normalize_discord_handle('@TeSt_User')).to eq('@test_user')
        expect(User.normalize_discord_handle('TeSt.User')).to eq('@test.user')
      end

      it 'returns nil for legacy discriminator format' do
        expect(User.normalize_discord_handle('name#1234')).to be_nil
      end

      it 'returns nil for invalid characters' do
        expect(User.normalize_discord_handle('invalid handle')).to be_nil
      end
    end

    describe '#should_notify_discord?' do
      before do
        user.update(
          discord_webhook_url: 'https://discord.com/api/webhooks/123',
          discord_notify_offline: true,
          discord_notify_memos: true,
          discord_notify_pms: false
        )
      end

      it 'returns true for enabled event type when offline' do
        expect(user.should_notify_discord?(nil, :memo)).to be true
      end

      it 'returns false for disabled event type' do
        expect(user.should_notify_discord?(nil, :pm)).to be false
      end

      it 'returns false when discord is not configured' do
        user.update(discord_webhook_url: nil, discord_username: nil)
        expect(user.should_notify_discord?(nil, :memo)).to be false
      end
    end
  end

  # ========================================
  # Gradient Preferences
  # ========================================

  describe 'gradient preferences' do
    let(:user) { create(:user) }

    describe '#recent_gradient_ids' do
      it 'returns empty array by default' do
        expect(user.recent_gradient_ids).to eq([])
      end
    end

    describe '#add_recent_gradient!' do
      it 'adds gradient to recent list' do
        user.add_recent_gradient!(123)
        expect(user.recent_gradient_ids).to eq([123])
      end

      it 'moves existing gradient to front' do
        user.add_recent_gradient!(1)
        user.add_recent_gradient!(2)
        user.add_recent_gradient!(1)
        expect(user.recent_gradient_ids).to eq([1, 2])
      end

      it 'limits to 10 gradients' do
        (1..15).each { |i| user.add_recent_gradient!(i) }
        expect(user.recent_gradient_ids.length).to eq(10)
        expect(user.recent_gradient_ids.first).to eq(15)
      end
    end
  end

  # ========================================
  # Additional Edge Case Tests
  # ========================================

  describe '#verification_required?' do
    let(:user) { create(:user) }

    it 'returns false when email verification is disabled' do
      allow(GameSetting).to receive(:boolean).with('email_require_verification').and_return(false)
      expect(user.verification_required?).to be false
    end

    it 'returns true when verification is enabled and user is not verified' do
      allow(GameSetting).to receive(:boolean).with('email_require_verification').and_return(true)
      expect(user.email_verified?).to be false
      expect(user.verification_required?).to be true
    end

    it 'returns false when verification is enabled but user is verified' do
      allow(GameSetting).to receive(:boolean).with('email_require_verification').and_return(true)
      user.update(confirmed_at: Time.now)
      expect(user.verification_required?).to be false
    end
  end

  describe 'discord notification edge cases' do
    let(:user) { create(:user) }

    describe '#discord_webhook_configured?' do
      it 'returns false when webhook_url is nil' do
        user.update(discord_webhook_url: nil)
        expect(user.discord_webhook_configured?).to be_falsey
      end

      it 'returns false when webhook_url is empty string' do
        user.update(discord_webhook_url: '  ')
        expect(user.discord_webhook_configured?).to be_falsey
      end

      it 'returns true when webhook_url is present' do
        user.update(discord_webhook_url: 'https://discord.com/api/webhooks/123')
        expect(user.discord_webhook_configured?).to be true
      end
    end

    describe '#discord_dm_configured?' do
      it 'returns false when username is nil' do
        user.update(discord_username: nil)
        expect(user.discord_dm_configured?).to be_falsey
      end

      it 'returns false when username is empty string' do
        user.update(discord_username: '  ')
        expect(user.discord_dm_configured?).to be_falsey
      end

      it 'returns true when username is present' do
        user.update(discord_username: '@user1234')
        expect(user.discord_dm_configured?).to be true
      end
    end

    describe '#should_notify_discord? with online character' do
      before do
        user.update(
          discord_webhook_url: 'https://discord.com/api/webhooks/123',
          discord_notify_offline: false,
          discord_notify_online: true,
          discord_notify_memos: true
        )
      end

      it 'returns true when character is online and notify_online is true' do
        instance = double('CharacterInstance', online: true)
        expect(user.should_notify_discord?(instance, :memo)).to be true
      end

      it 'returns false when character is online but notify_online is false' do
        user.update(discord_notify_online: false)
        instance = double('CharacterInstance', online: true)
        expect(user.should_notify_discord?(instance, :memo)).to be false
      end

      it 'returns false when character is offline but notify_offline is false' do
        instance = double('CharacterInstance', online: false)
        expect(user.should_notify_discord?(instance, :memo)).to be false
      end
    end

    describe '#should_notify_discord? event types' do
      before do
        user.update(
          discord_webhook_url: 'https://discord.com/api/webhooks/123',
          discord_notify_offline: true,
          discord_notify_memos: true,
          discord_notify_pms: true,
          discord_notify_mentions: true
        )
      end

      it 'handles :pm event type' do
        expect(user.should_notify_discord?(nil, :pm)).to be true
      end

      it 'handles :mention event type' do
        expect(user.should_notify_discord?(nil, :mention)).to be true
      end

      it 'returns false for unknown event type' do
        expect(user.should_notify_discord?(nil, :unknown)).to be false
      end
    end
  end

  describe 'TTS setting defaults' do
    let(:user) { create(:user) }

    describe '#tts_pause_on_typing?' do
      it 'returns true by default (nil value)' do
        expect(user.tts_pause_on_typing?).to be true
      end

      it 'returns false when explicitly set to false' do
        user.update(tts_pause_on_typing: false)
        expect(user.tts_pause_on_typing?).to be false
      end

      it 'returns true when explicitly set to true' do
        user.update(tts_pause_on_typing: true)
        expect(user.tts_pause_on_typing?).to be true
      end
    end

    describe '#tts_auto_resume?' do
      it 'returns true by default (nil value)' do
        expect(user.tts_auto_resume?).to be true
      end

      it 'returns false when explicitly set to false' do
        user.update(tts_auto_resume: false)
        expect(user.tts_auto_resume?).to be false
      end
    end
  end

  describe 'connection history methods' do
    let(:user) { create(:user) }

    describe '#known_ips' do
      it 'delegates to ConnectionLog.unique_ips_for_user' do
        expect(ConnectionLog).to receive(:unique_ips_for_user).with(user.id).and_return(['192.168.1.1'])
        expect(user.known_ips).to eq(['192.168.1.1'])
      end
    end

    describe '#connection_history' do
      it 'delegates to ConnectionLog.recent_for_user with default limit' do
        expect(ConnectionLog).to receive(:recent_for_user).with(user.id, limit: 50).and_return([])
        expect(user.connection_history).to eq([])
      end

      it 'passes custom limit' do
        expect(ConnectionLog).to receive(:recent_for_user).with(user.id, limit: 10).and_return([])
        expect(user.connection_history(limit: 10)).to eq([])
      end
    end

    describe '#recent_failed_logins' do
      it 'counts failed login attempts within rate limit window' do
        # Mock the dataset query
        mock_dataset = double('dataset')
        allow(ConnectionLog).to receive(:where).with(user_id: user.id, outcome: 'invalid_credentials').and_return(mock_dataset)
        allow(mock_dataset).to receive(:where).and_return(mock_dataset)
        allow(mock_dataset).to receive(:count).and_return(3)

        expect(user.recent_failed_logins).to eq(3)
      end
    end
  end

  describe 'password edge cases' do
    describe '.authenticate with invalid hash' do
      it 'returns nil for corrupted password_digest' do
        user = create(:user)
        # Corrupt the digest
        user.this.update(password_digest: 'not-a-valid-bcrypt-hash')
        result = User.authenticate(user.username, 'any_password')
        expect(result).to be_nil
      end

      it 'returns nil when password_digest is nil' do
        user = create(:user)
        user.this.update(password_digest: nil, password_hash: nil)
        result = User.authenticate(user.username, 'any_password')
        expect(result).to be_nil
      end
    end
  end

  describe 'username titlecasing edge cases' do
    it 'handles single word usernames' do
      user = create(:user, username: 'alice')
      expect(user.username).to eq('Alice')
    end

    it 'handles multiple spaces between words' do
      user = create(:user, username: 'john   doe')
      expect(user.username).to eq('John Doe')
    end

    it 'handles complex hyphenated names' do
      user = create(:user, username: 'mary-jane watson-smith')
      expect(user.username).to eq('Mary-Jane Watson-Smith')
    end
  end

  describe '#discord_settings' do
    let(:user) { create(:user) }

    it 'returns all discord settings as hash' do
      user.update(
        discord_webhook_url: 'https://example.com/webhook',
        discord_username: '@user1234',
        discord_notify_offline: true,
        discord_notify_online: false,
        discord_notify_memos: true,
        discord_notify_pms: false,
        discord_notify_mentions: true
      )

      settings = user.discord_settings
      expect(settings[:webhook_url]).to eq('https://example.com/webhook')
      expect(settings[:username]).to eq('@user1234')
      expect(settings[:notify_offline]).to be true
      expect(settings[:notify_online]).to be false
      expect(settings[:notify_memos]).to be true
      expect(settings[:notify_pms]).to be false
      expect(settings[:notify_mentions]).to be true
    end
  end

  describe 'convenience permission checks edge cases' do
    let(:user) { create(:user) }

    describe '#can_see_all_rp?' do
      it 'returns false by default' do
        expect(user.can_see_all_rp?).to be false
      end

      it 'returns true when permission granted' do
        user.grant_permission!('can_see_all_rp')
        expect(user.can_see_all_rp?).to be true
      end
    end

    describe '#can_go_invisible?' do
      it 'returns false by default' do
        expect(user.can_go_invisible?).to be false
      end

      it 'returns true when permission granted' do
        user.grant_permission!('can_go_invisible')
        expect(user.can_go_invisible?).to be true
      end
    end

    describe '#can_manage_users?' do
      it 'returns false by default' do
        expect(user.can_manage_users?).to be false
      end

      it 'returns true when permission granted' do
        user.grant_permission!('can_manage_users')
        expect(user.can_manage_users?).to be true
      end
    end

    describe '#can_manage_permissions?' do
      it 'returns false by default' do
        expect(user.can_manage_permissions?).to be false
      end

      it 'returns true when permission granted' do
        user.grant_permission!('can_manage_permissions')
        expect(user.can_manage_permissions?).to be true
      end
    end
  end

  describe '#has_permission? with nil permissions' do
    let(:user) { create(:user) }

    it 'returns false when permissions is nil' do
      user.this.update(permissions: nil)
      user.refresh
      expect(user.has_permission?('can_build')).to be false
    end
  end

  describe '#touch_api_token_usage!' do
    let(:user) { create(:user) }

    it 'updates api_token_last_used_at' do
      user.generate_api_token!
      user.touch_api_token_usage!
      expect(user[:api_token_last_used_at]).to be_within(1).of(Time.now)
    end
  end

  describe 'accessibility settings edge cases' do
    let(:user) { create(:user) }

    describe '#accessibility_settings includes all fields' do
      it 'includes reduced_visual_effects' do
        user.update(reduced_visual_effects: true)
        expect(user.accessibility_settings[:reduced_visual_effects]).to be true
      end

      it 'includes high_contrast_mode' do
        user.update(high_contrast_mode: true)
        expect(user.accessibility_settings[:high_contrast_mode]).to be true
      end
    end

    describe '#configure_accessibility! with nil values' do
      it 'does not update settings when nil is passed' do
        user.update(accessibility_mode: true)
        user.configure_accessibility!(mode: nil)
        expect(user.accessibility_mode?).to be true
      end
    end
  end

  # ========================================
  # Additional Edge Case Tests - Phase 2
  # ========================================

  describe 'narrator voice edge cases' do
    let(:user) { create(:user) }

    describe '#set_narrator_voice! clamping' do
      it 'clamps negative pitch to minimum' do
        user.set_narrator_voice!(type: 'Kore', pitch: -50.0)
        expect(user.narrator_voice_pitch).to eq(-20.0)
      end

      it 'clamps negative speed to minimum' do
        user.set_narrator_voice!(type: 'Kore', speed: 0.1)
        expect(user.narrator_voice_speed).to eq(0.25)
      end

      it 'allows boundary values within range' do
        user.set_narrator_voice!(type: 'Kore', pitch: -20.0, speed: 0.25)
        expect(user.narrator_voice_pitch).to eq(-20.0)
        expect(user.narrator_voice_speed).to eq(0.25)
      end

      it 'handles non-numeric pitch by converting to float' do
        user.set_narrator_voice!(type: 'Kore', pitch: '5')
        expect(user.narrator_voice_pitch).to eq(5.0)
      end
    end

    describe '#narrator_settings with custom values' do
      it 'returns customized settings after update' do
        user.set_narrator_voice!(type: 'Charon', pitch: -10.0, speed: 2.0)
        settings = user.narrator_settings
        expect(settings[:voice_type]).to eq('Charon')
        expect(settings[:voice_pitch]).to eq(-10.0)
        expect(settings[:voice_speed]).to eq(2.0)
      end
    end

    describe '#has_narrator_voice? edge cases' do
      it 'returns false for empty string voice type' do
        user.update(narrator_voice_type: '')
        expect(user.has_narrator_voice?).to be false
      end
    end
  end

  describe 'authentication edge cases' do
    describe '.authenticate with legacy password_hash' do
      it 'migrates password_hash to password_digest on successful auth' do
        user = create(:user)
        user.set_password('test_password')
        original_digest = user.password_digest

        # Simulate legacy state: password_hash set, password_digest nil
        user.this.update(password_hash: original_digest, password_digest: nil)
        user.refresh

        result = User.authenticate(user.username, 'test_password')
        expect(result&.id).to eq(user.id)
        user.refresh
        expect(user.password_digest).not_to be_nil
      end

      it 'handles whitespace in username/email input' do
        user = create(:user, username: 'TestUser', email: 'test@example.com')
        user.set_password('password')
        user.save

        result = User.authenticate('  TestUser  ', 'password')
        expect(result&.id).to eq(user.id)
      end
    end
  end

  describe 'email validation edge cases' do
    it 'validates email with plus sign' do
      user = build(:user, email: 'test+tag@example.com')
      expect(user.valid?).to be true
    end

    it 'validates email with dots in local part' do
      user = build(:user, email: 'test.user@example.com')
      expect(user.valid?).to be true
    end

    it 'accepts email with double dots (regex allows it)' do
      user = build(:user, email: 'test..user@example.com')
      # Note: Current regex [\w+\-.]+@ allows consecutive dots - documenting actual behavior
      expect(user.valid?).to be true
    end

    it 'rejects email without domain extension' do
      user = build(:user, email: 'test@example')
      expect(user.valid?).to be false
    end

    it 'rejects email with space' do
      user = build(:user, email: 'test user@example.com')
      expect(user.valid?).to be false
    end
  end

  describe 'suspension edge cases' do
    let(:user) { create(:user) }

    describe '#suspension_remaining edge cases' do
      it 'returns nil when suspension has expired (no longer suspended)' do
        user.suspend!(reason: 'Timeout', until_time: Time.now - 0.1)
        # suspended? returns false when suspension_until is in the past
        # so suspension_remaining returns nil (not suspended = no remaining time)
        expect(user.suspension_remaining).to be_nil
      end
    end

    describe '#suspend! return value' do
      it 'returns self for chaining' do
        result = user.suspend!(reason: 'Test')
        expect(result).to eq(user)
      end
    end

    describe '#unsuspend! return value' do
      it 'returns self for chaining' do
        user.suspend!(reason: 'Test')
        result = user.unsuspend!
        expect(result).to eq(user)
      end
    end
  end

  describe 'mute edge cases' do
    let(:user) { create(:user) }

    describe '#mute_remaining_seconds when expired' do
      it 'returns 0 when mute just expired' do
        user.this.update(muted_until: Time.now - 0.1)
        user.refresh
        expect(user.mute_remaining_seconds).to eq(0)
      end
    end
  end

  describe 'confirmation token edge cases' do
    let(:user) { create(:user) }

    describe '#confirm_email! with nil token' do
      it 'returns :invalid when user has no token' do
        expect(user.confirm_email!('some-token')).to eq(:invalid)
      end
    end

    describe '#confirmation_token_valid? edge cases' do
      it 'returns false when confirmation_token_created_at is nil' do
        user.generate_confirmation_token!
        user.update(confirmation_token_created_at: nil)
        expect(user.confirmation_token_valid?).to be false
      end
    end
  end

  describe 'password reset edge cases' do
    let(:user) { create(:user) }

    describe '#reset_password_with_token! with nil token' do
      it 'returns :invalid when user has no reset token' do
        expect(user.reset_password_with_token!('some-token', 'new_password')).to eq(:invalid)
      end
    end

    describe '#password_reset_token_valid? edge cases' do
      it 'returns false when password_reset_token_created_at is nil' do
        user.generate_password_reset_token!
        user.this.update(password_reset_token_created_at: nil)
        user.refresh
        expect(user.password_reset_token_valid?).to be false
      end
    end
  end

  describe 'playtime tracking edge cases' do
    let(:user) { create(:user) }

    describe '#total_playtime_hours edge cases' do
      it 'handles nil total_playtime_seconds' do
        user.this.update(total_playtime_seconds: nil)
        user.refresh
        expect(user.total_playtime_hours).to eq(0.0)
      end

      it 'handles fractional hours' do
        user.update(total_playtime_seconds: 5400) # 1.5 hours
        expect(user.total_playtime_hours).to eq(1.5)
      end
    end

    describe '#exempt_from_abuse_checks? edge cases' do
      it 'handles nil total_playtime_seconds' do
        user.this.update(total_playtime_seconds: nil)
        user.refresh
        expect(user.exempt_from_abuse_checks?).to be false
      end
    end

    describe '#increment_playtime! edge cases' do
      it 'returns self for chaining' do
        result = user.increment_playtime!(100)
        expect(result).to eq(user)
      end

      it 'handles zero value' do
        user.increment_playtime!(0)
        expect(user.total_playtime_seconds || 0).to eq(0)
      end
    end

    describe '#playtime_display edge cases' do
      it 'handles nil total_playtime_seconds' do
        user.this.update(total_playtime_seconds: nil)
        user.refresh
        expect(user.playtime_display).to eq('0h 0m')
      end

      it 'handles large playtime values' do
        user.update(total_playtime_seconds: 360_000) # 100 hours
        expect(user.playtime_display).to eq('100h 0m')
      end
    end
  end

  describe 'gradient preferences edge cases' do
    let(:user) { create(:user) }

    describe '#gradient_preferences setter' do
      it 'wraps hash values in JSONB' do
        user.gradient_preferences = { 'recent_gradients' => [1, 2, 3] }
        expect(user.gradient_preferences['recent_gradients']).to eq([1, 2, 3])
      end

      it 'passes through non-hash values' do
        # Already wrapped JSONB value
        wrapped = Sequel.pg_jsonb_wrap({ 'recent_gradients' => [1, 2] })
        user.gradient_preferences = wrapped
        # Should still work
        expect(user.recent_gradient_ids).to include(1, 2)
      end
    end

    describe '#recent_gradient_ids edge cases' do
      it 'limits result to 10 even if stored more' do
        prefs = { 'recent_gradients' => (1..20).to_a }
        user.this.update(gradient_preferences: Sequel.pg_jsonb_wrap(prefs))
        user.refresh
        expect(user.recent_gradient_ids.length).to eq(10)
      end
    end

    describe '#add_recent_gradient! edge cases' do
      it 'handles empty initial state' do
        user.this.update(gradient_preferences: nil)
        user.refresh
        user.add_recent_gradient!(42)
        expect(user.recent_gradient_ids).to eq([42])
      end
    end
  end

  describe 'API token edge cases' do
    let(:user) { create(:user) }

    describe '#api_token_valid? edge cases' do
      it 'returns false for empty string token' do
        user.generate_api_token!
        expect(user.api_token_valid?('')).to be false
      end

      it 'returns false when no digest stored' do
        expect(user.api_token_valid?('a' * 64)).to be false
      end
    end

    describe '.find_by_api_token edge cases' do
      it 'returns nil for empty string' do
        expect(User.find_by_api_token('')).to be_nil
      end

      it 'returns nil for malformed token (wrong length)' do
        expect(User.find_by_api_token('short')).to be_nil
      end

      it 'returns nil for malformed token (wrong format)' do
        expect(User.find_by_api_token('g' * 64)).to be_nil # 'g' not in hex
      end
    end
  end

  describe 'staff? edge cases' do
    let(:user) { create(:user) }

    it 'returns true for can_see_all_rp permission' do
      user.grant_permission!('can_see_all_rp')
      expect(user.staff?).to be true
    end

    it 'returns true for can_go_invisible permission' do
      user.grant_permission!('can_go_invisible')
      expect(user.staff?).to be true
    end

    it 'returns false when only has non-staff permissions' do
      user.grant_permission!('can_build')
      expect(user.staff?).to be false
    end
  end

  describe 'granted_permissions edge cases' do
    let(:user) { create(:user) }

    it 'returns empty array when permissions is nil' do
      user.this.update(permissions: nil)
      user.refresh
      expect(user.granted_permissions).to eq([])
    end

    it 'excludes false-valued permissions' do
      perms = { 'can_build' => true, 'can_moderate' => false }
      user.this.update(permissions: Sequel.pg_jsonb_wrap(perms))
      user.refresh
      expect(user.granted_permissions).to eq(['can_build'])
      expect(user.granted_permissions).not_to include('can_moderate')
    end
  end

  describe 'session and remember token edge cases' do
    let(:user) { create(:user) }

    describe '#remember_valid? edge cases' do
      it 'returns false when remember_created_at is nil' do
        user.generate_remember_token!
        user.update(remember_created_at: nil)
        expect(user.remember_valid?(user.remember_token)).to be false
      end
    end
  end

  describe 'configure_accessibility! edge cases' do
    let(:user) { create(:user) }

    it 'handles all settings at once' do
      user.configure_accessibility!(
        mode: true,
        screen_reader: true,
        pause_on_typing: false,
        auto_resume: false,
        reduced_effects: true,
        high_contrast: true
      )

      settings = user.accessibility_settings
      expect(settings[:accessibility_mode]).to be true
      expect(settings[:screen_reader_optimized]).to be true
      expect(settings[:tts_pause_on_typing]).to be false
      expect(settings[:tts_auto_resume]).to be false
      expect(settings[:reduced_visual_effects]).to be true
      expect(settings[:high_contrast_mode]).to be true
    end

    it 'does nothing when all values are nil' do
      user.update(accessibility_mode: true)
      user.configure_accessibility!
      expect(user.accessibility_mode?).to be true
    end
  end

  describe 'update_discord_settings! edge cases' do
    let(:user) { create(:user) }

    it 'handles empty settings hash' do
      original_url = user.discord_webhook_url
      user.update_discord_settings!({})
      expect(user.discord_webhook_url).to eq(original_url)
    end

    it 'allows clearing values' do
      user.update(discord_webhook_url: 'https://example.com/webhook')
      user.update_discord_settings!(webhook_url: nil)
      expect(user.discord_webhook_url).to be_nil
    end
  end

  describe 'first user auto-admin edge cases' do
    it 'does not make subsequent users admin' do
      # Ensure at least one user exists
      create(:user)

      second_user = User.new(username: 'SecondUser', email: 'second@example.com')
      second_user.set_password('password')
      second_user.save

      expect(second_user.admin?).to be false
    end
  end

  describe 'format_duration private method via mute_info' do
    let(:user) { create(:user) }

    it 'formats zero duration' do
      user.this.update(muted_until: Time.now + 0.5)
      user.refresh
      info = user.mute_info
      # With less than a second remaining, should show something reasonable
      expect(info[:remaining_display]).to be_a(String)
    end

    it 'formats hours and minutes' do
      user.mute!(3630) # 1 hour, 30 seconds
      info = user.mute_info
      expect(info[:remaining_display]).to include('1 hour')
    end

    it 'formats minutes and seconds' do
      user.mute!(125) # 2 minutes, 5 seconds
      info = user.mute_info
      expect(info[:remaining_display]).to include('minute')
    end

    it 'pluralizes correctly' do
      user.mute!(10800) # 3 hours - gives margin so it still shows "hours" plural
      info = user.mute_info
      # Will show "2 hours X minutes" after a second passes - still plural
      expect(info[:remaining_display]).to match(/hours/)
    end
  end

  describe 'email case insensitivity' do
    it 'checks uniqueness case-insensitively' do
      create(:user, email: 'Unique@Example.com')
      duplicate = build(:user, email: 'UNIQUE@EXAMPLE.COM')
      # Email gets downcased in before_save, so both become unique@example.com
      # This triggers either validation or DB constraint depending on timing
      expect { duplicate.save }.to raise_error(Sequel::Error)
    end
  end
end
