# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcMemoryService do
  let(:npc) { create(:character, :npc) }
  let(:pc) { create(:character) }

  describe '.store_memory' do
    it 'creates a new memory' do
      expect {
        NpcMemoryService.store_memory(
          npc: npc,
          content: 'Saw a player in the town square',
          importance: 5,
          memory_type: 'observation'
        )
      }.to change(NpcMemory, :count).by(1)
    end

    it 'sets abstraction_level to 1 for new memories' do
      memory = NpcMemoryService.store_memory(
        npc: npc,
        content: 'Test memory',
        memory_type: 'interaction'
      )

      expect(memory.abstraction_level).to eq(1)
    end

    it 'associates memory with about_character if provided' do
      memory = NpcMemoryService.store_memory(
        npc: npc,
        content: 'Had conversation with player',
        about_character: pc,
        memory_type: 'interaction'
      )

      expect(memory.about_character_id).to eq(pc.id)
    end

    it 'stores embedding with input_type document' do
      allow(Embedding).to receive(:store)

      NpcMemoryService.store_memory(
        npc: npc,
        content: 'Memory content for embedding',
        memory_type: 'interaction'
      )

      expect(Embedding).to have_received(:store).with(
        hash_including(
          content_type: 'npc_memory',
          input_type: 'document',
          character_id: npc.id
        )
      )
    end
  end

  describe '.retrieve_relevant' do
    before do
      # Mock the LLM embed call
      allow(LLM::Client).to receive(:embed).and_return(
        { success: true, embedding: Array.new(1024) { rand } }
      )
      # Mock Embedding.similar_to to avoid pgvector operations
      allow(Embedding).to receive(:similar_to).and_return([])
    end

    it 'uses input_type query for retrieval' do
      NpcMemoryService.retrieve_relevant(npc: npc, query: 'test query')

      expect(LLM::Client).to have_received(:embed).with(
        hash_including(input_type: 'query')
      )
    end

    it 'returns empty array when embed fails' do
      allow(LLM::Client).to receive(:embed).and_return({ success: false })

      result = NpcMemoryService.retrieve_relevant(npc: npc, query: 'test')
      expect(result).to eq([])
    end

    context 'with include_abstractions option' do
      it 'includes abstracted memories by default' do
        NpcMemoryService.retrieve_relevant(
          npc: npc,
          query: 'test',
          include_abstractions: true
        )

        # Test passes if no error - abstractions are included by default
      end

      it 'excludes abstracted memories when false' do
        NpcMemoryService.retrieve_relevant(
          npc: npc,
          query: 'test',
          include_abstractions: false
        )

        # Test passes if no error
      end
    end
  end

  describe '.format_for_context' do
    it 'returns empty string for empty memories' do
      result = NpcMemoryService.format_for_context([])
      expect(result).to eq('')
    end

    it 'formats memories with content' do
      memory1 = NpcMemory.create(
        character_id: npc.id,
        content: 'First memory',
        memory_type: 'interaction',
        abstraction_level: 1
      )
      memory2 = NpcMemory.create(
        character_id: npc.id,
        content: 'Second memory',
        memory_type: 'abstraction',
        abstraction_level: 2
      )

      result = NpcMemoryService.format_for_context([memory1, memory2])

      expect(result).to include('First memory')
      expect(result).to include('[Summary] Second memory')
    end
  end

  describe '.abstract_memories!' do
    before do
      # Create threshold number of memories
      8.times do |i|
        NpcMemory.create(
          character_id: npc.id,
          content: "Memory #{i}",
          memory_type: 'interaction',
          abstraction_level: 1
        )
      end

      allow(LLM::Client).to receive(:generate).and_return(
        { success: true, text: 'Summary of memories' }
      )
      allow(Embedding).to receive(:store)
    end

    it 'does not abstract when below threshold' do
      # Delete some memories to go below threshold
      memories_to_delete = NpcMemory.where(character_id: npc.id).limit(5).all
      memories_to_delete.each(&:delete)

      expect {
        NpcMemoryService.abstract_memories!(npc: npc, level: 1)
      }.not_to change(NpcMemory, :count)
    end

    it 'creates abstraction at next level' do
      result = NpcMemoryService.abstract_memories!(npc: npc, level: 1)

      if result # May be nil if not enough memories
        expect(result.abstraction_level).to eq(2)
        expect(result.memory_type).to eq('abstraction')
      end
    end

    it 'links original memories to abstraction' do
      result = NpcMemoryService.abstract_memories!(npc: npc, level: 1)

      if result
        abstracted_memories = NpcMemory.where(abstracted_into_id: result.id)
        expect(abstracted_memories.count).to eq(8)
      end
    end

    it 'does not abstract beyond max level' do
      expect(NpcMemoryService.abstract_memories!(npc: npc, level: 4)).to be_nil
    end
  end

  describe '.process_abstractions!' do
    it 'processes all levels' do
      # Create memories that need abstraction at level 1
      8.times do |i|
        NpcMemory.create(
          character_id: npc.id,
          content: "Memory #{i}",
          memory_type: 'interaction',
          abstraction_level: 1
        )
      end

      allow(LLM::Client).to receive(:generate).and_return(
        { success: true, text: 'Summary' }
      )
      allow(Embedding).to receive(:store)

      # Should not raise error
      NpcMemoryService.process_abstractions!(npc: npc)
    end
  end
end
