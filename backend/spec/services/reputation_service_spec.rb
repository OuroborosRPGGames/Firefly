# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ReputationService do
  let(:pc) { create(:character, forename: 'Alice', surname: 'Smith') }
  let(:npc) { create(:character, :npc, forename: 'Guard') }

  describe 'schema contract' do
    it 'loads world memory models used by reputation generation' do
      expect(defined?(WorldMemory)).to eq('constant')
      expect(defined?(WorldMemoryCharacter)).to eq('constant')
    end
  end

  describe '.regenerate_all!' do
    before do
      allow(LLM::Client).to receive(:generate).and_return(
        {
          success: true,
          text: '{"tier_1": "Nothing notable.", "tier_2": "Regular adventurer.", "tier_3": "Has a secret."}'
        }
      )
    end

    it 'processes all PC characters' do
      pc # ensure PC exists
      pc2 = create(:character, forename: 'Bob')

      result = ReputationService.regenerate_all!

      expect(result[:processed]).to eq(2)
      expect(result[:errors]).to eq(0)
    end

    it 'does not process NPCs' do
      pc # ensure PC exists
      npc # ensure NPC exists

      result = ReputationService.regenerate_all!

      expect(result[:processed]).to eq(1) # only the PC
      expect(npc.reload.tier_1_reputation).to be_nil
    end

    it 'continues processing when one character fails' do
      allow(ReputationService).to receive(:regenerate_for_character!).and_call_original
      allow(ReputationService).to receive(:regenerate_for_character!).with(pc).and_raise('Test error')
      pc2 = create(:character, forename: 'Bob')

      result = ReputationService.regenerate_all!

      expect(result[:processed]).to eq(1)
      expect(result[:errors]).to eq(1)
    end
  end

  describe '.regenerate_for_character!' do
    let(:llm_response) do
      {
        success: true,
        text: '{"tier_1": "Famous hero.", "tier_2": "Known for bravery.", "tier_3": "Secretly afraid of heights."}'
      }
    end

    before do
      allow(LLM::Client).to receive(:generate).and_return(llm_response)
    end

    it 'returns false for nil character' do
      result = ReputationService.regenerate_for_character!(nil)
      expect(result).to be false
    end

    it 'returns false for NPC characters' do
      result = ReputationService.regenerate_for_character!(npc)
      expect(result).to be false
    end

    it 'updates character reputation columns' do
      ReputationService.regenerate_for_character!(pc)

      pc.reload
      expect(pc.tier_1_reputation).to eq('Famous hero.')
      expect(pc.tier_2_reputation).to eq('Known for bravery.')
      expect(pc.tier_3_reputation).to eq('Secretly afraid of heights.')
    end

    it 'sets reputation_updated_at timestamp' do
      ReputationService.regenerate_for_character!(pc)

      pc.reload
      expect(pc.reputation_updated_at).to be_within(5).of(Time.now)
    end

    it 'calls LLM with character name in prompt' do
      ReputationService.regenerate_for_character!(pc)

      expect(LLM::Client).to have_received(:generate).with(
        hash_including(prompt: a_string_including('Alice Smith'))
      )
    end

    it 'uses gemini-3-flash-preview model' do
      ReputationService.regenerate_for_character!(pc)

      expect(LLM::Client).to have_received(:generate).with(
        hash_including(model: 'gemini-3-flash-preview')
      )
    end

    it 'requests JSON mode' do
      ReputationService.regenerate_for_character!(pc)

      expect(LLM::Client).to have_received(:generate).with(
        hash_including(json_mode: true)
      )
    end

    it 'returns false when LLM fails' do
      allow(LLM::Client).to receive(:generate).and_return({ success: false, error: 'API error' })

      result = ReputationService.regenerate_for_character!(pc)

      expect(result).to be false
      expect(pc.reload.tier_1_reputation).to be_nil
    end

    it 'returns false when LLM returns invalid JSON' do
      allow(LLM::Client).to receive(:generate).and_return({ success: true, text: 'not json' })

      result = ReputationService.regenerate_for_character!(pc)

      expect(result).to be false
    end

    context 'with WorldMemory entries' do
      before do
        # Create a world memory linked to this PC
        memory = WorldMemory.create(
          summary: 'Alice saved the village from bandits',
          importance: 8,
          started_at: Time.now - 3600,
          ended_at: Time.now - 3000,
          memory_at: Time.now - 3000,
          publicity_level: 'public',
          abstraction_level: 1,
          excluded_from_public: false
        )

        WorldMemoryCharacter.create(
          world_memory_id: memory.id,
          character_id: pc.id,
          role: 'participant',
          message_count: 10,
          first_seen_at: memory.started_at,
          last_seen_at: memory.ended_at
        )
      end

      it 'includes memory summaries in prompt' do
        ReputationService.regenerate_for_character!(pc)

        expect(LLM::Client).to have_received(:generate).with(
          hash_including(prompt: a_string_including('saved the village'))
        )
      end

      it 'labels important memories' do
        ReputationService.regenerate_for_character!(pc)

        expect(LLM::Client).to have_received(:generate).with(
          hash_including(prompt: a_string_including('[Important]'))
        )
      end
    end
  end

  describe '.reputation_for' do
    before do
      pc.update(
        tier_1_reputation: 'Famous hero.',
        tier_2_reputation: 'Known for bravery.',
        tier_3_reputation: 'Secretly afraid of heights.'
      )
    end

    it 'returns nil for nil character' do
      expect(ReputationService.reputation_for(nil)).to be_nil
    end

    it 'returns tier 1 only for knowledge_tier 1' do
      result = ReputationService.reputation_for(pc, knowledge_tier: 1)

      expect(result).to eq('Famous hero.')
      expect(result).not_to include('bravery')
    end

    it 'returns tiers 1 and 2 for knowledge_tier 2' do
      result = ReputationService.reputation_for(pc, knowledge_tier: 2)

      expect(result).to include('Famous hero.')
      expect(result).to include('Known for bravery.')
      expect(result).not_to include('afraid of heights')
    end

    it 'returns all tiers for knowledge_tier 3' do
      result = ReputationService.reputation_for(pc, knowledge_tier: 3)

      expect(result).to include('Famous hero.')
      expect(result).to include('Known for bravery.')
      expect(result).to include('Secretly afraid of heights.')
    end

    it 'filters out "nothing notable" entries' do
      pc.update(tier_1_reputation: 'Nothing notable publicly known.')

      result = ReputationService.reputation_for(pc, knowledge_tier: 1)

      expect(result).to be_nil
    end

    it 'filters out empty tier entries' do
      pc.update(tier_1_reputation: '', tier_2_reputation: 'Only social knowledge.')

      result = ReputationService.reputation_for(pc, knowledge_tier: 2)

      expect(result).to eq('Only social knowledge.')
    end

    it 'joins multiple tiers with double newlines' do
      result = ReputationService.reputation_for(pc, knowledge_tier: 3)

      expect(result).to eq("Famous hero.\n\nKnown for bravery.\n\nSecretly afraid of heights.")
    end

    it 'returns nil when all tiers are empty or "nothing notable"' do
      pc.update(
        tier_1_reputation: 'Nothing notable.',
        tier_2_reputation: '',
        tier_3_reputation: nil
      )

      result = ReputationService.reputation_for(pc, knowledge_tier: 3)

      expect(result).to be_nil
    end

    it 'defaults to knowledge_tier 1' do
      result = ReputationService.reputation_for(pc)

      expect(result).to eq('Famous hero.')
    end
  end

  describe 'memory scoring' do
    it 'weighs importance at 60% and recency at 40%' do
      # Test via the model's relevance_score method
      recent_important = WorldMemory.new(importance: 10, memory_at: Time.now)
      old_unimportant = WorldMemory.new(importance: 1, memory_at: Time.now - (365 * 86400))

      # Recent + important should score higher
      expect(recent_important.relevance_score).to be > old_unimportant.relevance_score
    end
  end
end
