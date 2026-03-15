# frozen_string_literal: true

require 'spec_helper'

RSpec.describe StaffBroadcast do
  describe 'associations' do
    it 'belongs to created_by_user' do
      expect(described_class.association_reflections[:created_by_user]).not_to be_nil
    end

    it 'has many staff_broadcast_deliveries' do
      expect(described_class.association_reflections[:staff_broadcast_deliveries]).not_to be_nil
    end
  end

  describe 'instance methods' do
    it 'defines deliver!' do
      expect(described_class.instance_methods).to include(:deliver!)
    end

    it 'defines formatted_message' do
      expect(described_class.instance_methods).to include(:formatted_message)
    end

    it 'defines delivered_to?' do
      expect(described_class.instance_methods).to include(:delivered_to?)
    end

    it 'defines delivery_count' do
      expect(described_class.instance_methods).to include(:delivery_count)
    end

    it 'defines online_delivery_count' do
      expect(described_class.instance_methods).to include(:online_delivery_count)
    end

    it 'defines login_delivery_count' do
      expect(described_class.instance_methods).to include(:login_delivery_count)
    end
  end

  describe 'class methods' do
    it 'defines undelivered_for' do
      expect(described_class).to respond_to(:undelivered_for)
    end
  end

  describe '#formatted_message behavior' do
    it 'returns hash with content and html' do
      broadcast = described_class.new
      broadcast.values[:content] = 'Server restart in 5 minutes'
      result = broadcast.formatted_message
      expect(result).to be_a(Hash)
      expect(result[:content]).to include('[BROADCAST]')
      expect(result[:html]).to include('broadcast-message')
    end
  end

  describe '.undelivered_for behavior' do
    it 'returns empty array for nil character_instance' do
      expect(described_class.undelivered_for(nil)).to eq([])
    end
  end
end
