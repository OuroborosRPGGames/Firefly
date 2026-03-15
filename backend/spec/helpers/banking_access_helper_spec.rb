# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BankingAccessHelper do
  describe 'constants' do
    it 'defines MINIMUM_TRANSACTION_AMOUNT' do
      expect(described_class::MINIMUM_TRANSACTION_AMOUNT).to eq(5)
    end
  end

  # Create a test class that includes the helper
  let(:test_class) do
    Class.new do
      include BankingAccessHelper

      attr_accessor :location, :character_instance

      def initialize
        @location = nil
        @character_instance = nil
      end
    end
  end

  describe '#parse_amount' do
    let(:instance) { test_class.new }

    it 'returns max_amount for "all"' do
      expect(instance.parse_amount('all', 100)).to eq(100)
    end

    it 'returns max_amount for "ALL"' do
      expect(instance.parse_amount('ALL', 250)).to eq(250)
    end

    it 'returns integer for numeric string' do
      expect(instance.parse_amount('50', 100)).to eq(50)
    end

    it 'returns nil for non-numeric string' do
      expect(instance.parse_amount('abc', 100)).to be_nil
    end

    it 'returns nil for mixed string' do
      expect(instance.parse_amount('50abc', 100)).to be_nil
    end
  end

  describe 'module inclusion' do
    it 'provides has_bank_access? method' do
      instance = test_class.new
      expect(instance).to respond_to(:has_bank_access?)
    end

    it 'provides default_currency method' do
      instance = test_class.new
      expect(instance).to respond_to(:default_currency)
    end

    it 'provides find_or_create_bank_account method' do
      instance = test_class.new
      expect(instance).to respond_to(:find_or_create_bank_account)
    end

    it 'provides find_or_create_wallet method' do
      instance = test_class.new
      expect(instance).to respond_to(:find_or_create_wallet)
    end
  end
end
