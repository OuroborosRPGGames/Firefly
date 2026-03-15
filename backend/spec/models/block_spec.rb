# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Block do
  # Note: The Block model references columns/associations that may not exist in the DB schema
  # These tests focus on what's testable

  describe 'associations' do
    it 'has blocker_user association' do
      expect(described_class.association_reflections[:blocker_user]).not_to be_nil
    end

    it 'has blocked_user association' do
      expect(described_class.association_reflections[:blocked_user]).not_to be_nil
    end
  end

  describe '#ooc?' do
    it 'returns true when block_type is ooc' do
      block = described_class.new
      block.values[:block_type] = 'ooc'
      expect(block.ooc?).to be true
    end

    it 'returns false when block_type is ic' do
      block = described_class.new
      block.values[:block_type] = 'ic'
      expect(block.ooc?).to be false
    end
  end

  describe '#ic?' do
    it 'returns true when block_type is ic' do
      block = described_class.new
      block.values[:block_type] = 'ic'
      expect(block.ic?).to be true
    end

    it 'returns false when block_type is ooc' do
      block = described_class.new
      block.values[:block_type] = 'ooc'
      expect(block.ic?).to be false
    end
  end

  describe 'constants' do
    it 'has BLOCK_TYPES constant' do
      expect(described_class::BLOCK_TYPES).to eq(%w[ooc ic])
    end
  end
end
