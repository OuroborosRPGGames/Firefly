# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Permission do
  describe 'PERMISSIONS constant' do
    it 'contains all expected permissions' do
      expected = %w[
        can_create_staff_characters
        can_see_all_rp
        can_go_invisible
        can_access_admin_console
        can_manage_users
        can_manage_permissions
        can_manage_npcs
        can_build
        can_moderate
      ]
      expect(Permission::PERMISSIONS.keys).to match_array(expected)
    end

    it 'each permission has name, description, and category' do
      Permission::PERMISSIONS.each do |key, value|
        expect(value).to have_key(:name), "#{key} missing :name"
        expect(value).to have_key(:description), "#{key} missing :description"
        expect(value).to have_key(:category), "#{key} missing :category"
      end
    end
  end

  describe '.all' do
    it 'returns all permission keys' do
      expect(Permission.all).to eq(Permission::PERMISSIONS.keys)
    end
  end

  describe '.valid?' do
    it 'returns true for valid permission strings' do
      expect(Permission.valid?('can_build')).to be true
    end

    it 'returns true for valid permission symbols' do
      expect(Permission.valid?(:can_build)).to be true
    end

    it 'returns false for invalid permissions' do
      expect(Permission.valid?('invalid_permission')).to be false
      expect(Permission.valid?(:invalid_permission)).to be false
    end
  end

  describe '.info' do
    it 'returns permission info for valid permission' do
      info = Permission.info('can_build')
      expect(info[:name]).to eq('Build')
      expect(info[:category]).to eq(:world)
    end

    it 'returns nil for invalid permission' do
      expect(Permission.info('invalid')).to be_nil
    end
  end

  describe '.by_category' do
    it 'groups permissions by category' do
      by_category = Permission.by_category
      expect(by_category).to be_a(Hash)
      expect(by_category.keys).to include(:staff, :admin, :world, :moderation)
    end
  end
end
