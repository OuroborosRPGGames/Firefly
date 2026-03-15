# frozen_string_literal: true

require 'spec_helper'

RSpec.describe WorldMemoryNpc do
  let(:world_memory) { create(:world_memory) }
  let(:npc_character) { create(:character, :npc) }

  describe 'validations' do
    it 'requires world_memory_id' do
      link = WorldMemoryNpc.new(character_id: npc_character.id)
      expect(link.valid?).to be false
      expect(link.errors[:world_memory_id]).not_to be_empty
    end

    it 'requires character_id' do
      link = WorldMemoryNpc.new(world_memory_id: world_memory.id)
      expect(link.valid?).to be false
      expect(link.errors[:character_id]).not_to be_empty
    end

    it 'validates role is one of the allowed values' do
      link = WorldMemoryNpc.new(
        world_memory_id: world_memory.id,
        character_id: npc_character.id,
        role: 'invalid'
      )
      expect(link.valid?).to be false
      expect(link.errors[:role]).not_to be_empty
    end

    it 'accepts valid roles' do
      WorldMemoryNpc::ROLES.each do |role|
        link = WorldMemoryNpc.new(
          world_memory_id: world_memory.id,
          character_id: npc_character.id,
          role: role
        )
        expect(link.valid?).to be true
      end
    end

    it 'defaults role to involved' do
      link = WorldMemoryNpc.create(
        world_memory_id: world_memory.id,
        character_id: npc_character.id
      )
      expect(link.role).to eq 'involved'
    end
  end

  describe 'associations' do
    let(:link) do
      WorldMemoryNpc.create(
        world_memory_id: world_memory.id,
        character_id: npc_character.id,
        role: 'spawned'
      )
    end

    it 'belongs to world_memory' do
      expect(link.world_memory).to eq world_memory
    end

    it 'belongs to character' do
      expect(link.character).to eq npc_character
    end
  end

  describe '.for_npc' do
    let!(:link1) do
      WorldMemoryNpc.create(
        world_memory_id: world_memory.id,
        character_id: npc_character.id
      )
    end
    let!(:link2) do
      another_memory = create(:world_memory)
      WorldMemoryNpc.create(
        world_memory_id: another_memory.id,
        character_id: npc_character.id
      )
    end
    let!(:other_npc_link) do
      other_npc = create(:character, :npc)
      WorldMemoryNpc.create(
        world_memory_id: world_memory.id,
        character_id: other_npc.id
      )
    end

    it 'returns all links for a specific NPC' do
      results = WorldMemoryNpc.for_npc(npc_character.id).all
      expect(results.size).to eq 2
      expect(results).to include(link1, link2)
      expect(results).not_to include(other_npc_link)
    end
  end

  describe '.for_memory' do
    let(:another_npc) { create(:character, :npc) }
    let!(:link1) do
      WorldMemoryNpc.create(
        world_memory_id: world_memory.id,
        character_id: npc_character.id
      )
    end
    let!(:link2) do
      WorldMemoryNpc.create(
        world_memory_id: world_memory.id,
        character_id: another_npc.id
      )
    end

    it 'returns all NPC links for a specific memory' do
      results = WorldMemoryNpc.for_memory(world_memory.id).all
      expect(results.size).to eq 2
      expect(results).to include(link1, link2)
    end
  end

  describe '.unabstracted_memories_for_npc' do
    let(:another_npc) { create(:character, :npc) }
    let!(:memory1) { create(:world_memory, abstraction_level: 1) }
    let!(:memory2) { create(:world_memory, abstraction_level: 1) }
    let!(:memory3) { create(:world_memory, abstraction_level: 2) }
    let!(:link1) do
      WorldMemoryNpc.create(world_memory_id: memory1.id, character_id: npc_character.id)
    end
    let!(:link2) do
      WorldMemoryNpc.create(world_memory_id: memory2.id, character_id: npc_character.id)
    end
    let!(:link3) do
      WorldMemoryNpc.create(world_memory_id: memory3.id, character_id: npc_character.id)
    end

    it 'returns unabstracted memories at the specified level' do
      results = WorldMemoryNpc.unabstracted_memories_for_npc(npc_character.id, 1).all
      expect(results).to include(memory1, memory2)
      expect(results).not_to include(memory3)
    end

    it 'excludes already-abstracted memories' do
      # Create an abstraction record for memory1
      target_memory = create(:world_memory, abstraction_level: 2)
      WorldMemoryAbstraction.create(
        source_memory_id: memory1.id,
        target_memory_id: target_memory.id,
        branch_type: 'npc',
        branch_reference_id: npc_character.id
      )

      results = WorldMemoryNpc.unabstracted_memories_for_npc(npc_character.id, 1).all
      expect(results).not_to include(memory1)
      expect(results).to include(memory2)
    end
  end

  describe 'ROLES' do
    it 'includes expected roles' do
      expect(WorldMemoryNpc::ROLES).to eq %w[involved spawned mentioned]
    end
  end
end
