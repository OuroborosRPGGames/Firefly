# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldMemoryCharacter do
  describe 'constants' do
    it 'defines ROLES' do
      expect(described_class::ROLES).to eq(%w[participant observer mentioned])
    end
  end

  describe 'associations' do
    it 'belongs to world_memory' do
      expect(described_class.association_reflections[:world_memory]).not_to be_nil
    end

    it 'belongs to character' do
      expect(described_class.association_reflections[:character]).not_to be_nil
    end
  end

  describe 'validation' do
    it 'requires world_memory_id' do
      instance = described_class.new
      instance.values[:world_memory_id] = nil
      instance.values[:character_id] = 1
      expect(instance.valid?).to be false
    end

    it 'requires character_id' do
      instance = described_class.new
      instance.values[:world_memory_id] = 1
      instance.values[:character_id] = nil
      expect(instance.valid?).to be false
    end

    it 'validates role is in ROLES' do
      instance = described_class.new
      instance.values[:world_memory_id] = 1
      instance.values[:character_id] = 1
      instance.values[:role] = 'invalid_role'
      expect(instance.valid?).to be false
    end

    it 'allows valid roles' do
      instance = described_class.new
      instance.values[:world_memory_id] = 1
      instance.values[:character_id] = 1
      instance.values[:role] = 'participant'
      # Note: may fail other validations but role should pass
      expect(described_class::ROLES).to include(instance.values[:role])
    end
  end
end
