# frozen_string_literal: true

require 'spec_helper'

RSpec.describe NpcClue do
  let(:character) { create(:character, :npc) }
  let(:clue) { create(:clue, share_likelihood: 0.7, min_trust_required: 0.3) }

  describe 'validations' do
    it 'requires character_id' do
      npc_clue = described_class.new(clue_id: clue.id)
      expect(npc_clue.valid?).to be false
      expect(npc_clue.errors[:character_id]).not_to be_empty
    end

    it 'requires clue_id' do
      npc_clue = described_class.new(character_id: character.id)
      expect(npc_clue.valid?).to be false
      expect(npc_clue.errors[:clue_id]).not_to be_empty
    end

    it 'requires unique character_id/clue_id combination' do
      described_class.create(character_id: character.id, clue_id: clue.id)

      duplicate = described_class.new(character_id: character.id, clue_id: clue.id)
      expect(duplicate.valid?).to be false
    end

    it 'is valid with required fields' do
      npc_clue = described_class.new(
        character_id: character.id,
        clue_id: clue.id
      )
      expect(npc_clue.valid?).to be true
    end
  end

  describe '#effective_share_likelihood' do
    it 'uses override when set' do
      npc_clue = described_class.new(
        character_id: character.id,
        clue_id: clue.id,
        share_likelihood_override: 0.9
      )
      expect(npc_clue.effective_share_likelihood).to eq(0.9)
    end

    it 'falls back to clue default when no override' do
      npc_clue = described_class.new(
        character_id: character.id,
        clue_id: clue.id
      )
      expect(npc_clue.effective_share_likelihood).to eq(0.7)
    end
  end

  describe '#effective_min_trust' do
    it 'uses override when set' do
      npc_clue = described_class.new(
        character_id: character.id,
        clue_id: clue.id,
        min_trust_override: 0.8
      )
      expect(npc_clue.effective_min_trust).to eq(0.8)
    end

    it 'falls back to clue default when no override' do
      npc_clue = described_class.new(
        character_id: character.id,
        clue_id: clue.id
      )
      expect(npc_clue.effective_min_trust).to eq(0.3)
    end
  end
end
