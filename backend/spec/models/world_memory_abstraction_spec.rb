# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldMemoryAbstraction do
  let(:source_memory) { create(:world_memory, abstraction_level: 1) }
  let(:target_memory) { create(:world_memory, abstraction_level: 2) }

  describe 'validations' do
    it 'requires source_memory_id' do
      abstraction = WorldMemoryAbstraction.new(
        target_memory_id: target_memory.id,
        branch_type: 'location'
      )
      expect(abstraction.valid?).to be false
      expect(abstraction.errors[:source_memory_id]).not_to be_empty
    end

    it 'requires target_memory_id' do
      abstraction = WorldMemoryAbstraction.new(
        source_memory_id: source_memory.id,
        branch_type: 'location'
      )
      expect(abstraction.valid?).to be false
      expect(abstraction.errors[:target_memory_id]).not_to be_empty
    end

    it 'requires branch_type' do
      abstraction = WorldMemoryAbstraction.new(
        source_memory_id: source_memory.id,
        target_memory_id: target_memory.id
      )
      expect(abstraction.valid?).to be false
      expect(abstraction.errors[:branch_type]).not_to be_empty
    end

    it 'validates branch_type is one of the allowed values' do
      abstraction = WorldMemoryAbstraction.new(
        source_memory_id: source_memory.id,
        target_memory_id: target_memory.id,
        branch_type: 'invalid'
      )
      expect(abstraction.valid?).to be false
      expect(abstraction.errors[:branch_type]).not_to be_empty
    end

    it 'accepts valid branch_types' do
      WorldMemoryAbstraction::BRANCH_TYPES.each do |branch_type|
        abstraction = WorldMemoryAbstraction.new(
          source_memory_id: source_memory.id,
          target_memory_id: target_memory.id,
          branch_type: branch_type
        )
        expect(abstraction.valid?).to be true
      end
    end
  end

  describe 'associations' do
    let(:abstraction) do
      WorldMemoryAbstraction.create(
        source_memory_id: source_memory.id,
        target_memory_id: target_memory.id,
        branch_type: 'location'
      )
    end

    it 'belongs to source_memory' do
      expect(abstraction.source_memory).to eq source_memory
    end

    it 'belongs to target_memory' do
      expect(abstraction.target_memory).to eq target_memory
    end
  end

  describe '.for_branch' do
    let(:room) { create(:room) }
    let!(:location_abstraction) do
      WorldMemoryAbstraction.create(
        source_memory_id: source_memory.id,
        target_memory_id: target_memory.id,
        branch_type: 'location',
        branch_reference_id: room.id
      )
    end
    let!(:character_abstraction) do
      another_source = create(:world_memory, abstraction_level: 1)
      another_target = create(:world_memory, abstraction_level: 2)
      WorldMemoryAbstraction.create(
        source_memory_id: another_source.id,
        target_memory_id: another_target.id,
        branch_type: 'character',
        branch_reference_id: 999
      )
    end

    it 'returns abstractions for a specific branch type' do
      results = WorldMemoryAbstraction.for_branch('location').all
      expect(results).to include(location_abstraction)
      expect(results).not_to include(character_abstraction)
    end

    it 'filters by reference_id when provided' do
      results = WorldMemoryAbstraction.for_branch('location', room.id).all
      expect(results).to include(location_abstraction)
    end

    it 'returns empty for non-matching reference_id' do
      results = WorldMemoryAbstraction.for_branch('location', 0).all
      expect(results).to be_empty
    end
  end

  describe '.sources_for' do
    let!(:abstraction1) do
      WorldMemoryAbstraction.create(
        source_memory_id: source_memory.id,
        target_memory_id: target_memory.id,
        branch_type: 'location'
      )
    end
    let!(:abstraction2) do
      another_source = create(:world_memory, abstraction_level: 1)
      WorldMemoryAbstraction.create(
        source_memory_id: another_source.id,
        target_memory_id: target_memory.id,
        branch_type: 'character'
      )
    end

    it 'returns all sources for a target memory' do
      results = WorldMemoryAbstraction.sources_for(target_memory.id).all
      expect(results.size).to eq 2
      expect(results).to include(abstraction1, abstraction2)
    end
  end

  describe '.targets_for' do
    let(:another_target) { create(:world_memory, abstraction_level: 2) }
    let!(:abstraction1) do
      WorldMemoryAbstraction.create(
        source_memory_id: source_memory.id,
        target_memory_id: target_memory.id,
        branch_type: 'location'
      )
    end
    let!(:abstraction2) do
      WorldMemoryAbstraction.create(
        source_memory_id: source_memory.id,
        target_memory_id: another_target.id,
        branch_type: 'character'
      )
    end

    it 'returns all targets for a source memory' do
      results = WorldMemoryAbstraction.targets_for(source_memory.id).all
      expect(results.size).to eq 2
      expect(results).to include(abstraction1, abstraction2)
    end
  end

  describe 'BRANCH_TYPES' do
    it 'includes expected types' do
      expect(WorldMemoryAbstraction::BRANCH_TYPES).to include(
        'location', 'character', 'npc', 'lore', 'global'
      )
    end
  end
end
