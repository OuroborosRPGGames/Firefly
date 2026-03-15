# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldMemoryLore do
  let(:world_memory) { create(:world_memory) }
  let(:helpfile) { create(:helpfile, topic: 'Dragon Lore', category: 'lore') }

  describe 'validations' do
    it 'requires world_memory_id' do
      link = WorldMemoryLore.new(helpfile_id: helpfile.id)
      expect(link.valid?).to be false
      expect(link.errors[:world_memory_id]).not_to be_empty
    end

    it 'requires helpfile_id' do
      link = WorldMemoryLore.new(world_memory_id: world_memory.id)
      expect(link.valid?).to be false
      expect(link.errors[:helpfile_id]).not_to be_empty
    end

    it 'validates reference_type is one of the allowed values' do
      link = WorldMemoryLore.new(
        world_memory_id: world_memory.id,
        helpfile_id: helpfile.id,
        reference_type: 'invalid'
      )
      expect(link.valid?).to be false
      expect(link.errors[:reference_type]).not_to be_empty
    end

    it 'accepts valid reference_types' do
      WorldMemoryLore::REFERENCE_TYPES.each do |ref_type|
        link = WorldMemoryLore.new(
          world_memory_id: world_memory.id,
          helpfile_id: helpfile.id,
          reference_type: ref_type
        )
        expect(link.valid?).to be true
      end
    end

    it 'defaults reference_type to mentioned' do
      link = WorldMemoryLore.create(
        world_memory_id: world_memory.id,
        helpfile_id: helpfile.id
      )
      expect(link.reference_type).to eq 'mentioned'
    end
  end

  describe 'associations' do
    let(:link) do
      WorldMemoryLore.create(
        world_memory_id: world_memory.id,
        helpfile_id: helpfile.id,
        reference_type: 'central'
      )
    end

    it 'belongs to world_memory' do
      expect(link.world_memory).to eq world_memory
    end

    it 'belongs to helpfile' do
      expect(link.helpfile).to eq helpfile
    end
  end

  describe '.for_helpfile' do
    let!(:link1) do
      WorldMemoryLore.create(
        world_memory_id: world_memory.id,
        helpfile_id: helpfile.id
      )
    end
    let!(:link2) do
      another_memory = create(:world_memory)
      WorldMemoryLore.create(
        world_memory_id: another_memory.id,
        helpfile_id: helpfile.id
      )
    end
    let!(:other_helpfile_link) do
      other_helpfile = create(:helpfile, topic: 'Other Lore', category: 'lore')
      WorldMemoryLore.create(
        world_memory_id: world_memory.id,
        helpfile_id: other_helpfile.id
      )
    end

    it 'returns all links for a specific helpfile' do
      results = WorldMemoryLore.for_helpfile(helpfile.id).all
      expect(results.size).to eq 2
      expect(results).to include(link1, link2)
      expect(results).not_to include(other_helpfile_link)
    end
  end

  describe '.for_memory' do
    let(:another_helpfile) { create(:helpfile, topic: 'Another Topic', category: 'lore') }
    let!(:link1) do
      WorldMemoryLore.create(
        world_memory_id: world_memory.id,
        helpfile_id: helpfile.id
      )
    end
    let!(:link2) do
      WorldMemoryLore.create(
        world_memory_id: world_memory.id,
        helpfile_id: another_helpfile.id
      )
    end

    it 'returns all lore links for a specific memory' do
      results = WorldMemoryLore.for_memory(world_memory.id).all
      expect(results.size).to eq 2
      expect(results).to include(link1, link2)
    end
  end

  describe '.unabstracted_memories_for_lore' do
    let(:another_helpfile) { create(:helpfile, topic: 'Another Topic', category: 'lore') }
    let!(:memory1) { create(:world_memory, abstraction_level: 1) }
    let!(:memory2) { create(:world_memory, abstraction_level: 1) }
    let!(:memory3) { create(:world_memory, abstraction_level: 2) }
    let!(:link1) do
      WorldMemoryLore.create(world_memory_id: memory1.id, helpfile_id: helpfile.id)
    end
    let!(:link2) do
      WorldMemoryLore.create(world_memory_id: memory2.id, helpfile_id: helpfile.id)
    end
    let!(:link3) do
      WorldMemoryLore.create(world_memory_id: memory3.id, helpfile_id: helpfile.id)
    end

    it 'returns unabstracted memories at the specified level' do
      results = WorldMemoryLore.unabstracted_memories_for_lore(helpfile.id, 1).all
      expect(results).to include(memory1, memory2)
      expect(results).not_to include(memory3)
    end

    it 'excludes already-abstracted memories' do
      # Create an abstraction record for memory1
      target_memory = create(:world_memory, abstraction_level: 2)
      WorldMemoryAbstraction.create(
        source_memory_id: memory1.id,
        target_memory_id: target_memory.id,
        branch_type: 'lore',
        branch_reference_id: helpfile.id
      )

      results = WorldMemoryLore.unabstracted_memories_for_lore(helpfile.id, 1).all
      expect(results).not_to include(memory1)
      expect(results).to include(memory2)
    end
  end

  describe 'REFERENCE_TYPES' do
    it 'includes expected types' do
      expect(WorldMemoryLore::REFERENCE_TYPES).to eq %w[mentioned central background]
    end
  end
end
