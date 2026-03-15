# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcMemory do
  let(:npc) { create(:character) }
  let(:other_character) { create(:character) }
  let(:location) { create(:location) }

  describe 'constants' do
    it 'defines MEMORY_TYPES' do
      expected = %w[interaction observation event secret goal emotion abstraction reflection]
      expect(described_class::MEMORY_TYPES).to match_array(expected)
    end

    it 'defines ABSTRACTION_THRESHOLD from GameConfig' do
      expect(described_class::ABSTRACTION_THRESHOLD).to eq(GameConfig::NpcMemory::ABSTRACTION_THRESHOLD)
    end

    it 'defines MAX_ABSTRACTION_LEVEL from GameConfig' do
      expect(described_class::MAX_ABSTRACTION_LEVEL).to eq(GameConfig::NpcMemory::MAX_ABSTRACTION_LEVEL)
    end
  end

  describe 'associations' do
    it 'belongs to character' do
      memory = create(:npc_memory, character: npc)
      expect(memory.character).to eq(npc)
    end

    it 'belongs to about_character' do
      memory = create(:npc_memory, character: npc, about_character: other_character)
      expect(memory.about_character).to eq(other_character)
    end

    it 'belongs to location' do
      memory = create(:npc_memory, character: npc, location: location)
      expect(memory.location).to eq(location)
    end

    it 'belongs to abstracted_into' do
      abstraction = create(:npc_memory, :abstraction, character: npc)
      memory = create(:npc_memory, character: npc, abstracted_into: abstraction)
      expect(memory.abstracted_into).to eq(abstraction)
    end

    it 'has many abstracted_from' do
      abstraction = create(:npc_memory, :abstraction, character: npc)
      memory1 = create(:npc_memory, character: npc, abstracted_into: abstraction)
      memory2 = create(:npc_memory, character: npc, abstracted_into: abstraction)

      expect(abstraction.abstracted_from).to include(memory1, memory2)
    end
  end

  describe 'validations' do
    it 'requires character_id' do
      memory = build(:npc_memory, character: nil)
      expect(memory.valid?).to be false
      expect(memory.errors[:character_id]).to include('is not present')
    end

    it 'requires content' do
      memory = build(:npc_memory, character: npc, content: nil)
      expect(memory.valid?).to be false
      expect(memory.errors[:content]).to include('is not present')
    end

    it 'requires memory_type' do
      memory = build(:npc_memory, character: npc, memory_type: nil)
      expect(memory.valid?).to be false
      expect(memory.errors[:memory_type]).to include('is not present')
    end

    it 'validates memory_type is in MEMORY_TYPES' do
      memory = build(:npc_memory, character: npc, memory_type: 'invalid')
      expect(memory.valid?).to be false
    end

    it 'accepts valid memory_type values' do
      described_class::MEMORY_TYPES.each do |memory_type|
        memory = build(:npc_memory, character: npc, memory_type: memory_type)
        expect(memory.valid?).to be true
      end
    end
  end

  describe 'before_save defaults' do
    it 'sets default importance to 5' do
      memory = create(:npc_memory, character: npc, importance: nil)
      expect(memory.importance).to eq(5)
    end

    it 'sets default abstraction_level to 1' do
      memory = create(:npc_memory, character: npc, abstraction_level: nil)
      expect(memory.abstraction_level).to eq(1)
    end

    it 'sets created_at if not set' do
      memory = create(:npc_memory, character: npc)
      expect(memory.created_at).not_to be_nil
    end

    it 'sets memory_at if not set' do
      memory = create(:npc_memory, character: npc, memory_at: nil)
      expect(memory.memory_at).not_to be_nil
    end
  end

  describe '#relevance_score' do
    it 'returns higher score for more important memories' do
      important = create(:npc_memory, character: npc, importance: 10)
      normal = create(:npc_memory, character: npc, importance: 5)

      expect(important.relevance_score).to be > normal.relevance_score
    end

    it 'returns higher score for more recent memories' do
      recent = create(:npc_memory, character: npc, memory_at: Time.now)
      old = create(:npc_memory, character: npc, memory_at: Time.now - (180 * 86400)) # 6 months ago

      expect(recent.relevance_score).to be > old.relevance_score
    end

    it 'combines importance and timeliness factors' do
      memory = create(:npc_memory, character: npc, importance: 10, memory_at: Time.now)
      score = memory.relevance_score

      # Max score: importance (1.0 * 0.6) + timeliness (1.0 * 0.4) = 1.0
      expect(score).to be_between(0.9, 1.0)
    end

    it 'has minimum timeliness factor of 0.1' do
      very_old = create(:npc_memory, character: npc, importance: 1, memory_at: Time.now - (730 * 86400)) # 2 years ago
      score = very_old.relevance_score

      # Should still have some relevance
      expect(score).to be > 0
    end
  end

  describe '#about?' do
    it 'returns true when memory is about the character' do
      memory = create(:npc_memory, character: npc, about_character: other_character)
      expect(memory.about?(other_character)).to be true
    end

    it 'returns false when memory is not about the character' do
      third_character = create(:character)
      memory = create(:npc_memory, character: npc, about_character: other_character)
      expect(memory.about?(third_character)).to be false
    end
  end

  describe '#recent?' do
    it 'returns true for memory within default 7 days' do
      memory = create(:npc_memory, character: npc, memory_at: Time.now - (3 * 86400))
      expect(memory.recent?).to be true
    end

    it 'returns false for memory older than 7 days' do
      memory = create(:npc_memory, character: npc, memory_at: Time.now - (10 * 86400))
      expect(memory.recent?).to be false
    end

    it 'accepts custom days parameter' do
      memory = create(:npc_memory, character: npc, memory_at: Time.now - (3 * 86400))
      expect(memory.recent?(days: 2)).to be false
      expect(memory.recent?(days: 5)).to be true
    end
  end

  describe '#important?' do
    it 'returns true for importance >= 7' do
      memory = create(:npc_memory, character: npc, importance: 7)
      expect(memory.important?).to be true
    end

    it 'returns false for importance < 7' do
      memory = create(:npc_memory, character: npc, importance: 6)
      expect(memory.important?).to be false
    end
  end

  describe '#secret?' do
    it 'returns true for secret memory type' do
      memory = create(:npc_memory, :secret, character: npc)
      expect(memory.secret?).to be true
    end

    it 'returns false for non-secret memory type' do
      memory = create(:npc_memory, character: npc, memory_type: 'interaction')
      expect(memory.secret?).to be false
    end
  end

  describe '#abstracted?' do
    it 'returns true when abstracted_into_id is set' do
      abstraction = create(:npc_memory, :abstraction, character: npc)
      memory = create(:npc_memory, character: npc, abstracted_into: abstraction)
      expect(memory.abstracted?).to be true
    end

    it 'returns false when abstracted_into_id is nil' do
      memory = create(:npc_memory, character: npc)
      expect(memory.abstracted?).to be false
    end
  end

  describe '#abstraction?' do
    it 'returns true for abstraction memory type' do
      memory = create(:npc_memory, :abstraction, character: npc)
      expect(memory.abstraction?).to be true
    end

    it 'returns false for non-abstraction memory type' do
      memory = create(:npc_memory, character: npc, memory_type: 'interaction')
      expect(memory.abstraction?).to be false
    end
  end

  describe '#raw_memory?' do
    it 'returns true for abstraction_level 1' do
      memory = create(:npc_memory, character: npc, abstraction_level: 1)
      expect(memory.raw_memory?).to be true
    end

    it 'returns false for abstraction_level > 1' do
      memory = create(:npc_memory, character: npc, abstraction_level: 2)
      expect(memory.raw_memory?).to be false
    end
  end

  describe '#can_abstract?' do
    it 'returns true when level < MAX and not abstracted' do
      memory = create(:npc_memory, character: npc, abstraction_level: 1)
      expect(memory.can_abstract?).to be true
    end

    it 'returns false when at MAX_ABSTRACTION_LEVEL' do
      memory = create(:npc_memory, character: npc, abstraction_level: described_class::MAX_ABSTRACTION_LEVEL)
      expect(memory.can_abstract?).to be false
    end

    it 'returns false when already abstracted' do
      abstraction = create(:npc_memory, :abstraction, character: npc)
      memory = create(:npc_memory, character: npc, abstracted_into: abstraction)
      expect(memory.can_abstract?).to be false
    end
  end

  describe '.relevant_for' do
    before do
      @memory1 = create(:npc_memory, character: npc, importance: 10)
      @memory2 = create(:npc_memory, character: npc, importance: 5, about_character: other_character)
      @memory3 = create(:npc_memory, character: npc, importance: 8, location: location)
      @other_npc_memory = create(:npc_memory, character: other_character)
    end

    it 'returns memories for the NPC' do
      memories = described_class.relevant_for(npc).all
      expect(memories).to include(@memory1, @memory2, @memory3)
      expect(memories).not_to include(@other_npc_memory)
    end

    it 'filters by about_character when provided' do
      memories = described_class.relevant_for(npc, about: other_character).all
      expect(memories).to include(@memory2)
      expect(memories).not_to include(@memory1, @memory3)
    end

    it 'filters by location when provided' do
      memories = described_class.relevant_for(npc, location: location).all
      expect(memories).to include(@memory3)
      expect(memories).not_to include(@memory1, @memory2)
    end

    it 'orders by importance then memory_at' do
      memories = described_class.relevant_for(npc).all
      importances = memories.map(&:importance)
      expect(importances).to eq(importances.sort.reverse)
    end

    it 'respects limit parameter' do
      memories = described_class.relevant_for(npc, limit: 2).all
      expect(memories.size).to eq(2)
    end
  end

  describe '.create_from_interaction' do
    it 'creates a memory about an interaction' do
      memory = described_class.create_from_interaction(npc, other_character, 'Met at the tavern')

      expect(memory.character_id).to eq(npc.id)
      expect(memory.about_character_id).to eq(other_character.id)
      expect(memory.content).to eq('Met at the tavern')
      expect(memory.memory_type).to eq('interaction')
    end

    it 'uses default importance of 5' do
      memory = described_class.create_from_interaction(npc, other_character, 'Test')
      expect(memory.importance).to eq(5)
    end

    it 'accepts custom importance' do
      memory = described_class.create_from_interaction(npc, other_character, 'Test', importance: 9)
      expect(memory.importance).to eq(9)
    end
  end

  describe '.unabstracted_at_level' do
    before do
      @level1_unabstracted = create(:npc_memory, character: npc, abstraction_level: 1)
      @level1_abstracted = create(:npc_memory, character: npc, abstraction_level: 1,
                                               abstracted_into: create(:npc_memory, :abstraction, character: npc))
      @level2_unabstracted = create(:npc_memory, character: npc, abstraction_level: 2)
    end

    it 'returns unabstracted memories at the specified level' do
      memories = described_class.unabstracted_at_level(npc.id, 1).all
      expect(memories).to include(@level1_unabstracted)
      expect(memories).not_to include(@level1_abstracted, @level2_unabstracted)
    end

    it 'orders by created_at' do
      older = create(:npc_memory, character: npc, abstraction_level: 1)
      older.this.update(created_at: Time.now - 3600)
      older.refresh

      memories = described_class.unabstracted_at_level(npc.id, 1).all
      expect(memories.last.created_at).to be >= memories.first.created_at
    end
  end

  describe '.unabstracted_count_at_level' do
    it 'counts unabstracted memories at the specified level' do
      3.times { create(:npc_memory, character: npc, abstraction_level: 1) }
      2.times { create(:npc_memory, character: npc, abstraction_level: 2) }

      expect(described_class.unabstracted_count_at_level(npc.id, 1)).to eq(3)
      expect(described_class.unabstracted_count_at_level(npc.id, 2)).to eq(2)
    end
  end

  describe '.needs_abstraction?' do
    it 'returns true when count >= ABSTRACTION_THRESHOLD' do
      described_class::ABSTRACTION_THRESHOLD.times do
        create(:npc_memory, character: npc, abstraction_level: 1)
      end

      expect(described_class.needs_abstraction?(npc.id, 1)).to be true
    end

    it 'returns false when count < ABSTRACTION_THRESHOLD' do
      (described_class::ABSTRACTION_THRESHOLD - 1).times do
        create(:npc_memory, character: npc, abstraction_level: 1)
      end

      expect(described_class.needs_abstraction?(npc.id, 1)).to be false
    end
  end
end
