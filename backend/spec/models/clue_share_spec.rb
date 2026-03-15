# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ClueShare do
  let(:clue) { create(:clue) }
  let(:npc_character) { create(:character, :npc) }
  let(:recipient_character) { create(:character) }
  let(:room) { create(:room) }

  describe 'validations' do
    it 'requires clue_id' do
      share = described_class.new(
        npc_character_id: npc_character.id,
        recipient_character_id: recipient_character.id
      )
      expect(share.valid?).to be false
      expect(share.errors[:clue_id]).not_to be_empty
    end

    it 'requires npc_character_id' do
      share = described_class.new(
        clue_id: clue.id,
        recipient_character_id: recipient_character.id
      )
      expect(share.valid?).to be false
      expect(share.errors[:npc_character_id]).not_to be_empty
    end

    it 'requires recipient_character_id' do
      share = described_class.new(
        clue_id: clue.id,
        npc_character_id: npc_character.id
      )
      expect(share.valid?).to be false
      expect(share.errors[:recipient_character_id]).not_to be_empty
    end

    it 'is valid with required fields' do
      share = described_class.new(
        clue_id: clue.id,
        npc_character_id: npc_character.id,
        recipient_character_id: recipient_character.id
      )
      expect(share.valid?).to be true
    end
  end

  describe '#summary' do
    it 'returns human-readable summary' do
      share = described_class.new(
        clue_id: clue.id,
        npc_character_id: npc_character.id,
        recipient_character_id: recipient_character.id,
        shared_at: Time.now
      )

      summary = share.summary
      expect(summary).to include(npc_character.full_name)
      expect(summary).to include(recipient_character.full_name)
    end
  end
end
