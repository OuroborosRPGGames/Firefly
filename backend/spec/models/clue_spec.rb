# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Clue do
  let(:npc) { create(:character, :npc) }
  let(:pc) { create(:character) }

  describe 'associations' do
    it 'has many npc_clues' do
      clue = create(:clue)
      npc_clue = NpcClue.create(clue_id: clue.id, character_id: npc.id)

      expect(clue.npc_clues).to include(npc_clue)
    end

    it 'has many clue_shares' do
      clue = create(:clue)
      clue_share = create(:clue_share, clue: clue)

      expect(clue.clue_shares).to include(clue_share)
    end
  end

  describe 'validations' do
    it 'requires name' do
      clue = Clue.new(content: 'This content is long enough to pass validation.')
      expect(clue.valid?).to be false
      expect(clue.errors[:name]).not_to be_empty
    end

    it 'requires content' do
      clue = Clue.new(name: 'Test Clue')
      expect(clue.valid?).to be false
      expect(clue.errors[:content]).not_to be_empty
    end

    it 'validates content minimum length of 10' do
      clue = Clue.new(name: 'Test Clue', content: 'Short')
      expect(clue.valid?).to be false
      expect(clue.errors[:content]).not_to be_empty
    end

    it 'accepts content with exactly 10 characters' do
      clue = Clue.new(name: 'Test Clue', content: '1234567890')
      expect(clue.valid?).to be true
    end

    it 'is valid with all required fields' do
      clue = Clue.new(name: 'Test Clue', content: 'This is valid content that is long enough.')
      expect(clue.valid?).to be true
    end
  end

  describe '#npcs' do
    let(:clue) { create(:clue) }
    let(:npc1) { create(:character, :npc) }
    let(:npc2) { create(:character, :npc) }

    before do
      NpcClue.create(clue_id: clue.id, character_id: npc1.id)
      NpcClue.create(clue_id: clue.id, character_id: npc2.id)
    end

    it 'returns all NPCs who know this clue' do
      npcs = clue.npcs

      expect(npcs).to include(npc1)
      expect(npcs).to include(npc2)
      expect(npcs.length).to eq(2)
    end

    it 'returns empty array when no NPCs know the clue' do
      new_clue = create(:clue)
      expect(new_clue.npcs).to eq([])
    end
  end

  describe '#npc_ids' do
    let(:clue) { create(:clue) }
    let(:npc1) { create(:character, :npc) }
    let(:npc2) { create(:character, :npc) }

    before do
      NpcClue.create(clue_id: clue.id, character_id: npc1.id)
      NpcClue.create(clue_id: clue.id, character_id: npc2.id)
    end

    it 'returns all NPC IDs who know this clue' do
      ids = clue.npc_ids

      expect(ids).to include(npc1.id)
      expect(ids).to include(npc2.id)
      expect(ids.length).to eq(2)
    end
  end

  describe '#share_likelihood_for' do
    let(:clue) { create(:clue, share_likelihood: 0.5) }

    it 'returns the clue share_likelihood when no override exists' do
      expect(clue.share_likelihood_for(npc)).to eq(0.5)
    end

    it 'returns the override value when present' do
      NpcClue.create(
        clue_id: clue.id,
        character_id: npc.id,
        share_likelihood_override: 0.9
      )

      expect(clue.share_likelihood_for(npc)).to eq(0.9)
    end

    it 'returns clue default when override is nil' do
      NpcClue.create(
        clue_id: clue.id,
        character_id: npc.id,
        share_likelihood_override: nil
      )

      expect(clue.share_likelihood_for(npc)).to eq(0.5)
    end
  end

  describe '#min_trust_for' do
    let(:clue) { create(:clue, min_trust_required: 0.3) }

    it 'returns the clue min_trust_required when no override exists' do
      expect(clue.min_trust_for(npc)).to eq(0.3)
    end

    it 'returns the override value when present' do
      NpcClue.create(
        clue_id: clue.id,
        character_id: npc.id,
        min_trust_override: 0.7
      )

      expect(clue.min_trust_for(npc)).to eq(0.7)
    end

    it 'returns clue default when override is nil' do
      NpcClue.create(
        clue_id: clue.id,
        character_id: npc.id,
        min_trust_override: nil
      )

      expect(clue.min_trust_for(npc)).to eq(0.3)
    end
  end

  describe '#can_share_to?' do
    context 'when clue is not secret' do
      let(:clue) { create(:clue, is_secret: false) }

      it 'returns true regardless of trust level' do
        expect(clue.can_share_to?(pc, npc: npc)).to be true
      end
    end

    context 'when clue is secret' do
      let(:clue) { create(:clue, :secret, min_trust_required: 0.5) }

      it 'returns false when no relationship exists' do
        expect(clue.can_share_to?(pc, npc: npc)).to be false
      end

      it 'returns false when trust is below minimum' do
        NpcRelationship.create(
          npc_character_id: npc.id,
          pc_character_id: pc.id,
          trust: 0.3
        )

        expect(clue.can_share_to?(pc, npc: npc)).to be false
      end

      it 'returns true when trust meets minimum' do
        NpcRelationship.create(
          npc_character_id: npc.id,
          pc_character_id: pc.id,
          trust: 0.5
        )

        expect(clue.can_share_to?(pc, npc: npc)).to be true
      end

      it 'returns true when trust exceeds minimum' do
        NpcRelationship.create(
          npc_character_id: npc.id,
          pc_character_id: pc.id,
          trust: 0.9
        )

        expect(clue.can_share_to?(pc, npc: npc)).to be true
      end

      it 'uses NPC-specific min_trust_override when present' do
        NpcClue.create(
          clue_id: clue.id,
          character_id: npc.id,
          min_trust_override: 0.2
        )
        NpcRelationship.create(
          npc_character_id: npc.id,
          pc_character_id: pc.id,
          trust: 0.3
        )

        expect(clue.can_share_to?(pc, npc: npc)).to be true
      end
    end
  end

  describe '#already_shared_to?' do
    let(:clue) { create(:clue) }

    it 'returns false when clue has not been shared' do
      expect(clue.already_shared_to?(pc, npc: npc)).to be false
    end

    it 'returns true when clue has been shared to this PC by this NPC' do
      ClueShare.create(
        clue_id: clue.id,
        npc_character_id: npc.id,
        recipient_character_id: pc.id,
        shared_at: Time.now
      )

      expect(clue.already_shared_to?(pc, npc: npc)).to be true
    end

    it 'returns false when clue was shared by different NPC' do
      other_npc = create(:character, :npc)
      ClueShare.create(
        clue_id: clue.id,
        npc_character_id: other_npc.id,
        recipient_character_id: pc.id,
        shared_at: Time.now
      )

      expect(clue.already_shared_to?(pc, npc: npc)).to be false
    end

    it 'returns false when clue was shared to different PC' do
      other_pc = create(:character, is_npc: false)
      ClueShare.create(
        clue_id: clue.id,
        npc_character_id: npc.id,
        recipient_character_id: other_pc.id,
        shared_at: Time.now
      )

      expect(clue.already_shared_to?(pc, npc: npc)).to be false
    end
  end

  describe '#share_count' do
    let(:clue) { create(:clue) }

    it 'returns 0 when no shares exist' do
      expect(clue.share_count).to eq(0)
    end

    it 'returns the count of shares' do
      3.times do
        recipient = create(:character)
        ClueShare.create(
          clue_id: clue.id,
          npc_character_id: npc.id,
          recipient_character_id: recipient.id,
          shared_at: Time.now
        )
      end

      expect(clue.share_count).to eq(3)
    end
  end

  describe '#add_npc!' do
    let(:clue) { create(:clue) }

    it 'creates an NpcClue association' do
      clue.add_npc!(npc)

      npc_clue = NpcClue.where(clue_id: clue.id, character_id: npc.id).first
      expect(npc_clue).not_to be_nil
    end

    it 'accepts likelihood override' do
      clue.add_npc!(npc, likelihood_override: 0.8)

      npc_clue = NpcClue.where(clue_id: clue.id, character_id: npc.id).first
      expect(npc_clue.share_likelihood_override).to eq(0.8)
    end

    it 'accepts trust override' do
      clue.add_npc!(npc, trust_override: 0.4)

      npc_clue = NpcClue.where(clue_id: clue.id, character_id: npc.id).first
      expect(npc_clue.min_trust_override).to eq(0.4)
    end

    it 'accepts both overrides' do
      clue.add_npc!(npc, likelihood_override: 0.9, trust_override: 0.6)

      npc_clue = NpcClue.where(clue_id: clue.id, character_id: npc.id).first
      expect(npc_clue.share_likelihood_override).to eq(0.9)
      expect(npc_clue.min_trust_override).to eq(0.6)
    end
  end

  describe '#remove_npc!' do
    let(:clue) { create(:clue) }

    before do
      NpcClue.create(clue_id: clue.id, character_id: npc.id)
    end

    it 'removes the NpcClue association' do
      expect { clue.remove_npc!(npc) }.to change {
        NpcClue.where(clue_id: clue.id, character_id: npc.id).count
      }.from(1).to(0)
    end

    it 'does not affect other NPCs' do
      other_npc = create(:character, :npc)
      NpcClue.create(clue_id: clue.id, character_id: other_npc.id)

      clue.remove_npc!(npc)

      expect(NpcClue.where(clue_id: clue.id, character_id: other_npc.id).count).to eq(1)
    end
  end

  describe 'factory traits' do
    it 'creates a basic clue' do
      clue = create(:clue)
      expect(clue).to be_valid
      expect(clue.is_active).to be true
      expect(clue.is_secret).to be false
    end

    it 'creates a secret clue' do
      clue = create(:clue, :secret)
      expect(clue.is_secret).to be true
      expect(clue.min_trust_required).to eq(0.5)
    end

    it 'creates a high likelihood clue' do
      clue = create(:clue, :high_likelihood)
      expect(clue.share_likelihood).to eq(0.9)
    end

    it 'creates a low likelihood clue' do
      clue = create(:clue, :low_likelihood)
      expect(clue.share_likelihood).to eq(0.1)
    end

    it 'creates an inactive clue' do
      clue = create(:clue, :inactive)
      expect(clue.is_active).to be false
    end
  end
end
