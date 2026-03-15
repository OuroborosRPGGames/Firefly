# frozen_string_literal: true

require 'spec_helper'

RSpec.describe IpBan do
  describe 'associations' do
    it 'belongs to created_by_user' do
      expect(described_class.association_reflections[:created_by_user]).not_to be_nil
    end
  end

  describe 'constants' do
    it 'defines BAN_TYPES' do
      expect(described_class::BAN_TYPES).to include('permanent', 'temporary')
    end
  end

  describe 'instance methods' do
    it 'defines matches_ip?' do
      expect(described_class.instance_methods).to include(:matches_ip?)
    end

    it 'defines expired?' do
      expect(described_class.instance_methods).to include(:expired?)
    end

    it 'defines permanent?' do
      expect(described_class.instance_methods).to include(:permanent?)
    end

    it 'defines deactivate!' do
      expect(described_class.instance_methods).to include(:deactivate!)
    end

    it 'defines to_admin_hash' do
      expect(described_class.instance_methods).to include(:to_admin_hash)
    end
  end

  describe 'class methods' do
    it 'defines banned?' do
      expect(described_class).to respond_to(:banned?)
    end

    it 'defines active_bans' do
      expect(described_class).to respond_to(:active_bans)
    end

    it 'defines ban_ip!' do
      expect(described_class).to respond_to(:ban_ip!)
    end

    it 'defines find_matching_ban' do
      expect(described_class).to respond_to(:find_matching_ban)
    end
  end

  describe '#matches_ip? behavior' do
    it 'returns true for exact match' do
      ban = described_class.new
      ban.values[:ip_pattern] = '192.168.1.100'
      expect(ban.matches_ip?('192.168.1.100')).to be true
    end

    it 'returns false for non-matching IP' do
      ban = described_class.new
      ban.values[:ip_pattern] = '192.168.1.100'
      expect(ban.matches_ip?('192.168.1.101')).to be false
    end

    it 'returns false for nil IP' do
      ban = described_class.new
      ban.values[:ip_pattern] = '192.168.1.100'
      expect(ban.matches_ip?(nil)).to be false
    end

    it 'returns false for empty IP' do
      ban = described_class.new
      ban.values[:ip_pattern] = '192.168.1.100'
      expect(ban.matches_ip?('')).to be false
    end
  end

  describe '#expired? behavior' do
    it 'returns false when expires_at is nil' do
      ban = described_class.new
      ban.values[:expires_at] = nil
      expect(ban.expired?).to be false
    end

    it 'returns true when expires_at is in the past' do
      ban = described_class.new
      ban.values[:expires_at] = Time.now - 3600
      expect(ban.expired?).to be true
    end
  end

  describe '#permanent? behavior' do
    it 'returns true when ban_type is permanent' do
      ban = described_class.new
      ban.values[:ban_type] = 'permanent'
      expect(ban.permanent?).to be true
    end

    it 'returns true when expires_at is nil' do
      ban = described_class.new
      ban.values[:ban_type] = 'temporary'
      ban.values[:expires_at] = nil
      expect(ban.permanent?).to be true
    end
  end
end
