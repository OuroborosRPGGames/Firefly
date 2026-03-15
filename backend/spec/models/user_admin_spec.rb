# frozen_string_literal: true

require 'spec_helper'

RSpec.describe User, 'admin and permission methods' do
  let(:user) { create(:user) }
  let(:admin_user) { create(:user, :admin) }

  describe '#admin?' do
    it 'returns true when is_admin is true' do
      expect(admin_user.admin?).to be true
    end

    it 'returns false when is_admin is false' do
      expect(user.admin?).to be false
    end

    it 'returns false when is_admin is nil' do
      user.update(is_admin: nil)
      expect(user.admin?).to be false
    end
  end

  describe '#has_permission?' do
    it 'returns true for any permission when user is admin' do
      expect(admin_user.has_permission?('can_create_staff_characters')).to be true
      expect(admin_user.has_permission?('can_build')).to be true
      expect(admin_user.has_permission?('nonexistent_permission')).to be true
    end

    it 'returns false when permission not granted' do
      expect(user.has_permission?('can_create_staff_characters')).to be false
    end

    it 'returns true when permission is granted' do
      user.grant_permission!('can_create_staff_characters')
      expect(user.has_permission?('can_create_staff_characters')).to be true
    end

    it 'handles string and symbol permission names' do
      user.grant_permission!(:can_build)
      expect(user.has_permission?('can_build')).to be true
      expect(user.has_permission?(:can_build)).to be true
    end

    it 'returns false when permissions is nil' do
      user.update(permissions: nil)
      expect(user.has_permission?('can_build')).to be false
    end
  end

  describe '#grant_permission!' do
    it 'grants a valid permission' do
      result = user.grant_permission!('can_build')
      expect(result).to be true
      expect(user.has_permission?('can_build')).to be true
    end

    it 'rejects invalid permission names' do
      result = user.grant_permission!('invalid_permission')
      expect(result).to be false
    end

    it 'persists the permission to database' do
      user.grant_permission!('can_moderate')
      user.reload
      expect(user.has_permission?('can_moderate')).to be true
    end

    it 'can grant multiple permissions' do
      user.grant_permission!('can_build')
      user.grant_permission!('can_moderate')
      expect(user.has_permission?('can_build')).to be true
      expect(user.has_permission?('can_moderate')).to be true
    end
  end

  describe '#revoke_permission!' do
    before { user.grant_permission!('can_build') }

    it 'revokes a permission' do
      user.revoke_permission!('can_build')
      expect(user.has_permission?('can_build')).to be false
    end

    it 'persists the revocation to database' do
      user.revoke_permission!('can_build')
      user.reload
      expect(user.has_permission?('can_build')).to be false
    end

    it 'does not affect other permissions' do
      user.grant_permission!('can_moderate')
      user.revoke_permission!('can_build')
      expect(user.has_permission?('can_moderate')).to be true
    end
  end

  describe '#granted_permissions' do
    it 'returns empty array for user with no permissions' do
      expect(user.granted_permissions).to eq([])
    end

    it 'returns list of granted permissions' do
      user.grant_permission!('can_build')
      user.grant_permission!('can_moderate')
      expect(user.granted_permissions).to include('can_build', 'can_moderate')
    end

    it 'returns all permissions for admin user' do
      expect(admin_user.granted_permissions).to eq(Permission.all)
    end
  end

  describe 'first user auto-admin' do
    before do
      # Clear all users for this test
      User.dataset.delete
    end

    it 'makes the first user an admin' do
      first_user = User.new(username: 'first', email: 'first@example.com')
      first_user.set_password('password')
      first_user.save
      expect(first_user.is_admin).to be true
    end

    it 'does not make subsequent users admin' do
      first_user = User.new(username: 'first', email: 'first@example.com')
      first_user.set_password('password')
      first_user.save

      second_user = User.new(username: 'second', email: 'second@example.com')
      second_user.set_password('password')
      second_user.save

      expect(second_user.is_admin).to be false
    end
  end

  describe 'convenience permission methods' do
    it '#can_access_admin_console? checks the correct permission' do
      expect(user.can_access_admin_console?).to be false
      user.grant_permission!('can_access_admin_console')
      expect(user.can_access_admin_console?).to be true
    end

    it '#can_create_staff_characters? checks the correct permission' do
      expect(user.can_create_staff_characters?).to be false
      user.grant_permission!('can_create_staff_characters')
      expect(user.can_create_staff_characters?).to be true
    end

    it '#can_see_all_rp? checks the correct permission' do
      expect(user.can_see_all_rp?).to be false
      user.grant_permission!('can_see_all_rp')
      expect(user.can_see_all_rp?).to be true
    end

    it '#can_go_invisible? checks the correct permission' do
      expect(user.can_go_invisible?).to be false
      user.grant_permission!('can_go_invisible')
      expect(user.can_go_invisible?).to be true
    end

    it '#staff? returns true for users with staff permissions' do
      expect(user.staff?).to be false
      user.grant_permission!('can_create_staff_characters')
      expect(user.staff?).to be true
    end

    it '#staff? returns true for admins' do
      expect(admin_user.staff?).to be true
    end
  end
end
