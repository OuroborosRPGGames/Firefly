# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Relationship do
  let(:user1) { create(:user) }
  let(:user2) { create(:user) }
  let(:character1) { Character.create(forename: 'Alice', user: user1, is_npc: false) }
  let(:character2) { Character.create(forename: 'Bob', user: user2, is_npc: false) }

  describe 'validations' do
    it 'requires character_id' do
      rel = Relationship.new(target_character_id: character2.id)
      expect(rel.valid?).to be false
      expect(rel.errors[:character_id]).not_to be_empty
    end

    it 'requires target_character_id' do
      rel = Relationship.new(character_id: character1.id)
      expect(rel.valid?).to be false
      expect(rel.errors[:target_character_id]).not_to be_empty
    end

    it 'prevents self-relationship' do
      rel = Relationship.new(character_id: character1.id, target_character_id: character1.id)
      expect(rel.valid?).to be false
      expect(rel.errors[:target_character_id]).not_to be_empty
    end

    it 'ensures unique character pair' do
      Relationship.create(character: character1, target_character: character2)
      rel2 = Relationship.new(character: character1, target_character: character2)
      expect(rel2.valid?).to be false
    end

    it 'validates status values' do
      rel = Relationship.new(character: character1, target_character: character2, status: 'invalid')
      expect(rel.valid?).to be false
    end
  end

  describe 'status methods' do
    let(:rel) { Relationship.create(character: character1, target_character: character2, status: 'pending') }

    it '#pending? returns true for pending status' do
      expect(rel.pending?).to be true
    end

    it '#accepted? returns true for accepted status' do
      rel.update(status: 'accepted')
      expect(rel.accepted?).to be true
    end

    it '#blocked? returns true for blocked status' do
      rel.update(status: 'blocked')
      expect(rel.blocked?).to be true
    end
  end

  describe 'follow permission methods' do
    let(:rel) { Relationship.create(character: character1, target_character: character2, status: 'accepted') }

    it '#allow_follow! enables following' do
      rel.allow_follow!
      expect(rel.reload.can_follow).to be true
    end

    it '#revoke_follow! disables following' do
      rel.update(can_follow: true)
      rel.revoke_follow!
      expect(rel.reload.can_follow).to be false
    end
  end

  describe '.between' do
    it 'finds relationship between characters' do
      rel = Relationship.create(character: character1, target_character: character2)
      found = described_class.between(character1, character2)

      expect(found).to eq(rel)
    end

    it 'returns nil when no relationship exists' do
      found = described_class.between(character1, character2)

      expect(found).to be_nil
    end
  end

  describe '.can_follow?' do
    it 'returns true when accepted and can_follow is true' do
      Relationship.create(
        character: character1,
        target_character: character2,
        status: 'accepted',
        can_follow: true
      )

      expect(described_class.can_follow?(character1, character2)).to be true
    end

    it 'returns false when not accepted' do
      Relationship.create(
        character: character1,
        target_character: character2,
        status: 'pending',
        can_follow: true
      )

      expect(described_class.can_follow?(character1, character2)).to be false
    end

    it 'returns false when can_follow is false' do
      Relationship.create(
        character: character1,
        target_character: character2,
        status: 'accepted',
        can_follow: false
      )

      expect(described_class.can_follow?(character1, character2)).to be false
    end

    it 'returns false when no relationship exists' do
      expect(described_class.can_follow?(character1, character2)).to be false
    end
  end

  describe '.find_or_create_between' do
    it 'creates new relationship when none exists' do
      expect do
        described_class.find_or_create_between(character1, character2)
      end.to change { Relationship.count }.by(1)
    end

    it 'returns existing relationship when one exists' do
      existing = Relationship.create(character: character1, target_character: character2)

      found = described_class.find_or_create_between(character1, character2)

      expect(found).to eq(existing)
    end
  end
end
