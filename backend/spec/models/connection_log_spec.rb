# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ConnectionLog do
  describe 'associations' do
    it 'belongs to user' do
      expect(described_class.association_reflections[:user]).not_to be_nil
    end
  end

  describe 'constants' do
    it 'defines CONNECTION_TYPES' do
      expect(described_class::CONNECTION_TYPES).to include('web_login', 'api_auth', 'websocket')
    end

    it 'defines OUTCOMES' do
      expect(described_class::OUTCOMES).to include('success', 'banned_ip', 'suspended', 'invalid_credentials')
    end
  end

  describe 'instance methods' do
    it 'defines to_admin_hash' do
      expect(described_class.instance_methods).to include(:to_admin_hash)
    end
  end

  describe 'class methods' do
    it 'defines log_connection' do
      expect(described_class).to respond_to(:log_connection)
    end

    it 'defines recent_for_user' do
      expect(described_class).to respond_to(:recent_for_user)
    end

    it 'defines recent_for_ip' do
      expect(described_class).to respond_to(:recent_for_ip)
    end

    it 'defines unique_ips_for_user' do
      expect(described_class).to respond_to(:unique_ips_for_user)
    end

    it 'defines users_from_ip' do
      expect(described_class).to respond_to(:users_from_ip)
    end

    it 'defines recent_failed_attempts' do
      expect(described_class).to respond_to(:recent_failed_attempts)
    end

    it 'defines cleanup_old_logs!' do
      expect(described_class).to respond_to(:cleanup_old_logs!)
    end
  end
end
