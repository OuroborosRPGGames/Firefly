# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ItemBodyPosition do
  describe 'associations' do
    it 'belongs to an item' do
      expect(described_class.association_reflections[:item]).not_to be_nil
    end

    it 'belongs to a body_position' do
      expect(described_class.association_reflections[:body_position]).not_to be_nil
    end
  end

  describe '#covers?' do
    it 'returns true when covers is true' do
      record = described_class.new
      record.values[:covers] = true
      expect(record.covers?).to be true
    end

    it 'returns false when covers is false' do
      record = described_class.new
      record.values[:covers] = false
      expect(record.covers?).to be false
    end
  end

  describe '#reveals?' do
    it 'returns false when covers is true' do
      record = described_class.new
      record.values[:covers] = true
      expect(record.reveals?).to be false
    end

    it 'returns true when covers is false' do
      record = described_class.new
      record.values[:covers] = false
      expect(record.reveals?).to be true
    end
  end
end
