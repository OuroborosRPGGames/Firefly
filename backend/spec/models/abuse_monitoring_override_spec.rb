# frozen_string_literal: true

require 'spec_helper'

RSpec.describe AbuseMonitoringOverride do
  describe 'associations' do
    it 'belongs to triggered_by_user' do
      expect(described_class.association_reflections[:triggered_by_user]).not_to be_nil
    end
  end

  describe 'constants' do
    it 'defines DEFAULT_DURATION_SECONDS' do
      expect(described_class::DEFAULT_DURATION_SECONDS).to eq(3600)
    end
  end

  describe 'instance methods' do
    it 'defines deactivate!' do
      expect(described_class.instance_methods).to include(:deactivate!)
    end

    it 'defines remaining_seconds' do
      expect(described_class.instance_methods).to include(:remaining_seconds)
    end

    it 'defines expired?' do
      expect(described_class.instance_methods).to include(:expired?)
    end

    it 'defines to_admin_hash' do
      expect(described_class.instance_methods).to include(:to_admin_hash)
    end
  end

  describe 'class methods' do
    it 'defines active?' do
      expect(described_class).to respond_to(:active?)
    end

    it 'defines current' do
      expect(described_class).to respond_to(:current)
    end

    it 'defines activate!' do
      expect(described_class).to respond_to(:activate!)
    end

    it 'defines expire_all!' do
      expect(described_class).to respond_to(:expire_all!)
    end
  end

  describe '#expired? behavior' do
    it 'returns true when active_until is in the past' do
      override = described_class.new
      override.values[:active_until] = Time.now - 3600
      expect(override.expired?).to be true
    end

    it 'returns false when active_until is in the future' do
      override = described_class.new
      override.values[:active_until] = Time.now + 3600
      expect(override.expired?).to be false
    end
  end

  describe '#remaining_seconds behavior' do
    it 'returns nil when not active' do
      override = described_class.new
      override.values[:active] = false
      override.values[:active_until] = Time.now + 3600
      expect(override.remaining_seconds).to be_nil
    end

    it 'returns 0 when expired' do
      override = described_class.new
      override.values[:active] = true
      override.values[:active_until] = Time.now - 100
      expect(override.remaining_seconds).to eq(0)
    end
  end
end
