# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldMemoryLocation do
  describe 'associations' do
    it 'belongs to world_memory' do
      expect(described_class.association_reflections[:world_memory]).not_to be_nil
    end

    it 'belongs to room' do
      expect(described_class.association_reflections[:room]).not_to be_nil
    end
  end

  describe 'validation' do
    it 'requires world_memory_id' do
      instance = described_class.new
      instance.values[:world_memory_id] = nil
      instance.values[:room_id] = 1
      expect(instance.valid?).to be false
    end

    it 'requires room_id' do
      instance = described_class.new
      instance.values[:world_memory_id] = 1
      instance.values[:room_id] = nil
      expect(instance.valid?).to be false
    end
  end
end
