# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ModerationAction do
  describe 'associations' do
    it 'belongs to user' do
      expect(described_class.association_reflections[:user]).not_to be_nil
    end

    it 'belongs to abuse_check' do
      expect(described_class.association_reflections[:abuse_check]).not_to be_nil
    end

    it 'belongs to triggered_by_user' do
      expect(described_class.association_reflections[:triggered_by_user]).not_to be_nil
    end

    it 'belongs to reversed_by_user' do
      expect(described_class.association_reflections[:reversed_by_user]).not_to be_nil
    end
  end

  describe 'constants' do
    it 'defines ACTION_TYPES' do
      expect(described_class::ACTION_TYPES).to include('ip_ban', 'range_ban', 'suspend', 'logout', 'warn')
    end

    it 'defines TRIGGER_TYPES' do
      expect(described_class::TRIGGER_TYPES).to include('auto_moderation', 'staff', 'system')
    end
  end

  describe 'instance methods' do
    it 'defines reverse!' do
      expect(described_class.instance_methods).to include(:reverse!)
    end

    it 'defines active?' do
      expect(described_class.instance_methods).to include(:active?)
    end

    it 'defines expired?' do
      expect(described_class.instance_methods).to include(:expired?)
    end

    it 'defines to_admin_hash' do
      expect(described_class.instance_methods).to include(:to_admin_hash)
    end
  end

  describe 'class methods' do
    it 'defines create_ip_ban' do
      expect(described_class).to respond_to(:create_ip_ban)
    end

    it 'defines create_range_ban' do
      expect(described_class).to respond_to(:create_range_ban)
    end

    it 'defines create_suspension' do
      expect(described_class).to respond_to(:create_suspension)
    end

    it 'defines create_logout' do
      expect(described_class).to respond_to(:create_logout)
    end

    it 'defines create_registration_freeze' do
      expect(described_class).to respond_to(:create_registration_freeze)
    end

    it 'defines recent_for_user' do
      expect(described_class).to respond_to(:recent_for_user)
    end

    it 'defines recent_auto_actions' do
      expect(described_class).to respond_to(:recent_auto_actions)
    end
  end

  describe '#active? behavior' do
    it 'returns false when reversed' do
      action = described_class.new
      action.values[:reversed] = true
      action.values[:expires_at] = Time.now + 3600
      expect(action.active?).to be false
    end

    it 'returns true when not reversed and not expired' do
      action = described_class.new
      action.values[:reversed] = false
      action.values[:expires_at] = Time.now + 3600
      expect(action.active?).to be true
    end

    it 'returns true when not reversed and no expiry' do
      action = described_class.new
      action.values[:reversed] = false
      action.values[:expires_at] = nil
      expect(action.active?).to be true
    end
  end

  describe '#expired? behavior' do
    it 'returns false when expires_at is nil' do
      action = described_class.new
      action.values[:expires_at] = nil
      expect(action.expired?).to be false
    end

    it 'returns true when expires_at is in the past' do
      action = described_class.new
      action.values[:expires_at] = Time.now - 3600
      expect(action.expired?).to be true
    end
  end
end
